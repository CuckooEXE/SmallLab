# arm -- offline AArch64 (ARMv8/ARMv9 A64) instruction reference. Mirrors the static
# scs.stanford.edu/~zyedidia/arm64 pages at build time (GNU wget, not busybox's) and serves
# them. That reference is generated from ARM's machine-readable spec: one flat HTML page per
# instruction plus a single stylesheet, no CDN assets -- so a plain mirror is fully offline.
# Self-contained; nothing is fetched at runtime.
FROM nginx:1.27-alpine
RUN set -eux; \
    apk add --no-cache wget; \
    # --cut-dirs=1 drops the leading `~zyedidia` path component so pages land under arm64/
    # (parallel to the x86 image's x86/ subdir), keeping the site's flat relative links intact.
    wget --mirror --no-parent --no-host-directories --cut-dirs=1 --page-requisites \
         --convert-links --adjust-extension -e robots=off \
         --directory-prefix=/usr/share/nginx/html \
         "https://www.scs.stanford.edu/~zyedidia/arm64/" || true; \
    [ -s /usr/share/nginx/html/arm64/index.html ]; \
    printf '<!doctype html><meta http-equiv="refresh" content="0; url=arm64/index.html">\n' \
          > /usr/share/nginx/html/index.html; \
    apk del wget
