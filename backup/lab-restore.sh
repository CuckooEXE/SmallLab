#!/usr/bin/env bash
#
# lab-restore.sh -- put a backup snapshot back, then `docker compose up`.
#
# A snapshot is just the stack's volumes/ tree, so restoring is one rsync. On a fresh
# host: clone the repo, lay the snapshot down into <repo>/volumes BEFORE the first
# `docker compose up`, and every service comes up with its data already populated.
#
#   lab-restore.sh list                         # what's available
#   lab-restore.sh restore latest               # -> local <repo>/volumes (RESTORE_TARGET)
#   lab-restore.sh restore 20260619T030000 --target /opt/lab/volumes
#   lab-restore.sh restore latest --to root@newhost:/opt/lab/volumes
#       --force   overwrite a non-empty target without prompting
#
# Config: /etc/lab-backup/config.env (DEST, SSH_RSH) -- override LAB_BACKUP_CONFIG.
#
set -euo pipefail

CONFIG="${LAB_BACKUP_CONFIG:-/etc/lab-backup/config.env}"
# shellcheck disable=SC1090
[[ -r "$CONFIG" ]] && source "$CONFIG"

DEST="${DEST:-}"
SSH_RSH="${SSH_RSH:-ssh}"
need_dest() { [[ -n "$DEST" ]] || die "set DEST (directory holding the snapshots) in config or env"; }

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v rsync >/dev/null 2>&1 || die "rsync not found"

do_list() {
  need_dest
  [[ -d "$DEST" ]] || die "no snapshot dir at $DEST"
  local found=0 d
  for d in "$DEST"/2*/; do
    [[ -d "$d" ]] || continue; found=1
    printf '  %s  %6s  %s\n' \
      "$(date -r "$d" '+%Y-%m-%d %H:%M')" \
      "$(du -sh "$d" 2>/dev/null | cut -f1)" \
      "$(basename "$d")"
  done
  [[ "$found" == "1" ]] || echo "  (no snapshots in $DEST)"
  if [[ -L "$DEST/latest" ]]; then echo "  latest -> $(basename "$(readlink -f "$DEST/latest")")"; fi
  return 0
}

do_restore() {
  need_dest
  local snap="${1:-}" target="${RESTORE_TARGET:-/opt/lab/volumes}" to="" force=0
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:?}"; shift ;;
      --to)     to="${2:?}"; shift ;;
      --force)  force=1 ;;
      *) die "unknown option: $1" ;;
    esac
    shift
  done
  [[ -n "$snap" ]] || die "usage: lab-restore.sh restore <SNAPSHOT|latest> [--target DIR|--to host:DIR] [--force]"

  local srcdir
  if [[ "$snap" == "latest" ]]; then
    [[ -L "$DEST/latest" ]] || die "no 'latest' symlink in $DEST"
    srcdir="$(readlink -f "$DEST/latest")"
  else
    srcdir="$DEST/$snap"
  fi
  [[ -d "$srcdir" ]] || die "snapshot not found: $srcdir"

  # where are we restoring to?
  local dst remote=0 dst_desc
  if [[ -n "$to" ]]; then
    dst="$to"; remote=1; dst_desc="$to"
  else
    dst="$target"; dst_desc="$target (local)"
  fi

  # safety: refuse to clobber a populated target unless --force
  if [[ "$force" != "1" ]]; then
    local nonempty=0
    if [[ "$remote" == "1" ]]; then
      $SSH_RSH "${to%%:*}" "[ -n \"\$(ls -A '${to#*:}' 2>/dev/null)\" ]" && nonempty=1 || true
    else
      [[ -d "$dst" && -n "$(ls -A "$dst" 2>/dev/null)" ]] && nonempty=1
    fi
    if [[ "$nonempty" == "1" ]]; then
      warn "target $dst_desc is not empty; restoring will --delete/overwrite it."
      warn "stop docker first if it's the live volumes dir."
      local ans; read -rp "   type 'yes' to continue: " ans
      [[ "$ans" == "yes" ]] || die "aborted"
    fi
  fi

  [[ "$remote" == "0" ]] && mkdir -p "$dst"
  log "restoring $(basename "$srcdir") -> $dst_desc"
  rsync -aH --numeric-ids --delete -e "$SSH_RSH" "$srcdir/" "$dst/" \
    || die "rsync restore failed"
  ok "restored"
  echo
  echo "   next:  docker compose up -d   &&   ./bootstrap.sh"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  list)         do_list ;;
  restore)      do_restore "$@" ;;
  ""|-h|--help) grep -E '^#( |$)' "$0" | sed -E 's/^# ?//' | head -n 16 ;;
  *) die "unknown command '$cmd' (try: list | restore | help)" ;;
esac
