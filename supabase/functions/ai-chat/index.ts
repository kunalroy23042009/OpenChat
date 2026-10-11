// OpenChat AI: keyless assistant proxy. Users authenticate with their
// OpenChat (Supabase) sign-in — no per-user API keys. One server Gemini
// key (GEMINI_API_KEY secret) serves everyone behind a 50/day/user quota.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

serve(async (req) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "Sign in to use OpenChat AI." }, 401);

  let payload: { prompt?: unknown; history?: unknown };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid request." }, 400);
  }
  const prompt = typeof payload.prompt === "string" ? payload.prompt.trim() : "";
  if (!prompt || prompt.length > 4000) {
    return json({ error: "Empty message." }, 400);
  }
  const history = Array.isArray(payload.history)
    ? payload.history
        .filter(
          (m): m is { role: string; text: string } =>
            !!m &&
            typeof m === "object" &&
            typeof (m as { role?: unknown }).role === "string" &&
            typeof (m as { text?: unknown }).text === "string",
        )
        .slice(-6)
    : [];

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

  // Per-user daily quota, enforced with the caller's own identity.
  try {
    const quotaRes = await fetch(`${supabaseUrl}/rest/v1/rpc/ai_chat_quota`, {
      method: "POST",
      headers: {
        apikey: anonKey,
        Authorization: auth,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_limit: 50 }),
    });
    if (!quotaRes.ok) return json({ error: "Sign in to use OpenChat AI." }, 401);
    if (!(await quotaRes.json())) {
      return json(
        { error: "Daily AI limit reached (50 answers). Try again tomorrow." },
        429,
      );
    }
  } catch {
    return json({ error: "Account check failed. Try again." }, 503);
  }

  const geminiKey = Deno.env.get("GEMINI_API_KEY") ?? "";
  if (!geminiKey) return json({ error: "OpenChat AI is not configured yet." }, 503);

  const contents = [
    ...history.map((m) => ({
      role: m.role === "assistant" ? "model" : "user",
      parts: [{ text: m.text }],
    })),
    { role: "user", parts: [{ text: prompt }] },
  ];

  let reply: string;
  try {
    const geminiRes = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent?key=${geminiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          system_instruction: {
            parts: [
              {
                text: "You are OpenChat AI, a helpful assistant inside the OpenChat messaging app. Keep answers concise and friendly.",
              },
            ],
          },
          contents,
          generationConfig: { maxOutputTokens: 1024 },
        }),
      },
    );
    if (!geminiRes.ok) {
      return json({ error: "AI service is busy. Try again shortly." }, 502);
    }
    const data = await geminiRes.json();
    const parts = data?.candidates?.[0]?.content?.parts;
    reply =
      Array.isArray(parts) && parts.length > 0 && typeof parts[0]?.text === "string"
        ? parts[0].text.trim()
        : "No answer returned. Try again.";
  } catch {
    return json({ error: "AI service is unreachable. Try again." }, 502);
  }

  return json({ reply });
});
