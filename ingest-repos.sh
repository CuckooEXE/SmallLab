#!/usr/bin/env bash
#
# ingest-repos.sh -- drop source archives into OpenGrok's index.
#
# OpenGrok indexes whatever source trees live under its source root, one "project" per
# top-level directory. This script extracts each archive into volumes/opengrok/src/<name>
# (or copies a directory in); OpenGrok picks it up on its next sync (every SYNC_PERIOD_MINUTES,
# see compose/opengrok.yaml) -- or restart the container to index immediately.
#
# Fully OFFLINE -- unlike ./build.sh this needs no internet, so run it any time on the
# air-gapped host.
#
#   ./ingest-repos.sh <archive-or-dir> [<archive-or-dir> ...]
#   ./ingest-repos.sh incoming/*.tar.gz
#
# Re-runnable: an already-imported <name> is rebuilt from scratch. To index right now instead
# of waiting for the timer:
#   docker compose restart opengrok
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DEST="$SCRIPT_DIR/volumes/opengrok/src"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v tar >/dev/null || die "missing dependency: tar"
[[ $# -ge 1 ]] || die "usage: $0 <archive.tar.gz|dir> [...]"

# slug <path> -- strip the archive extension and make a file-safe project name.
slug() {
  local b; b="$(basename -- "$1")"
  b="${b%.tar.gz}"; b="${b%.tgz}"; b="${b%.tar.xz}"; b="${b%.tar.bz2}"
  b="${b%.tar}";    b="${b%.zip}"
  printf '%s' "$b" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

# ingest <archive-or-dir> -- extract (or copy) the source into volumes/opengrok/src/<slug>,
# replacing any previous import of the same name.
ingest() {
  local src="$1" name; name="$(slug "$src")"
  [[ -n "$name" && "$name" != "-" ]] || die "could not derive a project name from: $src"
  local work="$DEST/$name"
  log "$src -> volumes/opengrok/src/$name"

  rm -rf "$work"; mkdir -p "$work"
  if [[ -d "$src" ]]; then
    cp -a "$src/." "$work/"
  else
    case "$src" in
      *.tar.gz|*.tgz) tar -xzf "$src" -C "$work" ;;
      *.tar.xz)       tar -xJf "$src" -C "$work" ;;
      *.tar.bz2)      tar -xjf "$src" -C "$work" ;;
      *.tar)          tar -xf  "$src" -C "$work" ;;
      *.zip)          command -v unzip >/dev/null || die "missing dependency: unzip (for $src)"
                      unzip -q "$src" -d "$work" ;;
      *)              die "unsupported archive (want .tar.gz/.tgz/.tar.xz/.tar.bz2/.tar/.zip or a dir): $src" ;;
    esac
  fi

  # Collapse the usual single `foo-1.2.3/` wrapper dir so the project root is the source root.
  shopt -s nullglob dotglob
  local entries=("$work"/*)
  if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    mv "${entries[0]}"/* "$work"/ 2>/dev/null || true
    rmdir "${entries[0]}" 2>/dev/null || true
  fi
  shopt -u nullglob dotglob

  local files; files="$(find "$work" -type f | wc -l | tr -d ' ')"
  ok "$name  ($files files staged for indexing)"
}

mkdir -p "$DEST"
[[ -w "$DEST" ]] || die "$DEST is not writable by $(id -un).
        It is owned by root (if 'docker compose up' created it) or by uid 1111 (OpenGrok's appuser,
        which chowns the source tree on every boot). Take it back, then re-run:
            sudo chown -R $(id -un):$(id -gn) volumes/opengrok/src
        OpenGrok re-chowns it to 1111 on its next start -- that's fine, indexing only reads it."

for arg in "$@"; do ingest "$arg"; done
log "done. OpenGrok indexes on its next sync; to index now:  docker compose restart opengrok"
