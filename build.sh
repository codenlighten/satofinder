#!/usr/bin/env bash
# build.sh — single-file build step for SatoFinder v2.
#
# What it does, for each target page:
#   1. Extracts the *literal text content* of the single inline <script> in the
#      page — exactly what a browser computes a CSP hash over — and pins its
#      SHA-256 (base64) into the `script-src 'sha256-...'` directive of the CSP
#      meta tag. Re-run after every edit to a script body, otherwise the browser
#      refuses to execute it.
#
#   2. (Optional) Re-fetches that page's pinned @smartledger/bsv CDN bundles and
#      warns if any live hash drifts from what's currently baked into the SRI
#      attributes. Doesn't rewrite — drift requires a deliberate version bump,
#      which is the whole point of SRI.
#
# Targets are declared in TARGETS below as "file:sdk_version:bundle bundle ...".
# Each page is verified against its own pinned version — they are allowed to
# differ (they did while the alternate led the upgrade), so nothing here assumes
# they match.
#
# Idempotent: source file == output file. Re-run after every edit to an inline
# script block.
#
# Usage: ./build.sh [--no-network]      # --no-network skips the SRI drift check
#        FILE=index.html ./build.sh     # restrict to one target
#
# Requires: bash, python3, openssl, curl.

set -euo pipefail

# file : sdk_version : space-separated bundle basenames (without .min.js)
TARGETS=(
  "index.html:7.1.0:bsv"
  "satofinder-modern.html:7.1.0:bsv"
)

NO_NETWORK=0
[[ "${1:-}" == "--no-network" ]] && NO_NETWORK=1

drift_found=0

# --- 0a. Every locally-linked page must be in the deploy manifest ------------
# make-tarball.sh ships an explicit allowlist, so a new page is invisible to the
# deploy until it is added there. index.html linking to a page that was never
# packaged is a 404 in production and green everywhere else — which is exactly
# what happened when satofinder-modern.html was added.
if [[ -f make-tarball.sh ]]; then
  missing_art=0
  for page in $(grep -ohE 'href="[a-zA-Z0-9_.-]+\.html"' index.html satofinder-modern.html 2>/dev/null \
                | sed -E 's/href="([^"]+)"/\1/' | sort -u); do
    [[ -f "$page" ]] || continue
    if ! grep -qE "^[[:space:]]*${page}\$" make-tarball.sh; then
      echo "build.sh: FAIL — $page is linked but is not in make-tarball.sh ARTIFACTS." >&2
      echo "         It would 404 in production. Add it to the allowlist." >&2
      missing_art=1
    fi
  done
  [[ "$missing_art" -eq 0 ]] || exit 1
  echo "deploy manifest: every linked page is packaged"
  echo
fi

# --- 0. Service worker must stay a tombstone --------------------------------
# There is deliberately no service worker (see the comment in service-worker.js).
# The old one served the app cache-first and only refreshed when its own bytes
# changed, which silently pinned returning users to v2.0.0 across four releases
# — withholding the ordinal-burn protection from exactly the people who already
# had a wallet. It bought nothing: this wallet needs the network for every
# useful action, and SRI already guarantees the bundle bytes.
#
# Reinstating a cache is a decision to make deliberately, not something to
# rediscover in a year. Fail the build if caching or a registration reappears.
if [[ -f service-worker.js ]]; then
  if grep -qE 'caches\.open|cache\.addAll|cache\.put|addEventListener\(.fetch.' service-worker.js; then
    echo "build.sh: FAIL — service-worker.js caches or intercepts fetches again." >&2
    echo "         It is meant to be a tombstone. Cache-first serving of this app is what" >&2
    echo "         pinned users to v2.0.0 for four releases; read the comment in that file" >&2
    echo "         before removing this check." >&2
    exit 1
  fi
  if grep -q "serviceWorker.register" index.html satofinder-modern.html 2>/dev/null; then
    echo "build.sh: FAIL — a page registers a service worker again; see service-worker.js." >&2
    exit 1
  fi
  echo "service worker: tombstone only, no caching, no page registers it"
  echo
