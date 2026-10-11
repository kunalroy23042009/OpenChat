// LiveKit access-token minter. The browser/app authenticates with its
// OpenChat (Supabase) session; the LiveKit API secret never leaves the
// server. Requires LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function b64url(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function hmacSha256(key: string, data: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(data));
  return new Uint8Array(sig);
}

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Sign in to call." }, 401);

  const livekitUrl = Deno.env.get("LIVEKIT_URL") ?? "";
  const apiKey = Deno.env.get("LIVEKIT_API_KEY") ?? "";
  const apiSecret = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  if (!livekitUrl || !apiKey || !apiSecret) {
    return json({ error: "Calling is not configured yet." }, 503);
  }

  let body: { room?: unknown; name?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  const room = typeof body.room === "string" ? body.room.trim() : "";
  if (!room || room.length > 128 || !/^dm_[0-9a-f-]{36}_[0-9a-f-]{36}$/.test(room)) {
    return json({ error: "Invalid room." }, 400);
  }

  // Validate the caller's session and bind the token to it.
  let userId: string;
  try {
    const meRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: anonKey, Authorization: auth },
    });
    if (!meRes.ok) return json({ error: "Sign in to call." }, 401);
    const me = await meRes.json();
    userId = me?.id as string;
    if (!userId) return json({ error: "Sign in to call." }, 401);
  } catch {
    return json({ error: "Account check failed. Try again." }, 503);
  }
  if (!room.includes(userId)) {
    return json({ error: "Not your call." }, 403);
  }
  const name =
    typeof body.name === "string" && body.name.trim() !== ""
      ? body.name.trim().slice(0, 60)
      : userId.slice(0, 8);

  const now = Math.floor(Date.now() / 1000);
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const payload = b64url(
    new TextEncoder().encode(
      JSON.stringify({
        iss: apiKey,
        sub: userId,
        name,
        nbf: now - 5,
        exp: now + 600,
        video: { roomJoin: true, room, canPublish: true, canSubscribe: true },
      }),
    ),
  );
  const sig = b64url(await hmacSha256(apiSecret, `${header}.${payload}`));
  return json({ url: livekitUrl, token: `${header}.${payload}.${sig}` });
});
