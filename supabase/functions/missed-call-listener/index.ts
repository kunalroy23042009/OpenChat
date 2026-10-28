// Missed call notification listener: receives pg_notify from call_invites trigger
// and sends FCM push to the callee.

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

async function sendFcm(
  admin: any,
  sa: any,
  access: string,
  token: string,
  data: Record<string, string>,
  eventId: string,
  recipient: string,
  kind: string,
  deviceHash: string,
): Promise<boolean> {
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
        .eq('actor_id', data['peer'] as string).eq('recipient_id', recipient).eq('kind', kind).eq('event_id', eventId)
        .eq('device_hash', deviceHash);
      return true;
    } else {
      const failure = await res.json().catch(() => null);
      if (failure?.error?.details?.some((d: { errorCode?: string }) => d.errorCode === 'UNREGISTERED')) {
        await admin.from('push_tokens').delete().eq('token', token).eq('user_id', recipient);
      }
      return false;
    }
  } catch {
    return false;
  }
}

serve(async (req) => {
  // This function is invoked via pg_notify LISTEN, not HTTP.
  // For Supabase Edge Functions, we need a different approach.
  // Option 1: Use a separate worker that LISTENs on the channel.
  // Option 2: Call this function directly from the trigger via a helper.
  // Since Edge Functions can't hold persistent LISTEN connections,
  // we use a different pattern: the trigger calls a helper function that invokes this.

  // This file is for reference; the actual implementation uses a Supabase
  // Database Webhook or a separate worker process.
  return json({ status: 'missed-call-listener - deploy as worker' });
});