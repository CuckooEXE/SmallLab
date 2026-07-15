#!/usr/bin/env bash
#
# build.sh -- the staging step (needs internet). It:
#   1. builds every custom image under images/<name>/   ->  lab/<name>:latest
#   2. pulls the pinned prebuilt images the compose stack references (caddy, nginx, step-ca, ...)
#   3. saves both groups as gzipped tarballs under dist/, ready to carry to the host:
#        dist/lab-images.tar.gz       -- the custom lab/* images (served sites, tools, sessions)
#        dist/prebuilt-images.tar.gz  -- the pinned upstream images
#
# Everything that isn't a plain prebuilt (e.g. nginx:alpine) has a Dockerfile under images/ and
# is built here; build-time resources (Dockerfiles, nginx conf, settings.json) live beside it.
# Runtime resources stay in config/ and volumes/.
#
# On the target host (online or air-gapped):
#   for f in dist/*.tar.gz; do docker load -i "$f"; done
#   docker compose up -d && ./bootstrap.sh
#
#   ./build.sh                 # build all, pull prebuilts, write both bundles
#   ./build.sh sqlime x86      # rebuild only these custom images (skips pull + bundle)
#
# Re-run after editing a Dockerfile, adding an images/<name>/, or to refresh content.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
IMAGES_DIR=images
DIST_DIR=dist

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
[[ -d "$IMAGES_DIR" ]] || die "no $IMAGES_DIR/ directory next to this script"

# Targets: explicit args, else every images/<name>.
targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  for d in "$IMAGES_DIR"/*/; do targets+=("$(basename "$d")"); done
fi

# 1. build the custom images. images/<name>/ -> lab/<name>:latest. Plain order is enough: no
#    custom image builds FROM another (term-netutils is FROM ttyd, not lab/term-base).
built=() failed=()
for name in "${targets[@]}"; do
  [[ -f "$IMAGES_DIR/$name/Dockerfile" ]] || { warn "skip '$name' (no $IMAGES_DIR/$name/Dockerfile)"; failed+=("$name"); continue; }
  log "building lab/$name:latest  (from $IMAGES_DIR/$name)"
  if docker build -t "lab/$name:latest" "$IMAGES_DIR/$name"; then
    ok "lab/$name:latest"; built+=("lab/$name:latest")
  else
    warn "FAILED to build lab/$name:latest"; failed+=("$name")
  fi
done
[[ ${#failed[@]} -eq 0 ]] || die "${#failed[@]} image(s) failed to build: ${failed[*]}"

# A targeted run just (re)builds those images -- skip the pull + bundle.
if [[ $# -gt 0 ]]; then
  ok "built ${#built[@]} image(s): ${built[*]}"
  exit 0
fi

# 2. pull the pinned prebuilt images the compose stack references (everything it lists that we do
#    not build). Every opt-in profile is enabled so their images bundle too -- including all four
#    Ollama accelerator variants (CPU/NVIDIA share one image; AMD, Intel each add a large one).
log "resolving prebuilt images from the compose stack"
mapfile -t compose_imgs < <(docker compose \
  --profile dhcp --profile full-lab \
  --profile ai-cpu --profile ai-nvidia --profile ai-amd --profile ai-intel \
  config --images 2>/dev/null | sort -u)
[[ ${#compose_imgs[@]} -gt 0 ]] || die "could not read images from compose (is .env present?)"
prebuilt=()
for img in "${compose_imgs[@]}"; do [[ "$img" == lab/* ]] || prebuilt+=("$img"); done

# The session control plane launches some images directly (e.g. the plain code-server "base"
# profile) that are NOT compose services, so compose config never lists them. Harvest the
# non-lab image refs from its profile configs so they ride along in the bundle too.
if compgen -G "config/session-control/*.json" >/dev/null; then
  while IFS= read -r img; do
    [[ -z "$img" || "$img" == lab/* ]] && continue
    prebuilt+=("$img")
  done < <(grep -hoE '"image"[[:space:]]*:[[:space:]]*"[^"]+"' config/session-control/*.json \
           | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/')
fi
mapfile -t prebuilt < <(printf '%s\n' "${prebuilt[@]}" | sort -u)

for img in "${prebuilt[@]}"; do
  log "pulling $img"
  if docker pull -q "$img" >/dev/null; then ok "$img"; else die "failed to pull $img"; fi
done

# 3. save both groups as gzipped tarballs for transfer (docker load reads gzip directly).
mkdir -p "$DIST_DIR"
log "saving ${#built[@]} custom images   -> $DIST_DIR/lab-images.tar.gz"
docker save "${built[@]}"    | gzip > "$DIST_DIR/lab-images.tar.gz"
log "saving ${#prebuilt[@]} prebuilt images -> $DIST_DIR/prebuilt-images.tar.gz"
docker save "${prebuilt[@]}" | gzip > "$DIST_DIR/prebuilt-images.tar.gz"

echo
log "summary"
ok "custom   : ${#built[@]} images -> $DIST_DIR/lab-images.tar.gz"
ok "prebuilt : ${#prebuilt[@]} images -> $DIST_DIR/prebuilt-images.tar.gz"
# shellcheck disable=SC2016  # literal instructions for the operator -- not meant to expand here
ok 'carry dist/*.tar.gz to the host, then: for f in dist/*.tar.gz; do docker load -i "$f"; done'
