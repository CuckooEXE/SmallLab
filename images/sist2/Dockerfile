# sist2 -- offline full-text search over the file share (find.lab). Wraps the upstream sist2
# binary with an entrypoint that builds a SQLite/FTS5 index of the share, re-scans it hourly, and
# serves the web UI -- no Elasticsearch, all UI assets embedded in the binary, OCR language packs
# baked into the upstream image. Self-contained; nothing is fetched at runtime.
FROM sist2app/sist2:x64-linux
COPY entrypoint.sh /usr/local/bin/sist2-entrypoint.sh
RUN chmod +x /usr/local/bin/sist2-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/sist2-entrypoint.sh"]
