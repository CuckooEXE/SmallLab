# jq kung fu -- offline jq playground (jq.lab). Compiles jq to WebAssembly (Emscripten) so filters
# run in-browser, then vendors the two assets the page pulled from a CDN -- Bootstrap CSS and the
# ACE editor -- and rewrites their URLs to the local copies. Self-contained; nothing is fetched at
# runtime.
FROM emscripten/emsdk:3.1.8 AS jq
RUN apt-get update \
 && apt-get install -y --no-install-recommends git autoconf automake libtool flex bison \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 https://github.com/robertaboukhalil/jqkungfu.git .
RUN ./compile.sh
# output -> /src/build/jq.js, /src/build/jq.wasm  (index.html at /src/index.html)

# Vendor the CDN assets index.html references: Bootstrap 4.3.1 CSS and the full ACE 1.4.2 dist
# (ace.js lazy-loads its modes/themes/workers from the same dir, so ship all of src-min-noconflict).
FROM node:20-alpine AS vendor
WORKDIR /v
RUN npm install --no-save ace-builds@1.4.2 bootstrap@4.3.1 \
 && mkdir -p ace \
 && cp -r node_modules/ace-builds/src-min-noconflict/. ace/ \
 && cp node_modules/bootstrap/dist/css/bootstrap.min.css bootstrap.min.css

FROM nginx:1.27-alpine
COPY --from=jq     /src/index.html      /usr/share/nginx/html/index.html
COPY --from=jq     /src/build           /usr/share/nginx/html/build
COPY --from=vendor /v/ace               /usr/share/nginx/html/vendor/ace
COPY --from=vendor /v/bootstrap.min.css /usr/share/nginx/html/vendor/bootstrap.min.css
# Point the two CDN references at the vendored copies (best-effort: harmless if upstream changes).
RUN sed -i \
      -e 's#https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/css/bootstrap.min.css#vendor/bootstrap.min.css#g' \
      -e 's#https://cdnjs.cloudflare.com/ajax/libs/ace/1.4.2/ace.js#vendor/ace/ace.js#g' \
      /usr/share/nginx/html/index.html
