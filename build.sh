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
# The two pages intentionally pin DIFFERENT SDK versions: index.html is the
# stable production page, satofinder-modern.html is the alternate UI on a newer
# SDK. Each is verified against its own version.
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
  "index.html:3.4.3:bsv bsv-mnemonic bsv-message bsv-ecies"
  "satofinder-modern.html:7.0.1:bsv"
)

NO_NETWORK=0
[[ "${1:-}" == "--no-network" ]] && NO_NETWORK=1

drift_found=0

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
