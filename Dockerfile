# SatoFinder v2 — production container.
#
# Multi-stage build:
#   1. builder: runs ./make-tarball.sh inside a clean alpine image, then
#      extracts the resulting deterministic tarball. This guarantees the
#      shipped artifacts match what `./make-tarball.sh` produces locally
#      (same bytes, same SHA-256), and that no dev-only files leak in.
#   2. runtime: nginx:alpine serving only the extracted artifacts. nginx is
#      configured (see nginx.conf) to set the security headers that cannot
#      live in a <meta> CSP — frame-ancestors, Referrer-Policy,
#      Permissions-Policy, etc.
#
# Build & run locally:
#   docker build -t satofinder .
#   docker run --rm -p 8080:80 satofinder

# ---------- 1. builder ---------------------------------------------------------
FROM alpine:3.20 AS builder

RUN apk add --no-cache bash python3 openssl curl tar coreutils

WORKDIR /src
COPY . .

# --no-network: builder must not require external connectivity for SRI drift
# checks. The hashes baked into index.html are already validated by host
# tooling before pushing. Production deployers can run make-tarball.sh with
# network access if they want the release-blocking drift check.
RUN ./make-tarball.sh --no-network

# Extract the just-built tarball into /out/. We don't know the exact version
# string at COPY time, so glob — and assert exactly one tarball was produced.
RUN mkdir /out && \
    set -e && \
    count=$(ls dist/satofinder-v*.tar.gz | wc -l) && \
    [ "$count" = "1" ] || (echo "expected 1 tarball, got $count" >&2; exit 1) && \
    tar -xzf dist/satofinder-v*.tar.gz -C /out --strip-components=1

# ---------- 2. runtime ---------------------------------------------------------
FROM nginx:1.27-alpine

# Drop the default nginx config; ship our own with strict security headers.
RUN rm /etc/nginx/conf.d/default.conf && mkdir -p /etc/nginx/snippets
COPY nginx.conf             /etc/nginx/conf.d/satofinder.conf
COPY security-headers.conf  /etc/nginx/snippets/security-headers.conf

# Only the extracted runtime artifacts. No source, no dev tooling, no tarball.
COPY --from=builder /out/ /usr/share/nginx/html/

# nginx:alpine listens on 80 by default; CapRover/the reverse proxy upstream
# terminates HTTPS.
EXPOSE 80

# Cheap healthcheck — hit /index.html and look for a 200.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O- -S http://127.0.0.1/ 2>&1 | grep -q "HTTP/1.1 200" || exit 1

CMD ["nginx", "-g", "daemon off;"]
