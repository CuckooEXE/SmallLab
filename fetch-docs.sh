#!/usr/bin/env bash
#
# fetch-docs.sh -- stage OFFLINE documentation content into volumes/ for the static doc
# sites (cppreference, x86). This is the docs analog of `docker compose pull`: run it on a
# machine WITH internet during the provisioning window, then carry the populated volumes/
# dirs to the air-gapped host (git clone + rsync of volumes/, or run this on the host while
# it still has temporary internet). Nothing here is fetched at runtime.
#
#   ./fetch-docs.sh [all|cppreference|x86]   (default: all)
#
# Re-runnable: each target re-populates its own volumes/<name> dir.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
V="$SCRIPT_DIR/volumes"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# redirect <dir> <relative-target> -- drop a tiny landing page at <dir>/index.html so the
# bare https://<svc>.lab/ lands on the real start page of the bundle/mirror.
redirect() {
  printf '<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0; url=%s"><a href="%s">open</a>\n' \
    "$2" "$2" > "$1/index.html"
}

# ensure_writable <dir> -- the doc volumes are served READ-ONLY to nginx, but this script
# (running as your user, not root) must WRITE content into them. If `docker compose up` created
# the bind-mount dir first, it's owned by root and unwritable -- stop with the exact fix.
ensure_writable() {
  mkdir -p "$1" 2>/dev/null || true
  [[ -w "$1" ]] || die "$1 is not writable by $(id -un) -- likely created as root by 'docker compose up'.
        Fix:  sudo chown -R $(id -un):$(id -gn) ${1#"$SCRIPT_DIR/"}   (then re-run ./fetch-docs.sh)"
}

# --- cppreference (PeterFeicht html-book, the maintained offline archive) ----
fetch_cppreference() {
  command -v curl >/dev/null || die "missing dependency: curl"
  command -v tar  >/dev/null || die "missing dependency: tar"
  local dir="$V/cppreference"; ensure_writable "$dir"
  log "cppreference: resolving latest html-book release"
  local url
  url="$(curl -fsSL https://api.github.com/repos/PeterFeicht/cppreference-doc/releases/latest \
        | grep -oE 'https://[^"]*/html-book-[0-9]+\.tar\.xz' | head -1)" \
    || { warn "cppreference: could not resolve the release URL"; return 1; }
  [[ -n "$url" ]] || { warn "cppreference: no html-book asset found"; return 1; }
  log "cppreference: downloading $url"
  curl -fsSL "$url" | tar -xJ -C "$dir"          # unpacks reference/ + the doxygen .tag.xml files
  redirect "$dir" "reference/en/cpp.html"
  ok "cppreference -> volumes/cppreference  (start: reference/en/cpp.html)"
}

# --- x86 instruction reference (c9x.me/x86) ---------------------------------
fetch_x86() {
  command -v wget >/dev/null || die "missing dependency: wget"
  local dir="$V/x86"; ensure_writable "$dir"
  log "x86: mirroring https://c9x.me/x86/"
  wget --quiet --mirror --no-parent --page-requisites --convert-links --adjust-extension \
       --directory-prefix="$dir" "https://c9x.me/x86/" \
    || warn "x86: wget exited non-zero (partial mirror is usually still usable)"
  redirect "$dir" "c9x.me/x86/index.html"
  ok "x86 -> volumes/x86  (start: c9x.me/x86/index.html)"
}

case "${1:-all}" in
  cppreference) fetch_cppreference ;;
  x86)          fetch_x86 ;;
  all)          fetch_cppreference; fetch_x86 ;;
  *)            die "usage: $0 [all|cppreference|x86]" ;;
esac

log "done. If you staged on a different machine, copy volumes/{cppreference,x86} to the air-gapped host."
