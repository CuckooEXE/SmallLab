#!/usr/bin/env bash
#
# fetch-docs.sh -- stage OFFLINE documentation content into volumes/ for the static doc
# sites (cppreference, x86, tldr). This is the docs analog of `docker compose pull`: run it on
# a machine WITH internet during the provisioning window, then carry the populated volumes/
# dirs to the air-gapped host (git clone + rsync of volumes/, or run this on the host while
# it still has temporary internet). Nothing here is fetched at runtime.
#
#   ./fetch-docs.sh [all|cppreference|x86|tldr]   (default: all)
#
# Most targets need only curl/wget/tar; `tldr` additionally builds a static site in a
# throwaway node container, so it also needs docker (already present on the provisioning box).
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

# --- tldr.inbrowser.app (offline tldr-pages PWA) ----------------------------
# Build the static site in a throwaway node container -- no host node/pnpm toolchain needed,
# just docker (which the provisioning box already has for `compose pull`). The build's
# `download:tldr-pages` step pulls the tldr-pages archive and BAKES it into the bundle, so
# the finished site fetches nothing at runtime. node:20-alpine is build-time only; it never
# runs on the air-gapped host, so it's not part of the prepull set.
fetch_tldr() {
  command -v docker >/dev/null || die "missing dependency: docker (tldr builds in a node container)"
  command -v git    >/dev/null || die "missing dependency: git"
  local dir="$V/tldr"; ensure_writable "$dir"
  local src; src="$(mktemp -d)"
  log "tldr: cloning InBrowserApp/tldr.inbrowser.app"
  git clone --depth 1 https://github.com/InBrowserApp/tldr.inbrowser.app.git "$src" \
    || { warn "tldr: clone failed"; rm -rf "$src"; return 1; }

  # Air-gap: the in-browser page loader races the bundled zip against a live
  # raw.githubusercontent.com fetch whenever the browser reports online (it's aborted the
  # instant the local zip wins, but it's still an outbound attempt). Force the zip-only
  # branch so a cold load never reaches off-box. Best-effort: if upstream restructured the
  # guard the build still works, just with the race left in.
  local gp="$src/src/data/tldr-pages/page/getPage.ts"
  if [[ -f "$gp" ]] && grep -q 'isZipReady || !navigator.onLine' "$gp"; then
    sed -i 's#if (isZipReady || !navigator.onLine) {#if (true /* air-gap: always serve from the bundled zip */) {#' "$gp"
    ok "tldr: patched page loader to zip-only (air-gap)"
  else
    warn "tldr: zip-only air-gap patch did not apply (upstream changed?); github fallback left in place"
  fi

  log "tldr: building static site in node container (downloads tldr-pages archive + vite build)"
  # Runs as root in-container; chowns the tree back to the invoking user at the end so the
  # host-side cp/rm below don't trip over root-owned build output.
  # pnpm 8 matches the repo's lockfileVersion 6.0 (corepack's default is newer and needs a
  # newer Node than node:20-alpine ships). node 20 is fine for the vite 4 build.
  docker run --rm -e HOME=/tmp -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
      -v "$src:/app" -w /app node:20-alpine sh -lc "
        corepack enable &&
        corepack prepare pnpm@8.15.9 --activate &&
        pnpm install --frozen-lockfile &&
        pnpm build &&
        chown -R $(id -u):$(id -g) /app" \
    || { warn "tldr: container build failed (leftovers in $src may be root-owned)"; return 1; }

  rm -rf "${dir:?}"/* 2>/dev/null || true
  cp -a "$src/dist/." "$dir/"
  rm -rf "$src"
  ok "tldr -> volumes/tldr  (start: index.html)"
}

case "${1:-all}" in
  cppreference) fetch_cppreference ;;
  x86)          fetch_x86 ;;
  tldr)         fetch_tldr ;;
  all)          fetch_cppreference; fetch_x86; fetch_tldr ;;
  *)            die "usage: $0 [all|cppreference|x86|tldr]" ;;
esac

log "done. If you staged on a different machine, copy volumes/{cppreference,x86,tldr} to the air-gapped host."
