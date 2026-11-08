// Leest een recept uit de HTML van een receptpagina (schema.org Recipe in JSON-LD).
// Puur JavaScript zonder afhankelijkheden, zodat het in Deno en Node te testen is.

const FRAC = { "½": 0.5, "⅓": 1 / 3, "⅔": 2 / 3, "¼": 0.25, "¾": 0.75, "⅛": 0.125 };
const UNITS = [
  ["naar smaak", "naar smaak"], ["eetlepels", "el"], ["eetlepel", "el"], ["theelepels", "tl"], ["theelepel", "tl"],
  ["gram", "g"], ["gr", "g"], ["g", "g"], ["kilogram", "kg"], ["kg", "kg"], ["milliliter", "ml"], ["ml", "ml"],
  ["cl", "cl"], ["dl", "dl"], ["liter", "l"], ["l", "l"], ["el", "el"], ["tl", "tl"],
  ["stuk(s)", "stuk"], ["stuks", "stuk"], ["stuk", "stuk"], ["zakje(s)", "zakje"], ["zakjes", "zakje"], ["zakje", "zakje"],
  ["teen(tjes)", "teen"], ["tenen", "teen"], ["teentjes", "teen"], ["teentje", "teen"], ["teen", "teen"],
  ["blik(ken)", "blik"], ["blikken", "blik"], ["blik", "blik"], ["pak(ken)", "pak"], ["pakje(s)", "pakje"], ["pakje", "pakje"],
  ["bos(sen)", "bos"], ["bosje(s)", "bosje"], ["bosje", "bosje"], ["bos", "bos"], ["takje(s)", "takje"], ["takjes", "takje"], ["takje", "takje"],
  ["snuf(je)", "snufje"], ["snufje", "snufje"], ["snuf", "snufje"], ["scheutje", "scheutje"], ["scheut", "scheutje"],
  ["handje(s)", "handje"], ["handje", "handje"], ["plak(ken)", "plak"], ["plakjes", "plakje"], ["plakken", "plak"], ["plak", "plak"],
  ["sneetje(s)", "sneetje"], ["sneetjes", "sneetje"], ["sneetje", "sneetje"], ["cup", "cup"], ["cups", "cup"], ["tbsp", "el"], ["tsp", "tl"],
];

const decodeEntities = (s) => String(s ?? "")
  .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n))
  .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
  .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'");
