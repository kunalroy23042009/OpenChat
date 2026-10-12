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
    pemToBytes(sa.private_key),
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

  let body: { kind?: unknown; peer?: unknown; invite?: unknown; video?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  const kind = body.kind;
  if (kind !== "message" && kind !== "call" && kind !== "status") {
    return json({ error: "Invalid kind." }, 400);
  }

  const supabase = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: auth } },
  });
  const { data: user } = await supabase.auth.getUser();
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
  if (kind === "message" || kind === "call") {
    const peer = typeof body.peer === "string" ? body.peer : "";
    if (!/^[0-9a-f-]{36}$/.test(peer) || peer === me) {
      return json({ error: "Invalid peer." }, 400);
    }
    const { data: allowed } = await admin.rpc("messaging_allowed", { a: me, b: peer });
    if (allowed !== true) return json({ delivered: 0 });
    targets = [peer];
  } else {
    // Status: fan out to every accepted contact (service role reads the
    // contact graph directly; list_my_contacts needs a user session).
    const { data: rows } = await admin
      .from("contact_requests")
      .select("sender_id,recipient_id")
      .eq("status", "accepted")
      .or(`sender_id.eq.${me},recipient_id.eq.${me}`);
    targets = (rows ?? []).map((r: { sender_id: string; recipient_id: string }) =>
      r.sender_id === me ? r.recipient_id : r.sender_id,
    );
  }
  if (targets.length === 0) return json({ delivered: 0 });

  const { data: tokens } = await admin
    .from("push_tokens")
    .select("token")
    .in_("user_id", targets);
  const deviceTokens = ((tokens ?? []) as { token: string }[]).map((t) => t.token);
  if (deviceTokens.length === 0) return json({ delivered: 0 });

  const data: Record<string, string> =
    kind === "message"
      ? { kind, peer: me, name: myName }
      : kind === "call"
        ? {
            kind,
            peer: me,
            invite: typeof body.invite === "string" ? body.invite : "",
            video: body.video === true ? "true" : "false",
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
  for (const token of deviceTokens) {
    try {
      const res = await fetch(
        `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${access}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            message: { token, data, android: { priority: "high" } },
          }),
        },
      );
      if (res.ok) delivered++;
    } catch {
      // One dead token must not fail the batch.
    }
  }
  return json({ delivered });
});
