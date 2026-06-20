#!/usr/bin/env bash
#
# lab-backup.sh -- back up the docker volumes with rsync hard-link snapshots.
#
# Each run makes DEST/<timestamp>/ : a full, browsable copy of the volumes. Files
# that didn't change since the previous backup are hardlinks to it (rsync
# --link-dest), so N snapshots cost ~1 copy + the deltas. No special tools to read
# them back -- they're just files.
#
# Then it prunes to the retention curve (3h ... 3 months) and deletes anything older
# than 3 months.
#
#   lab-backup.sh            # run a backup now (uses config below)
#
# Config: /etc/lab-backup/config.env  (override LAB_BACKUP_CONFIG=/path), or env.
#
set -euo pipefail

CONFIG="${LAB_BACKUP_CONFIG:-/etc/lab-backup/config.env}"
# shellcheck disable=SC1090
[[ -r "$CONFIG" ]] && source "$CONFIG"

SRC="${SRC:?set SRC (local path or user@host:/path)}"
DEST="${DEST:?set DEST (local directory for snapshots)}"
SSH_RSH="${SSH_RSH:-ssh}"
PAUSE_CONTAINERS="${PAUSE_CONTAINERS:-0}"
COMPOSE_PROJECT="${COMPOSE_PROJECT:-lab}"
LOCK="${LAB_BACKUP_LOCK:-/run/lab-backup.lock}"

log()  { printf '\033[1;34m==>\033[0m %s %s\n' "$(date -u +%H:%M:%S)" "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v rsync >/dev/null 2>&1 || die "rsync not found"

# SRC is remote (user@host:/path) when the part before the first ':' contains no '/'.
SRC_REMOTE=0; SRC_HOST=""
if [[ "$SRC" == *:* && "${SRC%%:*}" != *"/"* ]]; then
  SRC_REMOTE=1; SRC_HOST="${SRC%%:*}"
fi

# stamp_epoch <dir-name> -- convert a UTC snapshot dir name to epoch seconds, or fail.
stamp_epoch() {
  local s="$1"
  date -u -d "${s:0:8} ${s:9:2}:${s:11:2}:${s:13:2}" +%s 2>/dev/null
}

# docker_freeze <pause|unpause> -- pause or unpause the project's containers, locally or
# over SSH if SRC is remote. A failure only warns; it never aborts the backup.
docker_freeze() {
  local action="$1" cmd
  # $ids is expanded by the remote/sub shell, not here, so it stays inside single quotes.
  # shellcheck disable=SC2016
  cmd='ids=$(docker ps -q --filter label=com.docker.compose.project='"$COMPOSE_PROJECT"'); [ -n "$ids" ] && docker '"$action"' $ids || true'
  if [[ "$SRC_REMOTE" == "1" ]]; then
    $SSH_RSH "$SRC_HOST" "$cmd" || warn "docker $action failed on $SRC_HOST"
  else
    sh -c "$cmd" || warn "docker $action failed"
  fi
}

# Retention curve: keep the snapshot nearest each of these ages (seconds) and delete the
# rest; anything older than CAP is always deleted.
KEEP_AGES=(
  10800 21600 43200 64800          # 3h 6h 12h 18h
  86400 172800 259200 345600 432000 # 1d 2d 3d 4d 5d
  604800 1209600 2419200            # 1w 2w 4w
  2592000 7776000                   # 1mo 3mo
)
CAP=7776000                         # 3 months; older than this is always deleted

# prune -- thin DEST to the retention curve, keeping the newest snapshot plus the one
# nearest each KEEP_AGES target, and deleting everything older than CAP.
prune() {
  local now dirs=() d ts age t best bestdiff diff
  now="$(date -u +%s)"
  mapfile -t dirs < <(find "$DEST" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' 2>/dev/null | sort)
  [[ ${#dirs[@]} -gt 1 ]] || return 0     # nothing to thin yet

  declare -A keep=()
  keep["${dirs[-1]}"]=1                    # always keep the newest
  for t in "${KEEP_AGES[@]}"; do
    best=""; bestdiff=""
    for d in "${dirs[@]}"; do
      ts="$(stamp_epoch "$d")" || continue
      age=$(( now - ts ))
      if (( age > CAP )); then continue; fi   # never pick one the cap will delete
      diff=$(( age - t )); (( diff < 0 )) && diff=$(( -diff ))
      if [[ -z "$bestdiff" || $diff -lt $bestdiff ]]; then bestdiff="$diff"; best="$d"; fi
    done
    [[ -n "$best" ]] && keep["$best"]=1
  done

  for d in "${dirs[@]}"; do
    ts="$(stamp_epoch "$d")" || continue
    age=$(( now - ts ))
    if [[ -z "${keep[$d]:-}" || $age -gt $CAP ]]; then
      rm -rf -- "${DEST:?}/$d" && log "pruned $d"
    fi
  done
  return 0
}

# Single-instance lock: refuse to run if another backup holds it.
exec 9>"$LOCK" || die "cannot open lock $LOCK"
flock -n 9 || die "another lab-backup is already running"

mkdir -p "$DEST"
TS="$(date -u +%Y%m%dT%H%M%S)"
NEW="$DEST/$TS"
PREV=""
[[ -L "$DEST/latest" ]] && PREV="$(readlink -f "$DEST/latest" 2>/dev/null || true)"

# cleanup -- unpause the containers if we paused them. Runs on EXIT and is also called
# explicitly once the copy is done. Always returns 0 so it can't trip `set -e`.
PAUSED=0
cleanup() {
  if [[ "$PAUSED" == "1" ]]; then docker_freeze unpause; PAUSED=0; fi
  return 0
}
trap cleanup EXIT
if [[ "$PAUSE_CONTAINERS" == "1" ]]; then
  log "pausing $COMPOSE_PROJECT containers (freeze, not restart)"
  docker_freeze pause; PAUSED=1
fi

log "rsync $SRC -> $NEW${PREV:+  (link-dest $(basename "$PREV"))}"
mkdir -p "$NEW"
# -aH preserve perms/owners/symlinks/hardlinks; --numeric-ids so UIDs survive a move
# to a new host; --link-dest dedups unchanged files against the previous snapshot.
rsync -aH --numeric-ids --delete \
  -e "$SSH_RSH" \
  ${PREV:+--link-dest="$PREV"} \
  "$SRC/" "$NEW/" \
  || die "rsync failed (snapshot $TS left in place for inspection)"

cleanup   # unpause as soon as the copy is done

ln -sfn "$NEW" "$DEST/latest"
ok "snapshot $TS  ($(du -sh "$NEW" 2>/dev/null | cut -f1) apparent)"

log "applying retention"
prune
ok "done -> $DEST"
