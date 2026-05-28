// SatoFinder service worker — cache-first, version-pinned.
// By SmartLedger Technology (https://smartledger.technology).
//
// Pre-caches the single-file app + the four SRI-pinned @smartledger/bsv@3.4.3
// CDN bundles, so the wallet works offline AND the exact pinned bundle bytes
// are frozen in the user's browser. SRI on the <script> tags still validates
// every served byte regardless of where the response came from (CDN or cache).
//
// Bump CACHE on every release — old caches are evicted in `activate`.
const CACHE = 'satofinder-v2.0.0';

const CORE = [
  './',
  './index.html',
  './manifest.json',
  './logo2.png',
];

const CDN = [
  'https://cdn.jsdelivr.net/npm/@smartledger/bsv@3.4.3/bsv.min.js',
  'https://cdn.jsdelivr.net/npm/@smartledger/bsv@3.4.3/bsv-mnemonic.min.js',
  'https://cdn.jsdelivr.net/npm/@smartledger/bsv@3.4.3/bsv-message.min.js',
  'https://cdn.jsdelivr.net/npm/@smartledger/bsv@3.4.3/bsv-ecies.min.js',
];

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // Core: must succeed. CDN: best-effort (offline install still OK).
    await cache.addAll(CORE);
    await Promise.allSettled(CDN.map(url =>
      fetch(url, { mode: 'cors', credentials: 'omit' })
        .then(r => r.ok && cache.put(url, r.clone()))
    ));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Never intercept API calls — wallet must always see live network errors.
  if (url.hostname === 'api.whatsonchain.com' || url.hostname === 'api.bitails.io') return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE);
    const cached = await cache.match(req, { ignoreSearch: false });
    if (cached) return cached;
    try {
      const fresh = await fetch(req);
      // Cache GETs from same origin + the pinned CDN bundles only.
      const isCdnBundle = CDN.includes(url.href);
      if ((url.origin === self.location.origin || isCdnBundle) && fresh.ok) {
        cache.put(req, fresh.clone());
      }
      return fresh;
    } catch (e) {
      // Offline + no cache → return a minimal HTML for navigations.
      if (req.mode === 'navigate') {
        return new Response('<h1>Offline</h1><p>SatoFinder is offline and not cached.</p>',
          { headers: { 'Content-Type': 'text/html' } });
      }
      throw e;
    }
  })());
});
