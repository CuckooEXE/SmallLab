# PayloadsAllTheThings -- offline payload/technique reference. Replicates the project's own
# mkdocs-material build (CI mounts the content as docs/, uses its .github/overrides theme and
# mkdocs.yml). The social / git-revision-date / git-committers plugins are dropped so the build
# needs no imaging libs, git history, or GitHub token; offline search is kept. Self-contained.
FROM squidfunk/mkdocs-material:9 AS build
WORKDIR /build
RUN apk add --no-cache git \
 && pip install --no-cache-dir mdx_truly_sane_lists \
 && git clone --depth 1 https://github.com/swisskyrepo/PayloadsAllTheThings.git docs \
 && rm -rf docs/.git \
 && cp docs/mkdocs.yml . \
 && mv docs/.github/overrides . \
 && sed -i -E '/^[[:space:]]*-[[:space:]]+(social|git-revision-date-localized|git-committers)[[:space:]]*:?.*$/d' mkdocs.yml \
 && mkdocs build -d /site

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY --from=build /site /usr/share/nginx/html
