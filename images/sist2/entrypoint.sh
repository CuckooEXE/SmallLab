#!/bin/sh
# sist2 entrypoint -- index the file share into a SQLite/FTS5 index, keep it fresh with an hourly
# incremental re-scan in the background, and serve the web UI in the foreground.
set -eu

SHARE=/share                       # the file share, mounted read-only
IDX=/idx                           # persisted index volume
SCAN="$IDX/documents.sist2"        # scan output (doc store + thumbnails)
SEARCH="$IDX/search.sist2"         # FTS5 search index the web UI queries
BIN="$(command -v sist2 || echo /root/sist2)"

reindex() {
  # --incremental is a no-op on the first run (no existing scan file) and only reprocesses
  # new/changed files thereafter.
  "$BIN" scan "$SHARE" --incremental --output "$SCAN" \
    && "$BIN" sqlite-index --search-index "$SEARCH" "$SCAN"
}

reindex || echo "sist2: initial index failed (will retry hourly)" >&2

( while true; do
    sleep 3600
    reindex || echo "sist2: hourly reindex failed" >&2
  done ) &

exec "$BIN" web --search-index "$SEARCH" --bind 0.0.0.0:4090 "$SCAN"
