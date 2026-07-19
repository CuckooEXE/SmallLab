#!/usr/bin/env bash
#
# ingest-repos.sh -- stage source trees as git repositories for Sourcebot to index.
#
# Sourcebot only indexes GIT REPOSITORIES. Per its local-repo connection, a folder is indexed
# only if it has a .git at its root AND a remote.origin.url set in its git config -- anything
# else is silently skipped. So this script does not just unpack source the way the OpenGrok
# version did; it guarantees each project under volumes/sourcebot/repos/<name> is a valid repo:
#
#   * a real git clone (a directory containing .git)  -> copied verbatim, FULL HISTORY KEPT.
#     A missing origin is filled in with a synthetic one so Sourcebot won't skip it.
#   * a tarball / zip / plain directory               -> git init + one "Imported <name>"
#     commit + synthetic origin. No history, but searchable.
#
# The synthetic origin is file:///repos/<name> -- the path the repo appears at INSIDE the
# container, which is what Sourcebot's config.json globs over.
#
# Sourcebot treats these as read-only: it will never `git fetch` them. To pick up new
# revisions, re-ingest (this script rebuilds a project from scratch) and let it re-index.
#
# Fully OFFLINE -- unlike ./build.sh this needs no internet, so run it any time on the
# air-gapped host.
#
#   ./ingest-repos.sh <archive-or-dir> [<archive-or-dir> ...]
#   ./ingest-repos.sh incoming/*.tar.gz
#
# Re-runnable: an already-imported <name> is rebuilt from scratch. Sourcebot re-indexes on its
# own poll; to kick it immediately:
#   docker compose restart sourcebot
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
DEST="$SCRIPT_DIR/volumes/sourcebot/repos"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v tar >/dev/null || die "missing dependency: tar"
command -v git >/dev/null || die "missing dependency: git"
[[ $# -ge 1 ]] || die "usage: $0 <archive.tar.gz|dir> [...]"

# Commit as the lab rather than inheriting (or requiring) the operator's git identity -- a host
# with no user.email configured would otherwise fail the commit below.
GIT_ID=(-c user.name="lab ingest" -c user.email="ingest@lab.invalid" -c commit.gpgsign=false)

# slug <path> -- strip the archive extension and make a file-safe project name.
slug() {
  local b; b="$(basename -- "$1")"
  b="${b%.tar.gz}"; b="${b%.tgz}"; b="${b%.tar.xz}"; b="${b%.tar.bz2}"
  b="${b%.tar}";    b="${b%.zip}"
  printf '%s' "$b" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-'
}

# ensure_origin <repo> <name> -- Sourcebot skips any repo without remote.origin.url, so give
# one to repos that have none (a `git init` tree, or a clone stripped of its remotes). An
# existing origin is left alone: it's the real provenance and Sourcebot surfaces it.
ensure_origin() {
  local work="$1" name="$2" existing
  existing="$(git -C "$work" config --get remote.origin.url 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    ok "origin kept: $existing"
  else
    git -C "$work" remote add origin "file:///repos/$name"
    ok "origin set: file:///repos/$name  (synthetic)"
  fi
}

# ingest <archive-or-dir> -- materialise volumes/sourcebot/repos/<slug> as a valid git repo,
# replacing any previous import of the same name.
ingest() {
  local src="$1" name; name="$(slug "$src")"
  [[ -n "$name" && "$name" != "-" ]] || die "could not derive a project name from: $src"
  local work="$DEST/$name"
  log "$src -> volumes/sourcebot/repos/$name"

  rm -rf "$work"; mkdir -p "$work"

  # A directory that is already a git repo is copied whole -- .git included -- so Sourcebot
  # indexes the real history rather than a flattened snapshot.
  if [[ -d "$src" && -d "$src/.git" ]]; then
    cp -a "$src/." "$work/"
    ok "copied existing git repo (history preserved)"
    ensure_origin "$work" "$name"
  else
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
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" && "$(basename "${entries[0]}")" != ".git" ]]; then
      mv "${entries[0]}"/* "${entries[0]}"/.[!.]* "$work"/ 2>/dev/null || true
      rmdir "${entries[0]}" 2>/dev/null || true
    fi
    shopt -u nullglob dotglob

    # Turn the snapshot into the single-commit repo Sourcebot requires. -A picks up any
    # .gitignore shipped in the tarball; --no-verify since there are no hooks worth running.
    git -C "$work" init -q -b main
    git -C "$work" "${GIT_ID[@]}" add -A
    if git -C "$work" diff --cached --quiet 2>/dev/null; then
      warn "$name has no files to commit -- Sourcebot will index it as empty"
    fi
    git -C "$work" "${GIT_ID[@]}" commit -q --no-verify -m "Imported $name" --allow-empty
    ok "initialised single-commit repo"
    ensure_origin "$work" "$name"
  fi

  # Sourcebot does not build a commit graph for local repos; on a big history that makes the
  # first index crawl. Cheap to precompute here, harmless on a one-commit import.
  git -C "$work" commit-graph write --reachable >/dev/null 2>&1 \
    || warn "could not write commit-graph for $name (indexing still works, just slower)"

  local files; files="$(git -C "$work" ls-files | wc -l | tr -d ' ')"
  ok "$name  ($files tracked files staged for indexing)"
}

mkdir -p "$DEST"
[[ -w "$DEST" ]] || die "$DEST is not writable by $(id -un).
        It is owned by root if 'docker compose up' created it. Take it back, then re-run:
            sudo chown -R $(id -un):$(id -gn) volumes/sourcebot/repos
        Sourcebot mounts it READ-ONLY, so it never changes the ownership back."

for arg in "$@"; do ingest "$arg"; done
log "done. Sourcebot re-indexes on its next poll; to index now:  docker compose restart sourcebot"
