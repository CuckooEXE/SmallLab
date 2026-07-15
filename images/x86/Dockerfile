# x86 -- offline x86/x64 instruction reference. Mirrors the static c9x.me/x86 pages at build
# time (GNU wget, not busybox's) and serves them. Self-contained; nothing is fetched at runtime.
FROM nginx:1.27-alpine
RUN set -eux; \
    apk add --no-cache wget; \
    wget --mirror --no-parent --no-host-directories --page-requisites \
         --convert-links --adjust-extension -e robots=off \
         --directory-prefix=/usr/share/nginx/html "https://c9x.me/x86/" || true; \
    [ -s /usr/share/nginx/html/x86/index.html ]; \
    printf '<!doctype html><meta http-equiv="refresh" content="0; url=x86/index.html">\n' \
          > /usr/share/nginx/html/index.html; \
    apk del wget
