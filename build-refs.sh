#!/usr/bin/env bash
#
# build-refs.sh -- build the offline reference images.
#
# Layout:  references/<name>/Dockerfile  ->  image  lab/<name>:latest  (referenced by compose).
# Each image is self-contained: it downloads (and builds, for generated sites) its content and
# serves it, so the running container needs nothing off-box.
#
# explainshell is special-cased -- it is built from the upstream project's OWN production
# Dockerfile (Python app + baked SQLite man-page DB) rather than a references/ Dockerfile.
#
# This is a STAGING step: it needs internet (clones, toolchain downloads, content). Once built,
# the images live in the host's local image store and run fully offline. Carry them to an
# air-gapped host with `docker save lab/<name>:latest | ssh <host> docker load`.
#
#   ./build-refs.sh                 # build every reference image
#   ./build-refs.sh gtfobins x86    # build specific ones
#   ./build-refs.sh explainshell    # the upstream-image one
#
# Re-run after editing a Dockerfile, or to refresh content.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
REF_DIR="references"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32mok\033[0m  %s\n' "$*"; }
warn() { printf '  \033[1;33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '  \033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || die "docker not found on PATH"
command -v git    >/dev/null 2>&1 || die "git not found on PATH"
[[ -d "$REF_DIR" ]] || die "no $REF_DIR/ directory next to this script"

# build_explainshell -- clone idank/explainshell and build its upstream production Dockerfile
# (Python app + Caddy + baked SQLite man-page DB) as lab/explainshell:latest. The upstream
# Makefile resolves the DB asset via `gh api` (needs auth); we resolve it the same way over the
# public API with curl instead, then pass it as the DB_NAME build-arg the Dockerfile expects.
# The in-build download-latest-db.sh fetches that asset over wget from the same public release.
build_explainshell() {
  command -v curl >/dev/null 2>&1 || { warn "explainshell: curl not found"; return 1; }
  local src rc=0 name; src="$(mktemp -d)"
  log "explainshell: cloning idank/explainshell"
  if ! git clone --depth 1 https://github.com/idank/explainshell.git "$src/es"; then rm -rf "$src"; return 1; fi
  name="$(curl -fsSL https://api.github.com/repos/idank/explainshell/releases/tags/db-latest \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"explainshell-[^"]+\.db\.zst"' \
        | sed -E 's/.*"(explainshell-[^"]+\.db\.zst)".*/\1/' | tail -1)"
  if [[ -z "$name" ]]; then warn "explainshell: could not resolve the DB asset name from db-latest"; rm -rf "$src"; return 1; fi
  log "explainshell: building lab/explainshell:latest (DB asset: $name)"
  ( cd "$src/es" && docker build -t lab/explainshell:latest -f prod/docker/Dockerfile --build-arg DB_NAME="$name" . ) || rc=$?
  rm -rf "$src"
  return "$rc"
}

# Targets: explicit args, else every references/<name> plus explainshell.
targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  for d in "$REF_DIR"/*/; do targets+=("$(basename "$d")"); done
  targets+=(explainshell)
fi

built=() failed=()
for t in "${targets[@]}"; do
  if [[ "$t" == "explainshell" ]]; then
    if build_explainshell; then ok "lab/explainshell:latest"; built+=("explainshell"); else warn "FAILED explainshell"; failed+=("$t"); fi
    continue
  fi
  [[ -f "$REF_DIR/$t/Dockerfile" ]] || { warn "skip '$t' (no $REF_DIR/$t/Dockerfile)"; failed+=("$t"); continue; }
  log "building lab/$t:latest  (from $REF_DIR/$t)"
  if docker build -t "lab/$t:latest" "$REF_DIR/$t"; then
    ok "lab/$t:latest"; built+=("$t")
  else
    warn "FAILED to build lab/$t:latest"; failed+=("$t")
  fi
done

echo
log "summary"
for b in "${built[@]:-}";  do [[ -n "$b" ]] && ok "built  lab/$b"; done
for f in "${failed[@]:-}"; do [[ -n "$f" ]] && warn "failed $f"; done
[[ ${#failed[@]} -eq 0 ]] || die "${#failed[@]} image(s) failed to build"
ok "all reference images built -- 'docker compose up -d' will pick them up"
