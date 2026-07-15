# JSON Crack -- offline JSON/YAML/CSV/XML visualizer (jsoncrack.lab). Builds the apps/www app from
# the AykutSarac/jsoncrack.com monorepo; its next.config sets output: "export", so the result is a
# static bundle with fonts baked in and all parsing (incl. jq / JSONPath) running in-browser. The
# build flag drops the off-box "upgrade" links. Self-contained; nothing is fetched at runtime.
FROM node:24-alpine AS build
ENV COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN apk add --no-cache git python3 make g++
WORKDIR /src
RUN git clone --depth 1 https://github.com/AykutSarac/jsoncrack.com.git .
RUN corepack enable && pnpm install --frozen-lockfile
ENV NEXT_PUBLIC_DISABLE_EXTERNAL_MODE=true
RUN pnpm build:www
# output -> /src/apps/www/out

FROM nginx:1.27-alpine
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/apps/www/out /usr/share/nginx/html
