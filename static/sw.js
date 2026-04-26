const CACHE_NAME = "fund-lens-v2";
const APP_ASSETS = [
  "/",
  "/static/index.html",
  "/static/styles.css",
  "/static/app.js",
  "/static/manifest.webmanifest",
  "/static/icon.svg",
  "/static/icon-180.png",
  "/static/icon-192.png",
  "/static/icon-512.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_ASSETS)));
});

self.addEventListener("fetch", (event) => {
  if (event.request.url.includes("/api/")) return;
  event.respondWith(
    caches.match(event.request).then((cached) => cached || fetch(event.request))
  );
});
