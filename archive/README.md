# archive/

Historical SatoFinder artifacts. **Nothing in here is deployed** — `make-tarball.sh`
ships an explicit allowlist, and this directory is not on it.

## satofinder-2024-wayback.html

The former `index.html` of satofinder.com, as captured by the Internet Archive on
2024-04-17 (`web.archive.org/web/20240417150411/https://satofinder.com/`).

**This is the capture, not the original source.** It is not runnable as-is:

- ~33 lines of archive.org toolbar markup and analytics are injected into `<head>`
  and `<body>`.
- Every asset URL is rewritten to `web.archive.org/web/20240417150411…/`, including
  the `bsv@1.5.0` bundles, so it only loads with the Wayback Machine reachable.

Kept because it is the provenance of the current app, and because it documents what
some users may still be running.

### Why it matters operationally

This version predates every safety property the current app has:

| | 2024 app | current |
|---|---|---|
| BSV library | `bsv@1.5.0` | `@smartledger/bsv@7.1.0`, SRI-pinned |
| Ordinal / BSV-20 spend protection | **none** | hard-blocks a Send it can't verify |
| BIP39 passphrase | none | yes |
| CSP / SRI | none | strict CSP + SHA-384 SRI |

It also registers a service worker at `/service-worker.js` — the same path the
current tombstone occupies. That is the hook that rescues anyone still cached on
this version: their page registers it, the tombstone evicts every cache and
unregisters, and the next load is the live app. See `service-worker.js`.

**Do not deploy this file.** Serving it would put a wallet with no ordinal
protection back in front of users, and re-register a worker we are retiring.
