# Mermaid Live Editor -- offline diagrams-as-code editor (mermaid.lab). Builds the
# mermaid-js/mermaid-live-editor SvelteKit app (adapter-static); it bundles the mermaid renderer
# and renders entirely in-browser. The off-box endpoints baked in at build time (mermaid.ink /
# kroki.io export, Mermaid Chart links) are blanked so no diagram ever leaves the box -- those UI
# links simply drop out. Self-contained; nothing is fetched at runtime.
FROM node:24-alpine AS build
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN apk add --no-cache git python3 make g++
WORKDIR /src
RUN git clone --depth 1 https://github.com/mermaid-js/mermaid-live-editor.git .
# Blank the build-time external endpoints (best-effort: skip a key if upstream renamed it).
RUN if [ -f .env ]; then \
      sed -i -E "s#^MERMAID_RENDERER_URL=.*#MERMAID_RENDERER_URL=''#; \
                 s#^MERMAID_KROKI_RENDERER_URL=.*#MERMAID_KROKI_RENDERER_URL=''#; \
                 s#^MERMAID_IS_ENABLED_MERMAID_CHART_LINKS=.*#MERMAID_IS_ENABLED_MERMAID_CHART_LINKS=''#" .env; \
    fi
RUN corepack enable && pnpm install --frozen-lockfile && pnpm build
# output -> /src/docs

FROM nginx:1.27-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/docs /usr/share/nginx/html
