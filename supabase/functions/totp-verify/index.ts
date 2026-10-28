import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return json({ error: "2FA not configured" }, 503);
  }

  let body: { code?: string; user_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON" }, 400);
  }

  const code = body.code?.trim();
  const userId = body.user_id;
  if (!code || code.length !== 6 || !/^\d{6}$/.test(code)) {
    return json({ error: "Enter a valid 6-digit code" }, 400);
  }

  const admin = createClient(supabaseUrl, serviceKey);

  // Find user if user_id not provided (fallback to current JWT)
  let targetUserId = userId;
  if (!targetUserId) {
    const authHeader = req.headers.get("Authorization");
    if (authHeader?.startsWith("Bearer ")) {
      const token = authHeader.slice(7);
      const { data: { user }, error } = await admin.auth.getUser(token);
      if (error || !user) return json({ error: "Invalid session" }, 401);
      targetUserId = user.id;
    }
  }
  if (!targetUserId) return json({ error: "User not identified" }, 400);

  // Fetch TOTP secret
  const { data: pref, error: prefErr } = await admin
    .from("user_preferences")
    .select("totp_secret, totp_enabled")
    .eq("user_id", targetUserId)
    .maybeSingle();

  if (prefErr || !pref?.totp_enabled || !pref?.totp_secret) {
    return json({ error: "2FA not enabled for this account" }, 400);
  }

  // Verify TOTP using the same logic as the DB function
  const secret = pref.totp_secret;
  const timeStep = Math.floor(Date.now() / 1000 / 30);
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    base32ToBytes(secret),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"]
  );
  const hmac = new Uint8Array(await crypto.subtle.sign(
    "HMAC",
    key,
    new BigInt64Array([BigInt(timeStep)])
  ));
  const offset = hmac[19] & 0x0f;
  const otp = ((hmac[offset] & 0x7f) << 24 |
               (hmac[offset + 1] & 0xff) << 16 |
               (hmac[offset + 2] & 0xff) << 8 |
               (hmac[offset + 3] & 0xff)) % 1_000_000;
  const expected = otp.toString().padStart(6, "0");

  if (code !== expected) {
    return json({ error: "Invalid code" }, 401);
  }

  // Set a short-lived claim so the next password/email change passes the RLS gate
  await admin.auth.admin.updateUserById(targetUserId, {
    user_metadata: { totp_verified: true, totp_verified_at: Date.now() },
  });

  return json({ success: true });
});

function base32ToBytes(base32: string): Uint8Array {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0, value = 0;
  const out: number[] = [];
  for (const ch of base32.toUpperCase().replace(/=+$/, "")) {
    const idx = alphabet.indexOf(ch);
    if (idx === -1) continue;
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.push((value >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}