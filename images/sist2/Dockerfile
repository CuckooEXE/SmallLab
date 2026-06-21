# sist2 -- offline full-text search over the file share (find.lab). Wraps the upstream sist2
# binary with an entrypoint that builds a SQLite/FTS5 index of the share, re-scans it hourly, and
# serves the web UI -- no Elasticsearch, all UI assets embedded in the binary, OCR language packs
# baked into the upstream image. Self-contained; nothing is fetched at runtime.
# sist2app/sist2:x64-linux pinned 2026-06
FROM sist2app/sist2@sha256:2a95b4f9395485108ac209f1775b05de117f7dae97e3000244e2571435da9115
COPY entrypoint.sh /usr/local/bin/sist2-entrypoint.sh
RUN chmod +x /usr/local/bin/sist2-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/sist2-entrypoint.sh"]
