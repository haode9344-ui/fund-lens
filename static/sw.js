const CACHE_NAME = "fund-lens-v10";
const APP_ASSETS = [
  "/",
  "index.html",
  "styles.css",
  "app.js?v=10",
  "manifest.webmanifest",
  "icon.svg",
  "icon-180.png",
  "icon-192.png",
  "icon-512.png",
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