fi

for target in "${TARGETS[@]}"; do
  IFS=':' read -r file sdk_version bundles <<< "$target"

  # FILE=... restricts the run to a single target.
  if [[ -n "${FILE:-}" && "${FILE}" != "$file" ]]; then continue; fi
  [[ -f "$file" ]] || { echo "build.sh: $file not found, skipping" >&2; continue; }

  echo "=== $file  (@smartledger/bsv@${sdk_version}) ==="

  # --- 1. Inline-script CSP hash ---------------------------------------------
  # Hash the literal textContent of the (single) inline <script> element — the
  # exact bytes the browser hashes when evaluating the CSP sha256-... directive.
  script_hash=$(python3 - "$file" <<'PY'
import sys, re, hashlib, base64
html = open(sys.argv[1], 'rb').read().decode('utf-8')
# Strip HTML comments first. A browser never parses a <script> tag written
# inside a comment, so neither should we — prose like "the inline <script>
# block" in a comment would otherwise be picked up as a bogus second script
# and, worse, could shift which bytes get hashed.
html = re.sub(r'<!--[\s\S]*?-->', '', html)
# Match each <script>...</script> block; capture the inner text. Scripts with
# a `src=` attribute have empty inner text and are skipped.
blocks = re.findall(r'<script(?:\s[^>]*)?>([\s\S]*?)</script>', html)
inline = [b for b in blocks if b.strip()]
if len(inline) != 1:
    sys.exit(f"build.sh: expected exactly 1 inline script in {sys.argv[1]}, found {len(inline)}")
content = inline[0].encode('utf-8')
print(base64.b64encode(hashlib.sha256(content).digest()).decode())
PY
  )

  echo "  inline script sha256: $script_hash"

  # Substitute the hash into the CSP meta tag. Match either the unhashed
  # placeholder (`__SCRIPT_HASH__`) or a previously-pinned hash so re-runs work.
  if grep -q "__SCRIPT_HASH__" "$file"; then
    sed -i "s|__SCRIPT_HASH__|${script_hash}|g" "$file"
    echo "  pinned (placeholder replaced)"
  elif grep -qE "'sha256-[A-Za-z0-9+/=]+' https://cdn.jsdelivr.net" "$file"; then
    sed -i -E "s|'sha256-[A-Za-z0-9+/=]+' https://cdn.jsdelivr.net|'sha256-${script_hash}' https://cdn.jsdelivr.net|" "$file"
    echo "  pinned (existing hash updated)"
  else
    echo "  build.sh: no CSP placeholder or existing hash found in $file; nothing to substitute" >&2
  fi

  # --- 2. SRI drift check (network) ------------------------------------------
  if [[ "$NO_NETWORK" -eq 0 ]]; then
    echo "  checking SRI against live cdn.jsdelivr.net ..."
    for f in $bundles; do
      live=$(curl -sSL "https://cdn.jsdelivr.net/npm/@smartledger/bsv@${sdk_version}/${f}.min.js" \
        | openssl dgst -sha384 -binary | openssl base64 -A)
      if grep -qF "sha384-${live}" "$file"; then
        printf '    OK    %s  sha384-%s\n' "$f.min.js" "$live"
      else
        printf '    DRIFT %s  expected sha384-%s\n' "$f.min.js" "$live" >&2
        printf '          (the file pins a different hash; an SDK upgrade requires a deliberate bump)\n' >&2
        drift_found=1
      fi
    done
  fi
  echo
done

if [[ "$drift_found" -eq 1 ]]; then
  echo "build.sh: SRI drift detected — review before deploying." >&2
  exit 1
fi

echo "build.sh: done. Open the page(s) in a browser; check DevTools console for CSP violations."
