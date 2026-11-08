// Service worker van Tom's Receptenboek: bewaart de app-bestanden op het toestel,
// zodat de app ook zonder internet opent. Gegevens (recepten, lijst) bewaart de app zelf.
const CACHE = "receptenboek-v2";
const PHOTOS = "receptenboek-fotos-v1";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icon.png", "./icon-512.png"];
const CDN = ["cdn.jsdelivr.net", "fonts.googleapis.com", "fonts.gstatic.com"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE && k !== PHOTOS).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);

  // Receptfoto's: de link verandert bij elke start (tijdelijke toegangscode), de foto zelf niet.
  // Bewaar ze op naam, zodat elke foto maar één keer wordt gedownload (en ook offline te zien is).
  if (url.pathname.includes("/storage/v1/object/") && url.pathname.includes("/recipe-photos/")) {
    const key = url.origin + url.pathname.replace("/object/sign/", "/object/");
    e.respondWith(caches.open(PHOTOS).then((c) => c.match(key).then((hit) => hit || fetch(req).then((res) => {
      if (res.ok || res.type === "opaque") c.put(key, res.clone());
      return res;
    }))));
    return;
  }

  // De app zelf: eerst online (dan krijg je altijd de nieuwste versie), anders de bewaarde versie
  if (url.origin === location.origin && (req.mode === "navigate" || url.pathname.endsWith(".html") || url.pathname.endsWith("/"))) {
    e.respondWith(fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put("./index.html", copy)); }
      return res;
    }).catch(() => caches.match("./index.html")));
    return;
  }
  // Iconen en manifest: bewaarde versie, op de achtergrond bijwerken
  if (url.origin === location.origin) {
    e.respondWith(caches.match(req).then((hit) => {
      const net = fetch(req).then((res) => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return res; }).catch(() => hit);
      return hit || net;
    }));
    return;
  }
  // Bibliotheek en lettertypen: bewaarde versie, op de achtergrond bijwerken
  if (CDN.includes(url.hostname)) {
    e.respondWith(caches.match(req).then((hit) => {
      const net = fetch(req).then((res) => { if (res.ok || res.type === "opaque") { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return res; }).catch(() => hit);
      return hit || net;
    }));
  }
  // Al het andere (Supabase: recepten, inloggen) gaat gewoon via internet
});
