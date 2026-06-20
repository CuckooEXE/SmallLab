# x86 -- offline x86/x64 instruction reference. Mirrors the static c9x.me/x86 pages at build
# time (GNU wget, not busybox's) and serves them. Self-contained; nothing is fetched at runtime.
# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
RUN set -eux; \
    apk add --no-cache wget; \
    wget --mirror --no-parent --no-host-directories --page-requisites \
         --convert-links --adjust-extension -e robots=off \
         --directory-prefix=/usr/share/nginx/html "https://c9x.me/x86/" || true; \
    printf '<!doctype html><meta http-equiv="refresh" content="0; url=x86/index.html">\n' \
          > /usr/share/nginx/html/index.html; \
    apk del wget