const clean = (s) => decodeEntities(String(s ?? "").replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ").trim();

function findRecipe(node) {
  if (!node || typeof node !== "object") return null;
  if (Array.isArray(node)) { for (const n of node) { const r = findRecipe(n); if (r) return r; } return null; }
  const t = node["@type"];
  if (t === "Recipe" || (Array.isArray(t) && t.includes("Recipe"))) return node;
  if (node["@graph"]) return findRecipe(node["@graph"]);
  return null;
}

export function parseIngredient(line) {
  const text = clean(line);
  const m = text.match(/^(\d+(?:[.,]\d+)?(?:\s*[-–]\s*\d+(?:[.,]\d+)?)?)?\s*([½⅓⅔¼¾⅛])?\s*(?:\/\s*\d+)?\s*(.*)$/);
  let amount = null;
  let rest = text;
  if (m && (m[1] || m[2])) {
    const first = m[1] ? parseFloat(m[1].split(/[-–]/)[0].replace(",", ".")) : 0;
    amount = Math.round((first + (m[2] ? FRAC[m[2]] : 0)) * 1000) / 1000;
    rest = m[3];
    const frac = text.match(/^(\d+)\s*\/\s*(\d+)\s+(.*)$/);
    if (frac) { amount = Math.round((+frac[1] / +frac[2]) * 1000) / 1000; rest = frac[3]; }
  }
  let unit = null;
  const low = rest.toLowerCase();
  for (const [word, norm] of UNITS) {
    if (low === word || low.startsWith(word + " ")) { unit = norm; rest = rest.slice(word.length).trim(); break; }
  }
  const name = rest ? rest.charAt(0).toUpperCase() + rest.slice(1) : text;
  const original = text.slice(0, text.length - rest.length).trim();
  return { name, amount, unit, original_text: original || null };
}

function steps(instr) {
  const out = [];
  const walk = (x, section) => {
    if (!x) return;
    if (typeof x === "string") {
      for (const part of clean(x).split(/\n+/)) if (part.trim()) out.push({ title: section || "", text: part.trim() });
      return;
    }
    if (Array.isArray(x)) { x.forEach((y) => walk(y, section)); return; }
    const t = x["@type"];
    if (t === "HowToSection") { walk(x.itemListElement, clean(x.name)); return; }
    if (x.itemListElement) { walk(x.itemListElement, section); return; }
    const text = clean(x.text || x.name || "");
    if (text) out.push({ title: x.name && x.text && clean(x.name) !== text ? clean(x.name) : (section || ""), text });
  };
  walk(instr, "");
  // Sectienaam alleen bij de eerste stap van een sectie tonen
  for (let i = out.length - 1; i > 0; i--) if (out[i].title && out[i].title === out[i - 1].title) out[i].title = "";
  return out;
}

function minutes(iso) {
  const m = String(iso || "").match(/^P(?:\d+D)?T?(?:(\d+)H)?(?:(\d+)M)?/i);
  if (!m) return null;
  const v = (+(m[1] || 0)) * 60 + (+(m[2] || 0));
  return v || null;
}

function imageUrl(img) {
  if (!img) return null;
  if (typeof img === "string") return img;
  if (Array.isArray(img)) return imageUrl(img[0]);
  return img.url || img.contentUrl || null;
}

// Geen receptblok op de pagina: pak de beschrijving (bij Instagram het onderschrift van de post)
function meta(html, key) {
  for (const tag of html.match(/<meta\b[^>]*>/gi) || []) {
    const k = tag.match(/(?:property|name)\s*=\s*["']([^"']+)["']/i);
    if (!k || k[1].toLowerCase() !== key) continue;
    const c = tag.match(/content\s*=\s*"([^"]*)"/i) || tag.match(/content\s*=\s*'([^']*)'/i);
    if (c) return decodeEntities(c[1]);
  }
  return "";
}
// Instagram zet voor het onderschrift: '123 likes, 4 comments - naam on 1 November 2026: "…"' (of in het Nederlands)
function stripSocialPrefix(text) {
  const m = String(text || "").match(/^[^"“]{0,240}?:\s*["“]([\s\S]+?)["”]\.?\s*$/);
  return m ? m[1] : String(text || "");
}
const tidy = (t) => String(t || "").replace(/\r/g, "").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
// Onderschrift uit de JSON die Instagram in de pagina meestuurt (vaak vollediger dan de beschrijving)
function jsonCaptions(html) {
  const out = [];
  const res = [/"caption"\s*:\s*\{[^{}]*?"text"\s*:\s*"((?:[^"\\]|\\.)*)"/g, /"edge_media_to_caption"\s*:\s*\{\s*"edges"\s*:\s*\[\s*\{\s*"node"\s*:\s*\{\s*"text"\s*:\s*"((?:[^"\\]|\\.)*)"/g];
  for (const re of res) for (const m of html.matchAll(re)) { try { out.push(JSON.parse(`"${m[1]}"`)); } catch { /* overslaan */ } }
  return out;
}
export function parseFallbackText(html) {
  const candidates = [
    { from: "og", text: stripSocialPrefix(meta(html, "og:description")) },
    { from: "meta", text: stripSocialPrefix(meta(html, "description")) },
    { from: "twitter", text: stripSocialPrefix(meta(html, "twitter:description")) },
    ...jsonCaptions(html).map((t) => ({ from: "json", text: t })),
  ].map((c) => ({ ...c, text: tidy(c.text) })).filter((c) => c.text);
  if (!candidates.length) return null;
  candidates.sort((a, b) => b.text.length - a.text.length); // de langste is meestal het volledige onderschrift
  return { text: candidates[0].text, from: candidates[0].from, image_url: meta(html, "og:image") || null };
}
// Instagram 'embed'-pagina (bedoeld om posts op andere sites te tonen): het onderschrift staat in <div class="Caption">
export function parseInstagramEmbed(html) {
  const m = html.match(/<div[^>]*class="[^"]*\bCaption\b[^"]*"[^>]*>([\s\S]*?)<div[^>]*class="[^"]*\bCaptionComments\b/i)
    || html.match(/<div[^>]*class="[^"]*\bCaption\b[^"]*"[^>]*>([\s\S]*?)<\/div>/i);
  if (!m) return null;
  let h = m[1].replace(/<a[^>]*class="[^"]*\bCaptionUsername\b[^"]*"[^>]*>[\s\S]*?<\/a>/i, "");
  h = h.replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]+>/g, "");
  const text = tidy(decodeEntities(h));
  const img = (html.match(/<img[^>]*class="[^"]*\bEmbeddedMediaImage\b[^"]*"[^>]*src="([^"]+)"/i) || [])[1];
  return text ? { text, from: "embed", image_url: img ? decodeEntities(img) : null } : null;
}
// Ziet de tekst eruit als een recept? (genoeg regels, en iets wat op ingrediënten lijkt)
export function looksLikeRecipe(text) {
  const lines = String(text || "").split("\n").map((l) => l.trim()).filter(Boolean);
  if (text.length < 80 || lines.length < 4) return false;
  const qty = lines.filter((l) => /(^|\s)(\d+([.,/]\d+)?|[½⅓⅔¼¾⅛])\s*(g|gr|gram|kg|ml|l|dl|cl|el|tl|eetlepels?|theelepels?|cups?|tbsp|tsp|stuks?|tenen|teen)?\b/i.test(l)).length;
  const head = /(ingredi[eë]nt|wat heb je nodig|boodschappen|benodigdheden|bereiding|zo maak je|method|instructions)/i.test(text);
  return qty >= 3 || head;
}

