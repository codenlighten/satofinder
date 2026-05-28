# SatoFinder v2

By **[SmartLedger Technology](https://smartledger.technology)**.

Single-file, fully client-side BSV wallet with encrypted local storage, BIP32/BIP44 derivation, send, and coin recovery sweep.

Everything is in [`index.html`](index.html). Read every line.

## Quick start

```sh
# Serve locally (any static server)
python3 -m http.server 8000
# Open http://localhost:8000

# Or deploy: drop index.html + manifest.json + service-worker.js + logo2.png on any static host.
```

## Security model

- **Mnemonic encryption**: PBKDF2-SHA256 (310,000 iter) → AES-GCM, in `localStorage`. No plaintext seed leaves your browser.
- **Subresource Integrity (SRI)**: the four `@smartledger/bsv@3.4.3` CDN bundles are pinned by SHA-384. A compromised CDN can't ship modified JS.
- **Content-Security-Policy**: inline script is pinned by SHA-256. Outbound network limited to `api.whatsonchain.com` and `api.bitails.io`. No eval, no inline event handlers.
- **DOM safety**: zero `innerHTML` of API data. All third-party text rendered via `textContent`. Link `href`s validated against an allow-list.
- **Auto-lock**: clears in-memory wallet after 10 min idle, or when tab is hidden.
- **Hide-keys default**: WIF and mnemonic are not rendered into the DOM until you click "Show".
- **No password recovery**: forgot password = wipe vault + re-import mnemonic. The encrypted blob is the only source of truth.

## Important headers (deploy-time)

The meta-tag CSP ships with the file, but `frame-ancestors` only works as a real HTTP header. Add to your deploy:

```
# Netlify _headers, nginx add_header, Caddy header, etc.
X-Frame-Options: DENY
Content-Security-Policy: frame-ancestors 'none'
Referrer-Policy: no-referrer
Permissions-Policy: clipboard-write=(self)
```

## Files

| file | purpose |
|---|---|
| `index.html` | the entire wallet — HTML + CSS + JS in one file (~1,500 lines) |
| `service-worker.js` | cache-first SW; pre-caches index + pinned CDN bundles for offline use |
| `manifest.json` | PWA manifest |
| `help.html` | user-facing docs |
| `build.sh` | recomputes the inline-script CSP hash after every edit; verifies SRI drift |
| `spike.html` | Phase 0 SDK + crypto smoke tests (open in a browser) |
| `logo2.png` | PWA icon + favicon |

## After editing `index.html`

```sh
./build.sh            # patches CSP hash; checks live CDN SRI drift
./build.sh --no-network   # skip the network check
```

The browser will refuse the inline script if you change it without re-running `build.sh`.

## Disclaimer

Free, as-is, no warranty. Test with small amounts first. The author is not responsible for loss of funds.
