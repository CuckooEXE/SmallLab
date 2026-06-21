# ExplainShell -- offline shell-command explainer (explainshell.lab). Tracks the upstream
# idank/explainshell production image (Python app + a custom-built Caddy + the man-page DB baked
# in), made self-contained: the source is cloned here and the DB release asset is resolved over
# GitHub's public API at build time, so no build args or external context are needed. The DB is
# downloaded during the build and baked in. Self-contained; nothing is fetched at runtime.

# Clone the upstream source and resolve the latest DB asset name into a file.
FROM debian:bookworm-slim AS src
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl jq \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/idank/explainshell.git /src
RUN curl -fsSL https://api.github.com/repos/idank/explainshell/releases/tags/db-latest \
      | jq -r '.assets[].name | select(startswith("explainshell-") and endswith(".db.zst"))' \
      | tail -1 > /src/DB_NAME \
 && [ -s /src/DB_NAME ]

# Build the custom Caddy (upstream's botshed plugin), exactly as the upstream Dockerfile does.
FROM caddy:2-builder AS caddy-builder
COPY --from=src /src/prod/botshed /src/botshed
RUN xcaddy build --with explainshell.com/botshed=/src/botshed

FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends wget zstd jq \
 && rm -rf /var/lib/apt/lists/*
COPY --from=caddy-builder /usr/bin/caddy /usr/local/bin/caddy
WORKDIR /opt/webapp
COPY --from=src /src/requirements.txt .
RUN pip3 install --no-cache-dir --no-warn-script-location -r requirements.txt
COPY --from=src /src/tools/download-latest-db.sh tools/
COPY --from=src /src/DB_NAME /tmp/DB_NAME
RUN tools/download-latest-db.sh --asset "$(cat /tmp/DB_NAME)" explainshell.db
COPY --from=src /src/prod/docker/Caddyfile /etc/caddy/Caddyfile
COPY --from=src /src/prod/docker/start.sh .
COPY --from=src /src/explainshell/ explainshell/
ENV DEBUG=false
ENV DB_PATH=/opt/webapp/explainshell.db
EXPOSE 8080
CMD ["./start.sh"]
