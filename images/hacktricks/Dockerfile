# HackTricks -- offline pentest methodology wiki. Builds the English (master) book with the
# project's own mdBook toolchain image (custom preprocessor included); ENV=dev skips external
# title lookups so the build stays off-box. Large/slow build. Self-contained.
FROM ghcr.io/hacktricks-wiki/hacktricks-cloud/translator-image AS build
WORKDIR /app
RUN git clone --depth 1 --branch master https://github.com/HackTricks-wiki/hacktricks.git . \
 && git config --global --add safe.directory /app \
 && MDBOOK_PREPROCESSOR__HACKTRICKS__ENV=dev mdbook build

# nginx:1.27-alpine
FROM nginx@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
COPY --from=build /app/book /usr/share/nginx/html
