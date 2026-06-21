# cppreference -- offline C/C++ reference. Downloads the maintained PeterFeicht html-book
# release at build time and serves it. Self-contained; nothing is fetched at runtime.
# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
RUN set -eux; \
    apk add --no-cache curl tar xz; \
    url="$(curl -fsSL https://api.github.com/repos/PeterFeicht/cppreference-doc/releases/latest \
          | grep -oE 'https://[^"]*/html-book-[0-9]+\.tar\.xz' | head -1)"; \
    [ -n "$url" ]; \
    curl -fsSL "$url" | tar -xJ -C /usr/share/nginx/html; \
    printf '<!doctype html><meta http-equiv="refresh" content="0; url=reference/en/cpp.html">\n' \
          > /usr/share/nginx/html/index.html; \
    apk del curl tar xz
