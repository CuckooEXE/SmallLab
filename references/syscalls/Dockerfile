# syscalls -- offline Linux syscall table (Juszkiewicz's cross-architecture page). A single
# static page fetched at build time. Self-contained; nothing is fetched at runtime.
# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
RUN set -eux; \
    apk add --no-cache wget; \
    wget --page-requisites --convert-links --adjust-extension --no-directories \
         -e robots=off --directory-prefix=/usr/share/nginx/html \
         "https://gpages.juszkiewicz.com.pl/syscalls-table/syscalls.html" || true; \
    [ -s /usr/share/nginx/html/syscalls.html ]; \
    printf '<!doctype html><meta http-equiv="refresh" content="0; url=syscalls.html">\n' \
          > /usr/share/nginx/html/index.html; \
    apk del wget
