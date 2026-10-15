// WhatsApp-style push fan-out. The app invokes this best-effort after a
// send (message/call/status); the function verifies the caller, resolves
// the recipients' FCM tokens server-side, and delivers a DATA-ONLY nudge.
// Payloads carry routing ids and display names only — never message
// content, ciphertext, or key material. Requires FCM_SERVICE_ACCOUNT (the
// Firebase service-account JSON) configured as an Edge secret.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function b64urlJson(value: unknown): string {
  return btoa(JSON.stringify(value))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function b64urlBytes(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToBytes(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const raw = atob(body);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

/// Google OAuth2 access token for FCM HTTP v1, signed RS256 with the
/// service-account private key (PKCS#8 PEM).
async function googleAccessToken(sa: {
  client_email: string;
  private_key: string;
  token_uri: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = b64urlJson({ alg: "RS256", typ: "JWT" });
  const claims = b64urlJson({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri,
    iat: now,
    exp: now + 3600,
  });
  const key = await crypto.subtle.importKey(
    "pkcs8",
    new Uint8Array(pemToBytes(sa.private_key)).buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const assertion = `${header}.${claims}.${b64urlBytes(new Uint8Array(sig))}`;
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
  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Sign in to notify." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const saRaw = Deno.env.get("FCM_SERVICE_ACCOUNT") ?? "";
  if (!supabaseUrl || !anonKey || !serviceKey) {
    return json({ error: "Push is not configured yet." }, 503);
  }
  if (!saRaw) return json({ error: "FCM sender is not configured yet." }, 503);
  let sa: { client_email: string; private_key: string; token_uri: string; project_id: string };
  try {
    sa = JSON.parse(saRaw);
    if (!sa.client_email || !sa.private_key || !sa.project_id) throw new Error();
  } catch {
    return json({ error: "FCM sender is misconfigured." }, 503);
  }

  let body: { kind?: unknown; peer?: unknown; invite?: unknown; video?: unknown; group?: unknown; event?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  const kind = body.kind;
  if (kind !== "message" && kind !== "call" && kind !== "status" && kind !== "group") {
    return json({ error: "Invalid kind." }, 400);
  }

  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: auth } },
  });
  // Pass the token explicitly: pinned supabase-js versions resolve
  // getUser() from storage session only and ignore the header.
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : auth;
  const { data: user } = await supabase.auth.getUser(token);
  const me = user?.user?.id;
  if (!me) return json({ error: "Sign in to notify." }, 401);
  const { data: profile } = await supabase
    .from("profiles")
    .select("display_name")
    .eq("id", me)
    .single();
  const myName = (profile?.display_name as string | undefined) ?? "New contact";

  // Service-role client: reads tokens + contact graph, never exposes them.
  const admin = createClient(supabaseUrl, serviceKey);
  let targets: string[] = [];
  let eventId = '';
  let video = false;
  let groupId = '';
  let groupName = '';
  const recent = new Date(Date.now() - 120000).toISOString();
  const { data: links, error: linkError } = await admin.from('contact_requests')
    .select('sender_id,recipient_id').eq('status', 'accepted')
    .or(`sender_id.eq.${me},recipient_id.eq.${me}`);
  const { data: blocks, error: blockError } = await admin.from('contact_blocks')
    .select('owner_id,blocked_id').or(`owner_id.eq.${me},blocked_id.eq.${me}`);
  if (linkError || blockError) return json({ error: 'Contact lookup failed.' }, 503);
  const blocked = new Set((blocks ?? []).map((r) => r.owner_id === me ? r.blocked_id : r.owner_id));
  const accepted = [...new Set((links ?? []).map((r) => r.sender_id === me ? r.recipient_id : r.sender_id))]
    .filter((id) => !blocked.has(id));
  if (kind === 'group') {
    groupId = typeof body.group === 'string' ? body.group : '';
    const event = typeof body.event === 'string' ? body.event : '';
    if (!/^[0-9a-f-]{36}$/.test(groupId) || !/^[0-9a-f-]{36}$/.test(event)) {
      return json({ error: 'Invalid group event.' }, 400);
    }
    const { data: membership, error: memberError } = await admin.from('conversation_members')
      .select('user_id,is_muted,muted_until,joined_at').eq('conversation_id', groupId);
    if (memberError) return json({ error: 'Membership lookup failed.' }, 503);
    if (!membership?.some((m) => m.user_id === me)) return json({ delivered: 0 });
    const { data: eventRow, error: eventError } = await admin.from('group_messages')
      .select('id,created_at').eq('id', event).eq('conversation_id', groupId)
      .eq('sender_id', me).eq('is_deleted', false).gt('created_at', recent).maybeSingle();
    if (eventError) return json({ error: 'Group event lookup failed.' }, 503);
    if (!eventRow) return json({ delivered: 0 });
    const { data: group, error: groupError } = await admin.from('conversations')
      .select('title').eq('id', groupId).maybeSingle();
    if (groupError || !group) return json({ error: 'Group lookup failed.' }, 503);
    groupName = group.title || 'Group';
    eventId = eventRow.id;
    targets = membership.filter((m) => m.user_id !== me && !blocked.has(m.user_id) &&
      Date.parse(m.joined_at) <= Date.parse(eventRow.created_at) &&
      !(m.is_muted && (!m.muted_until || Date.parse(m.muted_until) > Date.now())))
      .map((m) => m.user_id);
  } else if (kind === "message" || kind === "call") {
    const peer = typeof body.peer === "string" ? body.peer : "";
    if (!/^[0-9a-f-]{36}$/.test(peer) || peer === me) {
      return json({ error: "Invalid peer." }, 400);
    }
    if (!accepted.includes(peer)) return json({ delivered: 0 });
    if (kind === 'call') {
      if (typeof body.invite !== 'string' || !/^[0-9a-f-]{36}$/.test(body.invite)) return json({ error: 'Invalid invite.' }, 400);
      const { data: invite } = await admin.from('call_invites').select('id,call_type,created_at')
        .eq('id', body.invite).eq('caller_id', me).eq('callee_id', peer).eq('status', 'ringing')
        .gt('created_at', new Date(Date.now() - 60000).toISOString())
        .gt('expires_at', new Date().toISOString()).maybeSingle();
      if (!invite) return json({ delivered: 0 });
      eventId = invite.id;
      video = invite.call_type === 'video';
    } else {
      // The caller cannot fabricate notification content or send a nudge
      // without a recent, authenticated message to this recipient.
      const { data: pending, error: pendingError } = await admin.from('message_envelopes')
        .select('client_message_id,created_at').eq('sender_id', me).eq('recipient_id', peer)
        .gt('created_at', recent).order('created_at', { ascending: false }).limit(1);
      const { data: acked, error: ackError } = await admin.from('envelope_receipts')
        .select('client_message_id,sent_at').eq('sender_id', me).eq('recipient_id', peer)
        .gt('sent_at', recent).order('sent_at', { ascending: false }).limit(1);
      if (pendingError || ackError) return json({ error: 'Message lookup failed.' }, 503);
      const events = [...(pending ?? []).map((r) => ({ id: r.client_message_id, at: r.created_at })),
        ...(acked ?? []).map((r) => ({ id: r.client_message_id, at: r.sent_at }))];
      events.sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
      if (!events.length) return json({ delivered: 0 });
      eventId = events[0].id;
    }
    targets = [peer];
  } else {
    const { data: statuses, error } = await admin.from('status_updates')
      .select('id,audience,audience_user_ids').eq('author_id', me).gt('created_at', recent)
      .gt('expires_at', new Date().toISOString()).order('created_at', { ascending: false }).limit(1);
    if (error) return json({ error: 'Status lookup failed.' }, 503);
    const status = statuses?.[0];
    if (!status) return json({ delivered: 0 });
    eventId = status.id;
    const audience: string[] = status.audience_user_ids ?? [];
    targets = accepted.filter((id) => status.audience === 'contacts' ||
      (status.audience === 'only' && audience.includes(id)) ||
      (status.audience === 'except' && !audience.includes(id)));
  }
  if (targets.length === 0) return json({ delivered: 0 });

  const { data: tokens, error: tokenError } = await admin
    .from("push_tokens")
    .select("token,user_id")
    .in("user_id", targets);
  if (tokenError) return json({ error: 'Device lookup failed.' }, 503);
  if (!tokens?.length) return json({ delivered: 0, reason: 'no_registered_devices' });

  const data: Record<string, string> =
    kind === 'group'
      ? { kind, peer: me, group: groupId, name: groupName }
      : kind === "message"
      ? { kind, peer: me, name: myName }
      : kind === "call"
        ? {
            kind,
            peer: me,
            invite: typeof body.invite === "string" ? body.invite : "",
            video: video ? "true" : "false",
            name: myName,
          }
        : { kind, peer: me, name: myName, snippet: "" };

  let access: string;
  try {
    access = await googleAccessToken({
      client_email: sa.client_email,
      private_key: sa.private_key,
      token_uri: sa.token_uri ?? "https://oauth2.googleapis.com/token",
    });
  } catch {
    return json({ error: "FCM authentication failed." }, 502);
  }

  let delivered = 0;
  let failed = 0;
  for (const { token, user_id: recipient } of tokens) {
    const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token));
    const deviceHash = b64urlBytes(new Uint8Array(hash));
    const { data: claimed, error } = await admin.rpc('claim_device_notification',
      { p_actor: me, p_recipient: recipient, p_kind: kind, p_event: eventId, p_device_hash: deviceHash });
    if (error) return json({ error: 'Dispatch registration failed.' }, 503);
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
            message: { token, data: { ...data, event: eventId, recipient }, android: { priority: "high", ttl: kind === 'call' ? '60s' : '3600s' } },
          }),
        },
      );
      if (res.ok) {
        delivered++;
        await admin.from('device_notification_dispatches').update({ sent: true })
          .eq('actor_id', me).eq('recipient_id', recipient).eq('kind', kind).eq('event_id', eventId)
          .eq('device_hash', deviceHash);
      } else {
        failed++;
        const failure = await res.json().catch(() => null);
        if (failure?.error?.details?.some((d: { errorCode?: string }) => d.errorCode === 'UNREGISTERED')) {
          await admin.from('push_tokens').delete().eq('token', token).eq('user_id', recipient);
        }
      }
    } catch {
      failed++;
    }
  }
  return json({ delivered, failed }, failed && !delivered ? 502 : 200);
});
