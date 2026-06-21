# tldr -- offline tldr-pages PWA. Builds the InBrowserApp static bundle, which bakes the whole
# tldr-pages archive in; the air-gap patch forces the bundled zip so a cold load never reaches
# github. Self-contained; nothing is fetched at runtime.
FROM node:20-alpine AS build
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 https://github.com/InBrowserApp/tldr.inbrowser.app.git .
# Force the zip-only branch of the page loader (best-effort: skip if upstream moved the guard).
RUN gp=src/data/tldr-pages/page/getPage.ts; \
    if [ -f "$gp" ] && grep -q 'isZipReady || !navigator.onLine' "$gp"; then \
      sed -i 's#if (isZipReady || !navigator.onLine) {#if (true /* air-gap: bundled zip only */) {#' "$gp"; \
    fi
RUN corepack enable && corepack prepare pnpm@8.15.9 --activate && \
    pnpm install --frozen-lockfile && pnpm build

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html