export function parseRecipeHtml(html, pageUrl) {
  const blocks = [...html.matchAll(/<script[^>]*type=["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script>/gi)].map((m) => m[1]);
  let recipe = null;
  for (const b of blocks) {
    try { recipe = findRecipe(JSON.parse(decodeEntities(b.trim()))) || findRecipe(JSON.parse(b.trim())); }
    catch { try { recipe = findRecipe(JSON.parse(b.trim())); } catch { /* ongeldig blok overslaan */ } }
    if (recipe) break;
  }
  if (!recipe) return null;

  let title = clean(recipe.name);
  let subtitle = "";
  const h1 = clean((html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i) || [])[1] || "");
  if (h1 && title.length > h1.length + 3 && title.toLowerCase().startsWith(h1.toLowerCase())) {
    subtitle = title.slice(h1.length).trim();
    title = h1;
  }
  const y = recipe.recipeYield;
  const servings = parseInt(Array.isArray(y) ? y[0] : y, 10) || 2;
  const time = minutes(recipe.totalTime) || ((minutes(recipe.prepTime) || 0) + (minutes(recipe.cookTime) || 0)) || null;
  const toList = (v) => (Array.isArray(v) ? v : v ? String(v).split(",") : []).map((s) => clean(s).toLowerCase()).filter(Boolean);
  const tags = [...new Set([...toList(recipe.recipeCuisine), ...toList(recipe.recipeCategory)])]
    .filter((t) => t.length <= 20 && !["hoofdgerecht", "main course", "diner", "dinner"].includes(t));

  return {
    title,
    subtitle,
    servings: Math.min(Math.max(servings, 1), 20),
    prep_time_minutes: time,
    ingredients: (recipe.recipeIngredient || recipe.ingredients || []).map(parseIngredient).filter((i) => i.name),
    steps: steps(recipe.recipeInstructions),
    tips: [],
    tags,
    source_url: pageUrl,
    description: clean(recipe.description),
    image_url: imageUrl(recipe.image),
  };
}
