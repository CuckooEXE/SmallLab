#!/usr/bin/env bash
#
# build-profiles.sh -- build the baked session profile images (code + terminal).
#
# Layout:  profiles/<kind>/<profile>/Dockerfile  ->  image  lab/<kind>-<profile>:latest
# which the control plane's config (config/session-control/<kind>.json) points at.
#
# This is a STAGING step: it needs internet (apt, toolchain downloads, ZLS source,
# Open VSX extensions). Once built, the images live in the host's local image store
# and the sessions run fully offline.
#
#   ./build-profiles.sh                 # build every profile under profiles/*/*
#   ./build-profiles.sh code            # build every code profile
#   ./build-profiles.sh term            # build every terminal profile
#   ./build-profiles.sh code/zig term/base   # build specific ones
#
# Re-run after editing a Dockerfile, or to refresh extensions/toolchains.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Pinned base image per kind -- keep in sync with config/session-control/<kind>.json.
declare -A BASE_FOR=(
  [code]="codercom/code-server@sha256:9a7848dd2627158e3873f88bd8743807a4168e4d580f26ec0cbc132a9d9ee78e"
  [term]="tsl0922/ttyd@sha256:9ac4c4d0b436127af7703402fbd7ae51ff49179ca06ad0a132d7c5cc157015a7"
)
PROFILES_DIR="profiles"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
[[ -d "$PROFILES_DIR" ]] || die "no $PROFILES_DIR/ directory next to this script"

# Expand a selector into "<kind>/<profile>" tokens. A selector is a kind ("code"),
# a single profile ("code/zig"), or nothing (all profiles under every kind).
collect() {  # collect [selector ...]
  local sels=("$@") sel kind dir
  [[ ${#sels[@]} -eq 0 ]] && sels=("${!BASE_FOR[@]}")
  for sel in "${sels[@]}"; do
    if [[ "$sel" == */* ]]; then
      if [[ -f "$PROFILES_DIR/$sel/Dockerfile" ]]; then
        printf '%s\n' "$sel"
      else
        warn "skip '$sel' (no $PROFILES_DIR/$sel/Dockerfile)"
      fi
    else
      kind="$sel"
      [[ -n "${BASE_FOR[$kind]:-}" ]] || { warn "skip '$kind' (unknown kind; known: ${!BASE_FOR[*]})"; continue; }
      for dir in "$PROFILES_DIR/$kind"/*/; do
        [[ -f "${dir}Dockerfile" ]] && printf '%s\n' "$kind/$(basename "$dir")"
      done
    fi
  done
}

mapfile -t targets < <(collect "$@")
[[ ${#targets[@]} -gt 0 ]] || die "no profiles to build"

# Pull each needed base once (harmless if already local).
declare -A pulled=()
for t in "${targets[@]}"; do
  kind="${t%%/*}"; base="${BASE_FOR[$kind]:-}"
  [[ -n "$base" ]] || die "no base image configured for kind '$kind'"
  if [[ -z "${pulled[$kind]:-}" ]]; then
    log "ensuring base for '$kind': $base"
    docker image inspect "$base" >/dev/null 2>&1 || docker pull "$base" >/dev/null
    ok "$base"; pulled[$kind]=1
  fi
done

built=() failed=()
for t in "${targets[@]}"; do
  kind="${t%%/*}"; profile="${t##*/}"
  dir="$PROFILES_DIR/$t"; tag="lab/${kind}-${profile}:latest"
  log "building $tag  (from $dir)"
  if docker build --build-arg "BASE=${BASE_FOR[$kind]}" -t "$tag" "$dir"; then
    ok "$tag"; built+=("$tag")
  else
    warn "FAILED to build $tag"; failed+=("$t")
  fi
done

echo
log "summary"
for b in "${built[@]:-}";  do [[ -n "$b" ]] && ok "built  $b"; done
for f in "${failed[@]:-}"; do [[ -n "$f" ]] && warn "failed $f"; done
[[ ${#failed[@]} -eq 0 ]] || die "${#failed[@]} profile(s) failed to build"
ok "all profiles built -- they are now available offline to the control plane"
