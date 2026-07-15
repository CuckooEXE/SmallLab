# cppreference -- offline C/C++ reference. Downloads the maintained PeterFeicht html-book
# release at build time and serves it. Self-contained; nothing is fetched at runtime.
FROM nginx:1.27-alpine
RUN set -eux; \
    apk add --no-cache curl tar xz; \
    url="$(curl -fsSL https://api.github.com/repos/PeterFeicht/cppreference-doc/releases/latest \
          | grep -oE 'https://[^"]*/html-book-[0-9]+\.tar\.xz' | head -1)"; \
    [ -n "$url" ]; \
    curl -fsSL "$url" | tar -xJ -C /usr/share/nginx/html; \
    printf '<!doctype html><meta http-equiv="refresh" content="0; url=reference/en/cpp.html">\n' \
          > /usr/share/nginx/html/index.html; \
    apk del curl tar xz
