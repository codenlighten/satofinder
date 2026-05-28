#!/usr/bin/env bash
# build.sh — single-file build step for SatoFinder v2.
#
# What it does:
#   1. Extracts the *literal text content* of the single inline <script> in
#      index.html — exactly what a browser computes a CSP hash over — and pins
#      its SHA-256 (base64) into the `script-src 'sha256-...'` directive of the
#      CSP meta tag. Re-run after every edit to the script body, otherwise the
#      browser refuses to execute it.
#
#   2. (Optional) Re-fetches the four pinned @smartledger/bsv@3.4.3 CDN bundles
#      and warns if any live hash drifts from what's currently baked into the
#      index.html SRI attributes. Doesn't rewrite — drift requires a deliberate
#      version bump, which is the whole point of SRI.
#
# Idempotent: source file == output file == index.html. Re-run after every edit
# to the inline script block.
#
# Usage: ./build.sh [--no-network]    # --no-network skips the SRI drift check
#
# Requires: bash, python3, openssl, curl.

set -euo pipefail

FILE="${FILE:-index.html}"
SDK_VERSION="3.4.3"
BUNDLES=(bsv bsv-mnemonic bsv-message bsv-ecies)

[[ -f "$FILE" ]] || { echo "build.sh: $FILE not found" >&2; exit 1; }

# --- 1. Inline-script CSP hash --------------------------------------------------
# Hash the literal textContent of the (single) inline <script> element — the
# exact bytes the browser hashes when evaluating the CSP sha256-... directive.
script_hash=$(python3 - "$FILE" <<'PY'
import sys, re, hashlib, base64
html = open(sys.argv[1], 'rb').read().decode('utf-8')
# Match each <script>...</script> block; capture the inner text. Scripts with
# a `src=` attribute have empty inner text and are skipped.
blocks = re.findall(r'<script(?:\s[^>]*)?>([\s\S]*?)</script>', html)
inline = [b for b in blocks if b.strip()]
if len(inline) != 1:
    sys.exit(f"build.sh: expected exactly 1 inline script, found {len(inline)}")
content = inline[0].encode('utf-8')
print(base64.b64encode(hashlib.sha256(content).digest()).decode())
PY
)

echo "inline script sha256: $script_hash"

# Substitute the hash into the CSP meta tag. Match either the unhashed
# placeholder (`__SCRIPT_HASH__`) or a previously-pinned hash so re-runs work.
if grep -q "__SCRIPT_HASH__" "$FILE"; then
  sed -i "s|__SCRIPT_HASH__|${script_hash}|g" "$FILE"
elif grep -qE "'sha256-[A-Za-z0-9+/=]+' https://cdn.jsdelivr.net" "$FILE"; then
  sed -i -E "s|'sha256-[A-Za-z0-9+/=]+' https://cdn.jsdelivr.net|'sha256-${script_hash}' https://cdn.jsdelivr.net|" "$FILE"
else
  echo "build.sh: no CSP placeholder or existing hash found; nothing to substitute" >&2
fi

# --- 2. SRI drift check (network) ----------------------------------------------
if [[ "${1:-}" != "--no-network" ]]; then
  echo
  echo "Checking SRI hashes against live cdn.jsdelivr.net ..."
  for f in "${BUNDLES[@]}"; do
    live=$(curl -sSL "https://cdn.jsdelivr.net/npm/@smartledger/bsv@${SDK_VERSION}/${f}.min.js" \
      | openssl dgst -sha384 -binary | openssl base64 -A)
    if grep -qF "sha384-${live}" "$FILE"; then
      printf '  OK    %s  sha384-%s\n' "$f.min.js" "$live"
    else
      printf '  DRIFT %s  expected sha384-%s\n' "$f.min.js" "$live" >&2
      printf '        (the file pins a different hash; SDK upgrade requires a deliberate bump)\n' >&2
    fi
  done
fi

echo
echo "build.sh: done. Open $FILE in a browser; check DevTools console for any CSP violations."
