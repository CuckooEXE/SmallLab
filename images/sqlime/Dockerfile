# SQLime -- offline SQLite playground (sqlime.lab). The nalgeon/sqlime static site: plain HTML +
# vanilla JS with the SQLite WASM engine (sqlean.wasm) committed in-repo, so queries run entirely
# in-browser. Served as-is (nginx maps .wasm to application/wasm). The opt-in "Ask AI" / Gist /
# open-from-URL actions are the only off-box paths and never fire unprompted. Self-contained.
FROM alpine:3.20 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 https://github.com/nalgeon/sqlime.git .
RUN rm -rf .git test CNAME README.md

FROM nginx:1.27-alpine
COPY --from=build /src /usr/share/nginx/html
