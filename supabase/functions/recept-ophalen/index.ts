// Edge Function: haalt een receptpagina op en geeft het recept terug in het formaat van de app.
// Alleen voor ingelogde gebruikers van de recepten-app.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import { parseRecipeHtml } from "./recipe.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const MAX_HTML = 5 * 1024 * 1024;
const MAX_IMAGE = 6 * 1024 * 1024;
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// Alleen gewone websites: geen interne adressen of IP-nummers
function safeUrl(raw: string): URL | null {
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  const h = u.hostname.toLowerCase();
  if (!h.includes(".") || h === "localhost" || h.endsWith(".local") || h.endsWith(".internal") || h.endsWith(".localhost")) return null;
  if (/^[\d.]+$/.test(h) || h.includes(":") || h.startsWith("[")) return null;
  if (u.username || u.password) return null;
  return u;
}

async function safeFetch(start: URL, accept: string): Promise<Response> {
  let url = start;
  for (let i = 0; i < 4; i++) {
    const res = await fetch(url, {
      redirect: "manual",
      headers: { "User-Agent": UA, "Accept": accept, "Accept-Language": "nl-NL,nl;q=0.9,en;q=0.6" },
      signal: AbortSignal.timeout(12000),
    });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      const next = safeUrl(new URL(res.headers.get("location")!, url).toString());
      if (!next) throw new Error("De pagina verwijst door naar een adres dat niet is toegestaan.");
      url = next;
      continue;
    }
    return res;
  }
  throw new Error("De pagina verwijst te vaak door.");
}

async function readLimited(res: Response, max: number): Promise<Uint8Array> {
  const reader = res.body!.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > max) { await reader.cancel(); throw new Error("too_large"); }
    chunks.push(value);
  }
  const out = new Uint8Array(size);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}

function toBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Gebruik POST." }, 405);

  // 1. Is dit een ingelogde gebruiker?
  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Log eerst in." }, 401);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data: userData, error: userError } = await sb.auth.getUser(token);
  if (userError || !userData?.user) return json({ error: "Je sessie is verlopen. Log opnieuw in." }, 401);

  // 2. Link controleren
  let body: { url?: string };
  try { body = await req.json(); } catch { return json({ error: "Geen link ontvangen." }, 400); }
  const url = safeUrl(String(body.url || "").trim());
  if (!url) return json({ error: "Dit is geen geldige link. Kopieer de volledige link, beginnend met https://." }, 400);

  // 3. Pagina ophalen en recept zoeken
  let html: string;
  try {
    const res = await safeFetch(url, "text/html,application/xhtml+xml");
    if (!res.ok) return json({ error: `De website gaf een foutmelding (${res.status}). Probeer het later nog eens, of plak de tekst van het recept.` }, 502);
    html = new TextDecoder().decode(await readLimited(res, MAX_HTML));
  } catch (e) {
    const msg = (e as Error).message;
    return json({ error: msg === "too_large" ? "Deze pagina is te groot om in te lezen." : msg.startsWith("De pagina") ? msg : "De website reageerde niet. Controleer de link of probeer het later nog eens." }, 502);
  }
  const recipe = parseRecipeHtml(html, url.toString());
  if (!recipe) return json({ error: "Op deze pagina staat geen recept dat de app kan lezen. Kopieer de tekst van het recept en plak die in plaats van de link." }, 422);

  // 4. Foto meesturen (de app verkleint hem daarna)
  let image: string | null = null;
  const imgUrl = recipe.image_url ? safeUrl(new URL(recipe.image_url, url).toString()) : null;
  if (imgUrl) {
    try {
      const res = await safeFetch(imgUrl, "image/jpeg,image/webp,image/png,image/*");
      const type = (res.headers.get("content-type") || "").split(";")[0];
      if (res.ok && type.startsWith("image/")) image = `data:${type};base64,${toBase64(await readLimited(res, MAX_IMAGE))}`;
    } catch { /* zonder foto verder */ }
  }

  return json({ recipe: { ...recipe, image } });
});
