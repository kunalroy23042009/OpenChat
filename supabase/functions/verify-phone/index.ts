// Phone-number login via Firebase OTP (free quota) bridged to Supabase.
// The app verifies the SMS code with Firebase, then posts the Firebase ID
// token here. This function validates the token against Google's certs,
// ensures a Supabase user for the verified number, and returns a
// single-use email OTP the client exchanges for a real session with
// verifyOtp(email, magiclink). The Firebase token and phone number never
// leave this exchange; nothing is logged.
// Requires verify_jwt=false (callers are not signed in yet).
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const FIREBASE_PROJECT = "openchat-511108-704cb";
const CERTS_URL =
  "https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

let certsCache: { at: number; certs: Record<string, string> } | null = null;

function b64ToBytes(b64: string): Uint8Array {
  const raw = atob(b64);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

function b64urlDecode(input: string): Uint8Array {
  const s = input.replace(/-/g, "+").replace(/_/g, "/");
  return b64ToBytes(s + "=".repeat((4 - (s.length % 4)) % 4));
}

/// Minimal DER reader (fail-closed): returns [contentStart, contentEnd].
function derChild(buf: Uint8Array, off: number, expectTag: number): [number, number] {
  if (off + 2 > buf.length || buf[off] !== expectTag) throw new Error("bad cert");
  let len = buf[off + 1];
  let pos = off + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n < 1 || n > 4 || pos + n > buf.length) throw new Error("bad cert");
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | buf[pos++];
  }
  if (pos + len > buf.length) throw new Error("bad cert");
  return [pos, pos + len];
}

/// Extracts the subjectPublicKeyInfo TLV from a DER X.509 certificate so
/// WebCrypto can import it (spki). Walks tbsCertificate children in order.
function spkiFromCert(der: Uint8Array): Uint8Array {
  let [s, e] = derChild(der, 0, 0x30);
  let [ts, te] = derChild(der, s, 0x30);
  void e;
  let p = ts;
  const skip = (): void => {
    const [cs, ce] = derChild(der, p, der[p]);
    void cs;
    p = ce;
  };
  if (der[p] === 0xa0) skip(); // [0] version
  skip(); // serial INTEGER
  skip(); // signature SEQ
  skip(); // issuer SEQ
  skip(); // validity SEQ
  skip(); // subject SEQ
  const [, se] = derChild(der, p, 0x30); // subjectPublicKeyInfo SEQ
  void te;
  return der.slice(p, se); // full TLV: tag + length + value
}

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  return b64ToBytes(body);
}

async function verifiedPhone(idToken: string): Promise<string> {
  const parts = idToken.split(".");
  if (parts.length !== 3) throw new Error("bad token");
  const header = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[0]))) as {
    kid?: string;
    alg?: string;
  };
  if (!header.kid || header.alg !== "RS256") throw new Error("bad token");
  if (!certsCache || Date.now() - certsCache.at > 3600000) {
    const res = await fetch(CERTS_URL, { signal: AbortSignal.timeout(10000) });
    if (!res.ok) throw new Error("certs unavailable");
    certsCache = { at: Date.now(), certs: await res.json() };
  }
  const pem = certsCache.certs[header.kid];
  if (!pem) throw new Error("unknown key");
  const key = await crypto.subtle.importKey(
    "spki",
    spkiFromCert(pemToDer(pem)),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    b64urlDecode(parts[2]),
    signingInput,
  );
  if (!ok) throw new Error("bad signature");
  const payload = JSON.parse(new TextDecoder().decode(b64urlDecode(parts[1]))) as {
    aud?: unknown;
    iss?: unknown;
    exp?: unknown;
    phone_number?: unknown;
  };
  if (payload.aud !== FIREBASE_PROJECT ||
      payload.iss !== `https://securetoken.google.com/${FIREBASE_PROJECT}` ||
      typeof payload.exp !== "number" || payload.exp * 1000 < Date.now()) {
    throw new Error("bad claims");
  }
  if (typeof payload.phone_number !== "string" ||
      !/^\+[1-9][0-9]{7,14}$/.test(payload.phone_number)) {
    throw new Error("no verified number");
  }
  return payload.phone_number;
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceKey) {
    return json({ error: "Phone login is not configured yet." }, 503);
  }
  let body: { idToken?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  if (typeof body.idToken !== "string" || !body.idToken) {
    return json({ error: "Invalid request." }, 400);
  }
  let phone: string;
  try {
    phone = await verifiedPhone(body.idToken);
  } catch {
    return json({ error: "Phone verification failed." }, 401);
  }

  const admin = createClient(supabaseUrl, serviceKey);
  const digits = phone.replace(/\D/g, "");
  const email = `phone.${digits}@phone.openchat.local`;
  try {
    // Find an existing user by phone (pilot scale: single page suffices).
    let userId: string | null = null;
    let page = 1;
    for (;;) {
      const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 });
      if (error) throw error;
      const hit = data.users.find((u) =>
        (u as { phone?: string }).phone === phone || u.email === email);
      if (hit) {
        userId = hit.id;
        await admin.auth.admin.updateUserById(hit.id, {
          phone,
          phone_confirm: true,
          user_metadata: { phone, verified_via: "firebase" },
        });
        break;
      }
      if (data.users.length < 100) break;
      page++;
      if (page > 20) break;
    }
    if (!userId) {
      const { data, error } = await admin.auth.admin.createUser({
        email,
        email_confirm: true,
        phone,
        phone_confirm: true,
        user_metadata: { phone, verified_via: "firebase" },
      });
      if (error || !data.user) throw error ?? new Error("create failed");
      userId = data.user.id;
    }
    await admin.from("profiles").update({ phone_number: phone }).eq("id", userId);
    const { data: link, error: linkError } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    if (linkError) throw linkError;
    const otp = (link.properties as { email_otp?: unknown }).email_otp;
    if (typeof otp !== "string" || !otp) throw new Error("link failed");
    return json({ email, otp });
  } catch {
    return json({ error: "Phone login failed. Try again." }, 503);
  }
});
