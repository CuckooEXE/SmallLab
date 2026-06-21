# SQLime -- offline SQLite playground (sqlime.lab). The nalgeon/sqlime static site: plain HTML +
# vanilla JS with the SQLite WASM engine (sqlean.wasm) committed in-repo, so queries run entirely
# in-browser. Served as-is (nginx maps .wasm to application/wasm). The opt-in "Ask AI" / Gist /
# open-from-URL actions are the only off-box paths and never fire unprompted. Self-contained.
FROM alpine:3.20 AS build
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 https://github.com/nalgeon/sqlime.git .
RUN rm -rf .git test CNAME README.md

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY --from=build /src /usr/share/nginx/html
