// SatoFinder service worker — TOMBSTONE. Deliberately does nothing but delete
// its own caches and unregister itself.
// By SmartLedger Technology (https://smartledger.technology).
//
// WHY THERE IS NO SERVICE WORKER ANY MORE
//
// The old worker pre-cached the app and served it cache-first, and it only
// re-installed (and so only re-fetched the app) when THIS FILE's bytes changed.
// It was never bumped between v2.0.0 and v2.4.0, so every returning visitor
// kept running the v2.0.0 app: no BIP39 passphrase support, no 24-word entropy
// fix, and no ordinal/token spend protection — the last of which is the thing
// that stops a Send from burning an NFT. Four releases reached new visitors
// only. There was no error and nothing to notice; the app just quietly stayed
// old for the people who already had a wallet in it.
//
// That risk bought nothing. SatoFinder cannot do useful work offline — balance,
// UTXOs, history and broadcast all need the network, and a Send hard-blocks
// unless the ordinal indexer can confirm the UTXOs are safe to spend, so an
// offline SatoFinder can derive an address and nothing else. Nor did the cache
// protect the bundle: the SHA-384 SRI on the <script> tag validates those bytes
// wherever they came from. And a wallet is precisely the kind of app that must
// never be pinned to old code — a fix has to reach the people already using it,
// which is the one thing cache-first prevents.
//
// Want it offline? Save the page. It is a single self-contained file.
//
// This file STAYS rather than being deleted: deleting it would leave workers
// that are already registered alive, with their caches intact. Browsers
// re-check this URL for existing registrations, and the stale cached
// index.html calls register() itself — both paths pull in this tombstone,
// which then evicts every cache and unregisters. It can be dropped once
// traffic from pre-2.5.0 clients has died off.
//
// nginx serves this path with `Cache-Control: no-cache, must-revalidate`,
// which is what lets the tombstone reach those clients at all — keep that.

self.addEventListener('install', () => {
  // Take over immediately instead of waiting for every tab to close.
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    // 1. Evict everything the old worker cached, including the stale app HTML.
    const keys = await caches.keys();
    await Promise.all(keys.map(k => caches.delete(k)));

    // 2. Unregister, so nothing intercepts fetches from here on.
    await self.registration.unregister();

    // 3. Reload any open tab. Those tabs are by definition running HTML that
    //    came from the cache just deleted — possibly the v2.0.0 app. After the
    //    reload they get the live page from the network, and that page does not
    //    register a worker, so this cannot loop.
    const clients = await self.clients.matchAll({ type: 'window' });
    for (const client of clients) {
      if ('navigate' in client) client.navigate(client.url).catch(() => {});
    }
  })());
});

// No fetch handler, on purpose. Every request goes straight to the network.
