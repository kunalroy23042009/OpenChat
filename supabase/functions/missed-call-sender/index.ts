// Missed call FCM sender: processes the missed_call_notifications queue.
// Deploy as a scheduled Edge Function (e.g., every 30 seconds via pg_cron or external cron).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

async function googleAccessToken(sa: {
  client_email: string;
  private_key: string;
  token_uri: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = btoa(JSON.stringify({ alg: "RS256", typ: "JWT" }))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const claims = btoa(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri,
    iat: now,
    exp: now + 3600,
  }))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
  const key = await crypto.subtle.importKey(
    "pkcs8",
    new Uint8Array(sa.private_key.replace(/-----BEGIN [^-]+-----/, "").replace(/-----END [^-]+-----/, "").replace(/\s+/g, "").split("").map(c => c.charCodeAt(0))).buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const assertion = `${header}.${claims}.${btoa(String.fromCharCode(...new Uint8Array(sig))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")}`;
  const res = await fetch(sa.token_uri, {
    signal: AbortSignal.timeout(10000),
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error("Google token exchange failed.");
  const data = await res.json();
  return data.access_token as string;
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
  if (!supabaseUrl || !serviceKey || !saRaw) {
    return json({ error: "Not configured." }, 503);
  }
  let sa: { client_email: string; private_key: string; token_uri: string; project_id: string };
  try {
    sa = JSON.parse(saRaw);
    if (!sa.client_email || !sa.private_key || !sa.project_id) throw new Error();
  } catch {
    return json({ error: "FCM sender misconfigured." }, 503);
  }

  const admin = createClient(supabaseUrl, serviceKey);

  // Get pending missed call notifications (limit 50 per run)
  const { data: notifications, error } = await admin.from('missed_call_notifications')
    .select('*')
    .is('sent_at', null)
    .order('created_at', { ascending: true })
    .limit(50);
  if (error) return json({ error: error.message }, 500);
  if (!notifications?.length) return json({ sent: 0 });

  // Get FCM tokens for all callees
  const calleeIds = [...new Set(notifications.map((n: any) => n.callee_id))];
  const { data: tokens } = await admin.from('push_tokens')
    .select('token, user_id').in('user_id', calleeIds);
  if (!tokens?.length) return json({ sent: 0, reason: 'no_registered_devices' });

  let access: string;
  try {
    access = await googleAccessToken({
      client_email: sa.client_email,
      private_key: sa.private_key,
      token_uri: sa.token_uri ?? "https://oauth2.googleapis.com/token",
    });
  } catch {
    return json({ error: "FCM auth failed" }, 502);
  }

  let sent = 0;
  for (const notif of notifications) {
    const eventId = notif.invite_id;
    const kind = 'missed_call';
    const data = { kind, peer: notif.caller_id, invite: eventId, video: notif.call_type === 'video' ? "true" : "false", name: notif.caller_name };

    for (const { token, user_id: recipient } of tokens.filter((t: any) => t.user_id === notif.callee_id)) {
      const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
      const deviceHash = btoa(String.fromCharCode(...new Uint8Array(hash)))
        .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      const { data: claimed } = await admin.rpc('claim_device_notification',
        { p_actor: notif.caller_id, p_recipient: recipient, p_kind: kind, p_event: eventId, p_device_hash: deviceHash });
      if (!claimed) continue;
      try {
        const res = await fetch(
          `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
          {
            method: "POST",
            signal: AbortSignal.timeout(10000),
            headers: {
              Authorization: `Bearer ${access}`,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({
              message: { token, data: { ...data, event: eventId, recipient }, android: { priority: "high", ttl: '3600s' } },
            }),
          },
        );
        if (res.ok) {
          await admin.from('device_notification_dispatches').update({ sent: true })
            .eq('actor_id', notif.caller_id).eq('recipient_id', recipient).eq('kind', kind).eq('event_id', eventId)
            .eq('device_hash', deviceHash);
          sent++;
        } else {
          const failure = await res.json().catch(() => null);
          if (failure?.error?.details?.some((d: { errorCode?: string }) => d.errorCode === 'UNREGISTERED')) {
            await admin.from('push_tokens').delete().eq('token', token).eq('user_id', recipient);
          }
        }
      } catch {
        // Continue to next token
      }
    }

    // Mark as sent (even if some tokens failed; we don't retry indefinitely)
    await admin.from('missed_call_notifications').update({ sent_at: new Date().toISOString() })
      .eq('id', notif.id);
  }

  return json({ sent });
});