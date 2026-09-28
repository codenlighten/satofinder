# SatoFinder v2

By **[SmartLedger Technology](https://smartledger.technology)**.

SatoFinder is a BSV wallet that runs entirely in your browser. It keeps an encrypted vault on the device, derives BIP32/BIP44 addresses, and can send. It can also find coins left on other derivation paths of a mnemonic and sweep them back.

Each page is a single HTML file with no build step and no server component. The only network calls are to public blockchain APIs.

| page | what it is |
|---|---|
| [`index.html`](index.html) | The main wallet ("Classic"). It has a password vault, send, per-address recovery sweeps, a token/ordinal view and history. |
| [`satofinder-modern.html`](satofinder-modern.html) | An alternate panelled interface with the same spending rules. Its recovery scan builds one consolidated transaction. |
| [`help.html`](help.html) | User documentation. |

## Run it locally

```sh
python3 -m http.server 8000     # any static server works
# open http://localhost:8000
```

## How it protects funds

- **Vault.** The mnemonic and optional BIP39 passphrase are encrypted with AES-GCM under a key from PBKDF2-SHA256 (600,000 iterations for new vaults; older vaults keep the count they were saved with), then stored in `localStorage`. They never leave the browser. There is no password recovery: if you forget the password, wipe the vault and re-import the mnemonic.
- **Backups.** "Download encrypted backup" saves the vault file; "Restore from backup file" reads one back (validated before any key derivation, then re-encrypted with a fresh salt at the current iteration count).
- **Replacing a vault** by create, import or restore asks you to type `REPLACE`, and offers to download the existing encrypted vault first.
- **Locking** happens after 10 minutes idle, 60 seconds after the tab is hidden (unless you come back first), or on demand. In the main wallet it clears the keys, recovery results, drafts and balances, and requests still in flight when the wallet locks are discarded when they return.
- **Ordinals and tokens are never spent as plain sats.** Before building any Send or sweep, every page of GorillaPool's unspent listing is checked, both plain and BSV-20, and each ordinal, BSV-20 and lock output is excluded. Every 1-sat output is also held back, in case the indexer hasn't seen a new ordinal yet. If the indexer is unreachable, or the listing can't be read completely, nothing is built.
- **You confirm before broadcasting.** Nothing is broadcast until you confirm a built, signed transaction. The confirmation shows its destination, amount and fee, and the raw hex is there to inspect.
- **Pinned code.**
  - The one external script, `@smartledger/bsv@7.1.0` from jsDelivr, is pinned by a SHA-384 SRI hash.
  - The inline script is pinned by its SHA-256 in the page's CSP.
  - The CSP allows network access only to `api.whatsonchain.com`, `api.bitails.io` and `ordinals.gorillapool.io`.
- **Clipboard.** A copied private key, recovery phrase or passphrase is cleared from the clipboard after 60 seconds or when the wallet locks, whichever is first.
- **DOM safety.** API data is rendered with `textContent`, never `innerHTML`.
- **No offline cache.** `service-worker.js` exists only to remove the old cache-first worker from browsers that still have it registered.

## Editing

Re-run `build.sh` after any change to a page's inline script. Otherwise the browser refuses to run it.

```sh
./build.sh                  # re-pin the inline-script CSP hash of each page; warn on CDN SRI drift
./build.sh --no-network     # skip the drift check
FILE=index.html ./build.sh  # one page only
```

Upgrading the SDK is deliberate: change the version in the `<script>` tag, update its `integrity` hash and the `TARGETS` list in `build.sh`, and run `build.sh`.

## Releasing

```sh
./make-tarball.sh           # runs build.sh, then a release-blocking SRI check, then writes dist/satofinder-v<VERSION>.tar.gz
```

The tarball is deterministic, so the printed SHA-256 can be compared across builds. `VERSION` comes from `const VERSION` in `index.html`.

`Dockerfile` builds that tarball and serves only the site's files from it (`index.html`, `satofinder-modern.html`, `help.html`, `service-worker.js`, `manifest.json`, `logo2.png`) with nginx. `nginx.conf` and `security-headers.conf` add the headers a meta-tag CSP can't set: `frame-ancestors`, `X-Frame-Options`, HSTS, `Referrer-Policy` and `Permissions-Policy`. `captain-definition` deploys the same image on CapRover. On any other static host, upload only those six files and set the equivalent headers.

## Other files

| file | purpose |
|---|---|
| `manifest.json`, `logo2.png` | PWA manifest and icon |
| `spike.html` | early SDK and crypto smoke tests (still on `@smartledger/bsv@3.4.3`); not shipped |
| `archive/` | an earlier version, kept for reference; not shipped |

## Disclaimer

Free and provided as-is, with no warranty. Test with small amounts first. The authors are not responsible for loss of funds.
