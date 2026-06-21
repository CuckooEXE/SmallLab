# AST Explorer -- offline AST explorer (ast.lab). Builds the fkling/astexplorer web app, which
# bundles ~80 parsers (incl. WASM engines) as local code-split chunks, so paste-source -> see-AST
# runs entirely in-browser. The air-gap patch drops the one analytics <script>; online snippet
# sharing (GitHub Gist) is the only feature lost. Self-contained; nothing is fetched at runtime.
FROM node:16-alpine AS build
RUN apk add --no-cache git python3 make g++
WORKDIR /src
RUN git clone --depth 1 https://github.com/fkling/astexplorer.git .
# Drop the Plausible analytics tag (best-effort: skip if upstream moved it).
RUN f=website/index.ejs; [ -f "$f" ] && sed -i '/plausible/d' "$f" || true
WORKDIR /src/website
RUN yarn install --frozen-lockfile && yarn run build
# output -> /src/out

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/out /usr/share/nginx/html
