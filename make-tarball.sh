#!/usr/bin/env bash
# make-tarball.sh — package SatoFinder for deployment.
#
# What it does:
#   1. Runs ./build.sh first, so the CSP hash in the shipped index.html is in
#      lockstep with the inline-script bytes. Aborts if build.sh fails.
#   2. Verifies SRI hashes against the live jsDelivr CDN one last time (unless
#      --no-network is passed). DRIFT is fatal here — a release must not ship
#      with hashes that no longer match the public CDN.
#   3. Extracts VERSION from index.html (`const VERSION = '...'`) and uses it
#      to name the tarball.
#   4. Stages only the runtime artifacts into a clean dir (no dev tooling, no
#      legacy assets, no tests, no .git).
#   5. Produces dist/satofinder-vX.Y.Z.tar.gz with deterministic flags so two
#      builds of the same source bytes yield byte-identical archives. Prints
#      the SHA-256 so anyone verifying the release can compare bytes.
#
# Usage:
#   ./make-tarball.sh              # full check, build, package
#   ./make-tarball.sh --no-network # skip the SRI drift verification
#
# Requires: bash, python3, openssl, curl, tar, sha256sum.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$SRC_DIR/dist"
NO_NET=0
[[ "${1:-}" == "--no-network" ]] && NO_NET=1

# Files that go in the tarball. Designed so the same archive serves two
# deployment paths:
#
#   1. Static host (Netlify / S3 / `nginx /var/www/`)
#        tar -xzf satofinder-v2.0.0.tar.gz
#        cp satofinder-v2.0.0/{index.html,service-worker.js,manifest.json,help.html,logo2.png} /srv/
#
#   2. CapRover (or anything that does `docker build` on an uploaded source dir)
#        caprover deploy --tarFile dist/satofinder-v2.0.0.tar.gz
#      CapRover reads captain-definition, runs the Dockerfile, which in turn
#      runs ./make-tarball.sh --no-network and extracts a clean /out — so the
#      static deploy artifacts inside the tarball are the same bytes that the
#      container ends up serving.
#
# Anything not on this list (build outputs in dist/, spike.html, .git,
# node_modules, etc.) is excluded by construction.
ARTIFACTS=(
  # Runtime / static deploy
  index.html
  satofinder-modern.html
  service-worker.js
  manifest.json
  help.html
  README.md
  logo2.png

  # CapRover + Docker build
  captain-definition
  Dockerfile
  .dockerignore
  nginx.conf
  security-headers.conf

  # Build scripts invoked by the Dockerfile builder stage
  make-tarball.sh
  build.sh
)

# 1. Build (re-hash inline script) -------------------------------------------
echo "==> ./build.sh $([[ $NO_NET -eq 1 ]] && echo --no-network)"
if [[ $NO_NET -eq 1 ]]; then
  "$SRC_DIR/build.sh" --no-network >/dev/null
else
  "$SRC_DIR/build.sh" >/dev/null
fi

# 2. Hard SRI drift check (release-blocking, unlike build.sh's warning) ------
if [[ $NO_NET -eq 0 ]]; then
  echo "==> verifying SRI hashes against live cdn.jsdelivr.net"
  drift=0
  for f in bsv bsv-mnemonic bsv-message bsv-ecies; do
    live=$(curl -sSL "https://cdn.jsdelivr.net/npm/@smartledger/bsv@3.4.3/${f}.min.js" \
      | openssl dgst -sha384 -binary | openssl base64 -A)
    if grep -qF "sha384-${live}" "$SRC_DIR/index.html"; then
      printf '    OK    %s\n' "$f.min.js"
    else
      printf '    DRIFT %s — live=%s\n' "$f.min.js" "$live" >&2
      drift=$((drift + 1))
    fi
  done
  if [[ $drift -gt 0 ]]; then
    echo "==> ERROR: $drift bundle(s) drifted from pinned SRI. Refusing to ship." >&2
    echo "    Either revert your @smartledger/bsv version or update the SRI tags deliberately." >&2
    exit 1
  fi
fi

# 3. Detect version ----------------------------------------------------------
VERSION=$(python3 -c "
import re, sys
src = open('$SRC_DIR/index.html').read()
m = re.search(r\"const VERSION\s*=\s*'([^']+)'\", src)
if not m: sys.exit('VERSION not found in index.html')
print(m.group(1))
")
TARBALL="satofinder-v${VERSION}.tar.gz"
echo "==> version: $VERSION"

# 4. Verify all artifacts exist ----------------------------------------------
missing=()
for f in "${ARTIFACTS[@]}"; do
  [[ -f "$SRC_DIR/$f" ]] || missing+=("$f")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "==> ERROR: missing artifact(s): ${missing[*]}" >&2
  exit 1
fi

# 5. Stage into clean dir, package deterministically -------------------------
mkdir -p "$DIST_DIR"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKGDIR="$STAGE/satofinder-v${VERSION}"
mkdir -p "$PKGDIR"
for f in "${ARTIFACTS[@]}"; do
  cp -p "$SRC_DIR/$f" "$PKGDIR/$f"
done

# Tar with deterministic flags so two builds of the same source bytes yield
# byte-identical archives. --sort=name fixes file ordering; --mtime fixes
# timestamps; --owner/--group/--numeric-owner remove the host uid/gid.
echo "==> packaging $TARBALL"
( cd "$STAGE" && tar \
    --sort=name \
    --mtime='1970-01-01 00:00:00 UTC' \
    --owner=0 --group=0 --numeric-owner \
    --format=gnu \
    -czf "$DIST_DIR/$TARBALL" "satofinder-v${VERSION}" )

# 6. Print SHA-256 + listing -------------------------------------------------
SHA=$(sha256sum "$DIST_DIR/$TARBALL" | cut -d' ' -f1)
SIZE=$(stat -c%s "$DIST_DIR/$TARBALL")
echo
echo "==> wrote $DIST_DIR/$TARBALL  (${SIZE} bytes)"
echo "==> sha256: $SHA"
echo
echo "==> contents:"
tar -tzf "$DIST_DIR/$TARBALL" | sed 's/^/    /'
