#!/usr/bin/env bash
#
# bootstrap.sh -- pre-configure the .lab stack after `docker compose up -d`.
#
#   1. waits for Technitium's HTTP API
#   2. logs in as Technitium's built-in 'admin'
#   3. adds the shared admin user (LAB_USER) to Technitium's Administrators group, so the
#      DNS console takes the same login as everything else
#   4. creates the `${LAB_DOMAIN}` primary zone and points *.${LAB_DOMAIN} + ${LAB_DOMAIN} -> ${HOST_IP}
#   5. exports step-ca's root CA to ./lab-root-ca.crt
#   6. sets step-ca's ACME cert lifetime (90 days; override via STEPCA_CERT_TTL)
#   7. restarts Caddy so it issues certs now that DNS + CA are ready
#   8. teaches vaultwarden (system store) to trust the lab root CA, so its OUTBOUND HTTPS
#      to *.${LAB_DOMAIN} verifies instead of erroring
#   9. if the full-lab profile is up: seeds the Mattermost admin (LAB_USER) and a default
#      team via mmctl. (GitLab needs no bootstrap -- it seeds root's password from .env on
#      first boot.)
#  10. rotates Nexus's built-in admin from the well-known first-boot password (admin123) to
#      LAB_PASSWORD, so packages.${LAB_DOMAIN} takes the same admin login as the rest of the lab,
#      then creates one HOSTED repo per format (npm/pypi/cargo/go/raw/yum/apt/docker) over the
#      REST API -- including docker-hosted's :8082 registry connector, which is what backs
#      docker.${LAB_DOMAIN}. apt-hosted gets a generated PGP signing key (lab-apt-signing.asc)
#  11. claims Sourcebot's OWNER account as LAB_USER and marks its org onboarded, so
#      search.${LAB_DOMAIN} serves anonymous search instead of a setup wizard
#
# Everything is driven by curl against the Technitium API plus a few `docker compose exec`
# calls. Idempotent: re-running overwrites the A records, no-ops the zone create, and leaves
# an existing Technitium/Mattermost user or team untouched.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] || { echo "error: .env not found next to bootstrap.sh" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source ./.env
set +a

: "${HOST_IP:?HOST_IP must be set in .env}"
: "${LAB_DOMAIN:?LAB_DOMAIN must be set in .env}"
: "${LAB_USER:?LAB_USER must be set in .env}"
: "${LAB_PASSWORD:?LAB_PASSWORD must be set in .env}"

TECH="http://127.0.0.1:5380"            # Technitium API, published on loopback
CA_OUT="$SCRIPT_DIR/lab-root-ca.crt"    # step-ca's root -> the CA clients must trust
CA_SRC="/home/step/certs/root_ca.crt"   # path inside the step-ca container
STEPCA_CERT_TTL="${STEPCA_CERT_TTL:-2160h}"   # ACME cert lifetime (2160h = 90 days)

# Colored status logging helpers.
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

need curl
need jq
need docker
need openssl

# percent-encode a value (passwords may contain reserved chars)
urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

# tapi <api/path> [key=value ...]   -- GET against the API with the session token,
# returns the raw JSON body. Technitium answers 200 even on logical errors, so the
# caller inspects .status rather than relying on the HTTP code.
tapi() {
  local path="$1"; shift
  local url="$TECH/api/$path?token=$TOKEN"
  local kv
  for kv in "$@"; do url+="&$kv"; done
  curl -fsS --max-time 15 "$url"
}

log "waiting for Technitium at $TECH"
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "$TECH/api/user/login" >/dev/null 2>&1; then
    ok "API is responding"; break
  fi
  [[ $i -eq 60 ]] && die "Technitium did not come up within ~2 min (is the stack running?)"
  sleep 2
done

# Technitium's built-in admin is always named "admin"; only its password comes from .env.
log "logging in to Technitium as 'admin'"
resp="$(curl -fsS --max-time 15 \
  "$TECH/api/user/login?user=admin&pass=$(urlenc "$LAB_PASSWORD")")" \
  || die "could not reach the Technitium API"
[[ "$(jq -r '.status // "error"' <<<"$resp")" == "ok" ]] \
  || die "login failed: $(jq -r '.errorMessage // "bad credentials"' <<<"$resp") -- check LAB_PASSWORD"
TOKEN="$(jq -r '.token' <<<"$resp")"
ok "authenticated"

# ensure_technitium_admin_user -- add LAB_USER to Technitium's Administrators group so the
# DNS console takes the same login as everything else (the built-in 'admin' stays as a
# fallback). Skipped when LAB_USER is 'admin'. Idempotent: an existing user is kept and its
# Administrators membership re-asserted.
ensure_technitium_admin_user() {
  [[ "$LAB_USER" == "admin" ]] && { ok "Technitium login is the built-in 'admin'"; return 0; }
  log "ensuring Technitium admin user '$LAB_USER'"
  local resp
  resp="$(tapi admin/users/create \
    "user=$(urlenc "$LAB_USER")" "displayName=$(urlenc "Lab Admin")" "pass=$(urlenc "$LAB_PASSWORD")")" || true
  case "$(jq -r '.status // "error"' <<<"$resp")" in
    ok) ok "user '$LAB_USER' created" ;;
    *)  if grep -qi 'already exists' <<<"$resp"; then
          ok "user '$LAB_USER' already exists"
        else
          warn "could not create Technitium user: $(jq -r '.errorMessage // .' <<<"$resp")"; return 1
        fi ;;
  esac
  # Re-assert Administrators membership (idempotent for a new or pre-existing user).
  resp="$(tapi admin/users/set "user=$(urlenc "$LAB_USER")" "memberOfGroups=Administrators")" || true
  if [[ "$(jq -r '.status // "error"' <<<"$resp")" == "ok" ]]; then
    ok "'$LAB_USER' is in the Administrators group"
  else
    warn "could not add '$LAB_USER' to Administrators: $(jq -r '.errorMessage // .' <<<"$resp")"; return 1
  fi
}
ensure_technitium_admin_user \
  || warn "Technitium user setup incomplete -- the built-in 'admin' still works; re-run ./bootstrap.sh"

log "ensuring primary zone '$LAB_DOMAIN'"
resp="$(tapi zones/create "zone=$(urlenc "$LAB_DOMAIN")" "type=Primary")" || true
case "$(jq -r '.status // "error"' <<<"$resp")" in
  ok) ok "zone created" ;;
  *)  if grep -qi 'already exists' <<<"$resp"; then ok "zone already exists"; else die "zone create failed: $resp"; fi ;;
esac

# add_a <name> <ip> -- write (overwrite) an A record in the lab zone pointing <name> at <ip>.
add_a() {
  local name="$1" ip="$2" resp
  resp="$(tapi zones/records/add \
    "domain=$(urlenc "$name")" "zone=$(urlenc "$LAB_DOMAIN")" \
    "type=A" "ipAddress=$ip" "ttl=300" "overwrite=true")"
  [[ "$(jq -r '.status // "error"' <<<"$resp")" == "ok" ]] \
    || die "failed to add A $name -> $ip: $resp"
  ok "A  $name -> $ip"
}
log "writing A records -> $HOST_IP"
add_a "*.$LAB_DOMAIN" "$HOST_IP"        # wildcard covers home.lab, dns.lab, gitlab.lab, ...
add_a "$LAB_DOMAIN"   "$HOST_IP"        # apex, for bare \\lab style references
# Per-session subdomains for the on-demand session control planes. These live one label
# deeper than the stack, which the *.lab wildcard above doesn't reach (it matches one label).
add_a "*.code.$LAB_DOMAIN" "$HOST_IP"       # <name>.code.lab  (code-server workspaces)
add_a "*.terminal.$LAB_DOMAIN" "$HOST_IP"   # <name>.terminal.lab  (ttyd terminals)
# IMPORTANT: adding *.code.lab / *.terminal.lab makes code.lab / terminal.lab EMPTY
# NON-TERMINALS (a node now exists *below* them), and per RFC 4592 a wildcard no longer
# synthesizes for an empty non-terminal -- so *.lab stops answering for the control-plane
# apexes themselves. They must therefore be listed EXPLICITLY:
add_a "code.$LAB_DOMAIN"     "$HOST_IP"  # control UI (else NODATA -> no cert, won't resolve)
add_a "terminal.$LAB_DOMAIN" "$HOST_IP"  # control UI (else NODATA -> no cert, won't resolve)

log "exporting step-ca root CA"
exported=0
for i in $(seq 1 30); do
  if docker compose exec -T step-ca test -f "$CA_SRC" 2>/dev/null; then
    if docker compose exec -T step-ca cat "$CA_SRC" > "$CA_OUT" 2>/dev/null && [[ -s "$CA_OUT" ]]; then
      ok "wrote $CA_OUT"; exported=1; break
    fi
  fi
  [[ $i -eq 30 ]] && warn "step-ca root not ready yet -- once it has initialised, run:
        docker compose cp step-ca:$CA_SRC ./$(basename "$CA_OUT")"
  sleep 2
done

log "ensuring ACME certificate lifetime = $STEPCA_CERT_TTL"
claims_result="$(docker compose exec -T -e DUR="$STEPCA_CERT_TTL" step-ca sh 2>/dev/null <<'EOSH'
set -e
CA=/home/step/config/ca.json
if jq -e --arg d "$DUR" '.authority.provisioners[]|select(.type=="ACME")|.claims.defaultTLSCertDuration==$d' "$CA" >/dev/null 2>&1; then
  echo UNCHANGED
else
  jq --arg d "$DUR" '.authority.provisioners |= map(if .type=="ACME" then .claims={minTLSCertDuration:"5m",maxTLSCertDuration:$d,defaultTLSCertDuration:$d} else . end)' "$CA" > /tmp/ca.json
  mv /tmp/ca.json "$CA"
  echo UPDATED
fi
EOSH
)"
if grep -q UPDATED <<<"$claims_result"; then
  docker compose restart step-ca >/dev/null 2>&1
  for i in $(seq 1 20); do
    [[ "$(docker compose ps step-ca --format '{{.Health}}' 2>/dev/null)" == "healthy" ]] && break
    sleep 2
  done
  ok "lifetime set -> step-ca restarted"
else
  ok "lifetime already $STEPCA_CERT_TTL"
fi

# Caddy can only issue certs once *.lab resolves and step-ca's root exists, so restart it to
# trigger issuance now instead of on its next retry.
if [[ "$exported" == "1" ]]; then
  log "reloading Caddy to trigger certificate issuance"
  if docker compose restart caddy >/dev/null 2>&1; then
    ok "Caddy reloaded"
  else
    warn "could not restart Caddy; run 'docker compose restart caddy' yourself"
  fi
fi

# trust_lab_ca -- install the lab root CA into vaultwarden's system trust store so its
# OUTBOUND HTTPS to *.lab verifies, then restart it to reload the store. The change lives in
# the container's writable layer (lost on recreate or image bump); re-running bootstrap
# re-applies it. Soft-fails: a hiccup here never wedges the rest of the bootstrap.
trust_lab_ca() {
  [[ "$exported" == "1" ]] || { warn "lab CA not exported -- skipping container CA trust"; return; }

  if docker compose cp "$CA_OUT" vaultwarden:/usr/local/share/ca-certificates/lab-root-ca.crt >/dev/null 2>&1 \
     && docker compose exec -T vaultwarden update-ca-certificates >/dev/null 2>&1 \
     && docker compose restart vaultwarden >/dev/null 2>&1; then
    ok "vaultwarden trusts the lab CA (system store)"
  else
    warn "could not install the CA into vaultwarden -- is it up? ('docker compose ps vaultwarden')"
  fi
}
log "teaching vaultwarden to trust the lab CA"
trust_lab_ca

# setup_mattermost -- seed the Mattermost admin (LAB_USER) and a default team (named after
# ${LAB_DOMAIN}) via mmctl over the container's local socket (MM_SERVICESETTINGS_ENABLELOCALMODE).
# Runs only when the full-lab profile is up; idempotent (an existing user/team is left
# untouched). GitLab needs no counterpart here: it seeds root's password from .env on first
# boot, and its admin username is the fixed `root`.
setup_mattermost() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mattermost \
    || { ok "full-lab profile not running -- skipping (enable: docker compose --profile full-lab up -d)"; return 0; }

  local -a mm=(docker compose --profile full-lab exec -T mattermost mmctl --local)
  local team="$LAB_DOMAIN"

  # Wait for the server (the local socket answers only once Mattermost is fully up).
  log "waiting for Mattermost's local socket"
  local i ready=0
  for i in $(seq 1 30); do
    if "${mm[@]}" system version >/dev/null 2>&1; then ok "Mattermost is responding"; ready=1; break; fi
    sleep 3
  done
  [[ "$ready" == 1 ]] || { warn "Mattermost never became ready. Check 'docker compose ps mattermost',
        then re-run ./bootstrap.sh (it's idempotent)."; return 1; }

  # Ensure the admin user.
  log "ensuring Mattermost admin '$LAB_USER'"
  local out
  if out="$("${mm[@]}" user create --email "${LAB_USER}@chat.${LAB_DOMAIN}" \
        --username "$LAB_USER" --password "$LAB_PASSWORD" \
        --system-admin --email-verified 2>&1)"; then
    ok "admin user created"
  elif grep -qi 'exists' <<<"$out"; then
    ok "admin user already exists"
  else
    warn "could not create admin user: $out"; return 1
  fi

  # Ensure the default team and put the admin in it.
  log "ensuring team '$team'"
  if out="$("${mm[@]}" team create --name "$team" --display-name "$team" 2>&1)"; then
    ok "team '$team' created"
  elif grep -qi 'exists' <<<"$out"; then
    ok "team '$team' already exists"
  else
    warn "could not create team '$team': $out"; return 1
  fi
  "${mm[@]}" team users add "$team" "$LAB_USER" >/dev/null 2>&1 || true

  ok "Mattermost configured: admin '$LAB_USER', team '$team'"
}
log "configuring Mattermost (full-lab profile)"
setup_mattermost \
  || warn "Mattermost auto-setup did not finish -- the rest of the stack is up; re-run ./bootstrap.sh to retry"

# --- Nexus ---------------------------------------------------------------------------------
# Nexus publishes no host port, so -- like the clients -- we reach it over HTTPS through Caddy,
# name pinned to HOST_IP and verified against the exported lab CA.
NEXUS_HOST="packages.${LAB_DOMAIN}"
NEXUS_API="https://${NEXUS_HOST}/service/rest/v1"
NEXUS_APT_DIST="${NEXUS_APT_DIST:-bookworm}"            # dists/<name>/ path apt-hosted publishes under
NEXUS_APT_PUBKEY="$SCRIPT_DIR/lab-apt-signing.asc"      # public half of apt-hosted's signing key

# ncurl <curl-args...>   -- HTTPS to Nexus through Caddy, name pinned + CA-verified.
# nxadmin <curl-args...> -- the same, authenticated as the Nexus admin.
ncurl()   { curl -sS --max-time 30 --resolve "${NEXUS_HOST}:443:${HOST_IP}" --cacert "$CA_OUT" "$@"; }
nxadmin() { ncurl -u "admin:${LAB_PASSWORD}" "$@"; }

# rotate_nexus_admin_password -- change Nexus's built-in admin from the well-known first-boot
# password (admin123, pinned by NEXUS_SECURITY_RANDOMPASSWORD=false in compose/nexus.yaml) to
# LAB_PASSWORD, so packages.${LAB_DOMAIN} takes the same admin login as the rest of the lab.
# Idempotent: on a re-run admin123 no longer authenticates, so we detect LAB_PASSWORD already
# working and no-op. Soft-fails: a hiccup here never wedges the rest of the bootstrap.
rotate_nexus_admin_password() {
  [[ "$exported" == "1" ]] || { warn "lab CA not exported -- skipping Nexus admin rotation"; return; }

  local i code
  # nauth <user:pass> -- HTTP code from an admin-only endpoint: 200 if the creds authenticate,
  # 401 if not (anonymous lacks nx-users-read, so a bad password never masquerades as success).
  nauth() { ncurl -o /dev/null -w '%{http_code}' -u "$1" "${NEXUS_API}/security/users?userId=admin" 2>/dev/null || echo 000; }

  # Wait for readiness: /status is an unauthenticated probe that only 200s once the DB is up
  # (first boot ~1-2 min, during which Caddy 502s).
  log "waiting for Nexus (${NEXUS_HOST})"
  code=000
  for i in $(seq 1 40); do
    code="$(ncurl -o /dev/null -w '%{http_code}' "${NEXUS_API}/status" 2>/dev/null || echo 000)"
    [[ "$code" == 200 ]] && break
    sleep 3
  done
  [[ "$code" == 200 ]] || { warn "Nexus never became ready (last status: $code). Check 'docker compose ps nexus', then re-run ./bootstrap.sh (it's idempotent)."; return 1; }
  ok "Nexus is responding"

  # Already rotated (a re-run)? LAB_PASSWORD authenticates -> nothing to do.
  if [[ "$(nauth "admin:${LAB_PASSWORD}")" == 200 ]]; then
    ok "Nexus admin already uses LAB_PASSWORD"
    return 0
  fi
  # First run: must be able to log in with the well-known default before we change it.
  if [[ "$(nauth "admin:admin123")" != 200 ]]; then
    warn "Nexus admin authenticates with neither admin123 nor LAB_PASSWORD -- rotate it by hand in the UI (https://${NEXUS_HOST})"
    return 1
  fi
  # change-password wants the NEW password as a text/plain body; --data-raw sends it verbatim
  # (no @file / URL-encoding surprises for passwords with reserved chars). 204 == rotated.
  log "rotating the Nexus admin password to LAB_PASSWORD"
  code="$(ncurl -o /dev/null -w '%{http_code}' -X PUT \
    -H 'Content-Type: text/plain' --data-raw "$LAB_PASSWORD" \
    -u 'admin:admin123' "${NEXUS_API}/security/users/admin/change-password" 2>/dev/null || echo 000)"
  if [[ "$code" == 204 ]]; then
    ok "Nexus admin password rotated (admin / LAB_PASSWORD)"
  else
    warn "Nexus change-password returned $code -- rotate it by hand in the UI (https://${NEXUS_HOST})"
    return 1
  fi
}

# nexus_repo_exists <name> -- 200 from the repo endpoint means it's there, 404 means it isn't.
# This is the idempotency guard: re-POSTing an existing repo is a 400 ("Name is already used"),
# not a no-op, so every create checks first.
nexus_repo_exists() {
  [[ "$(nxadmin -o /dev/null -w '%{http_code}' "${NEXUS_API}/repositories/$1" 2>/dev/null || echo 000)" == 200 ]]
}

# nexus_hosted_body <name> [extra-json] -- the request body every hosted format shares, with
# per-format attributes ({"docker":{...}}, {"yum":{...}}, ...) merged in. writePolicy ALLOW
# permits redeploying the same version, which is what you want in a lab.
nexus_hosted_body() {
  local extra="${2:-}"
  [[ -n "$extra" ]] || extra='{}'
  jq -cn --arg name "$1" --argjson extra "$extra" \
    '{name: $name, online: true,
      storage: {blobStoreName: "default", strictContentTypeValidation: true, writePolicy: "ALLOW"}}
     + $extra'
}

# nexus_create_hosted <format> <name> [extra-json] -- POST one hosted repo, skipping it if it
# already exists. Every format is path-routed under packages.${LAB_DOMAIN}/repository/<name>/,
# so adding one never touches compose.
nexus_create_hosted() {
  local format="$1" name="$2" extra="${3:-}" out code
  if nexus_repo_exists "$name"; then
    ok "${name} already exists"
    return 0
  fi
  out="$(nxadmin -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' \
    --data-binary "$(nexus_hosted_body "$name" "$extra")" \
    "${NEXUS_API}/repositories/${format}/hosted" 2>/dev/null || echo $'\n000')"
  code="${out##*$'\n'}"
  if [[ "$code" == 201 ]]; then
    ok "created ${name} (${format}/hosted)"
  else
    warn "could not create ${name} (${format}/hosted): HTTP ${code} ${out%$'\n'*}"
    return 1
  fi
}

# nexus_enable_docker_realm -- docker-hosted below sets forceBasicAuth=false so anonymous
# `docker pull` works; Nexus requires the Docker Bearer Token realm to be active for that
# (pushes still authenticate). Idempotent: appends DockerToken only if it's missing.
nexus_enable_docker_realm() {
  local active code
  active="$(nxadmin "${NEXUS_API}/security/realms/active" 2>/dev/null)" || return 1
  if jq -e 'index("DockerToken")' <<<"$active" >/dev/null 2>&1; then
    ok "Docker Bearer Token realm already active"
    return 0
  fi
  code="$(nxadmin -o /dev/null -w '%{http_code}' -X PUT -H 'Content-Type: application/json' \
    --data-binary "$(jq -c '. + ["DockerToken"]' <<<"$active")" \
    "${NEXUS_API}/security/realms/active" 2>/dev/null || echo 000)"
  [[ "$code" == 204 ]] && { ok "enabled the Docker Bearer Token realm"; return 0; }
  warn "could not enable the Docker Bearer Token realm (HTTP ${code}) -- anonymous 'docker pull' will ask for a login"
  return 1
}

# nexus_apt_signing_keypair -- apt-hosted is the one format that can't be created from a plain
# JSON body: Nexus signs the repo METADATA (Release files) itself and demands an armored PGP
# private key up front. Generate a throwaway passphrase-less signing key in a temp GNUPGHOME,
# echo the private half for the request body, and leave the public half in lab-apt-signing.asc
# for clients to import. The private key lives only inside Nexus -- it never touches the repo.
nexus_apt_signing_keypair() {
  local home
  home="$(mktemp -d)" || return 1
  chmod 700 "$home"
  # shellcheck disable=SC2064   # expand $home now, not at trap time
  trap "rm -rf -- '$home'" RETURN
  gpg --batch --quiet --homedir "$home" --passphrase '' --pinentry-mode loopback \
    --quick-generate-key "SmallLab APT Signing <apt@${LAB_DOMAIN}>" rsa4096 sign never \
    >/dev/null 2>&1 || return 1
  gpg --batch --quiet --homedir "$home" --armor --export > "$NEXUS_APT_PUBKEY" 2>/dev/null || return 1
  gpg --batch --quiet --homedir "$home" --armor --export-secret-keys 2>/dev/null
}

# create_nexus_repositories -- HOSTED repos only, one per format: these are the "publish your
# own packages" endpoints. Proxy and group repos (mirroring npmjs/PyPI/crates.io/... for offline
# builds) are deliberately NOT created -- add them in the UI if you want caching; see Playbook.
create_nexus_repositories() {
  [[ "$exported" == "1" ]] || { warn "lab CA not exported -- skipping Nexus repository setup"; return; }
  # Nothing below works without a working admin login (a failed/partial rotation).
  if [[ "$(ncurl -o /dev/null -w '%{http_code}' -u "admin:${LAB_PASSWORD}" \
        "${NEXUS_API}/security/users?userId=admin" 2>/dev/null || echo 000)" != 200 ]]; then
    warn "Nexus admin login is not usable -- skipping repository setup"
    return 1
  fi

  nexus_create_hosted npm   npm-hosted
  nexus_create_hosted pypi  pypi-hosted
  nexus_create_hosted cargo cargo-hosted
  nexus_create_hosted go    go-hosted
  nexus_create_hosted raw   raw-hosted
  # repodataDepth 0 = RPMs uploaded at the repo root; PERMISSIVE skips the is-this-really-an-RPM
  # path check, so odd filenames don't 400 on upload.
  nexus_create_hosted yum   yum-hosted '{"yum":{"repodataDepth":0,"deployPolicy":"PERMISSIVE"}}'

  # Docker/OCI: the connector on :8082 is what compose/nexus.yaml maps to docker.${LAB_DOMAIN}.
  # forceBasicAuth=false + the Docker realm = anonymous pull, `docker login` to push.
  nexus_enable_docker_realm || true
  nexus_create_hosted docker docker-hosted \
    '{"docker":{"v1Enabled":false,"forceBasicAuth":false,"httpPort":8082}}'

  # apt last: it's the only one that generates key material, and the only one we skip silently
  # when its dependency (gpg) is missing.
  if nexus_repo_exists apt-hosted; then
    ok "apt-hosted already exists"
  elif ! command -v gpg >/dev/null 2>&1; then
    warn "gpg not installed -- skipping apt-hosted (it needs a PGP signing key; create it in the UI)"
  else
    local key
    log "generating a PGP signing key for apt-hosted"
    if ! key="$(nexus_apt_signing_keypair)" || [[ -z "$key" ]]; then
      warn "could not generate the apt signing key -- skipping apt-hosted"
    else
      nexus_create_hosted apt apt-hosted \
        "$(jq -cn --arg dist "$NEXUS_APT_DIST" --arg key "$key" \
             '{apt: {distribution: $dist}, aptSigning: {keypair: $key, passphrase: ""}}')" \
        && ok "apt signing public key written to $(basename "$NEXUS_APT_PUBKEY") (clients import it)"
    fi
  fi
}

log "configuring Nexus (always-on)"
# Repos need a working admin login, so the rotation gates the creation; either one falling over
# soft-fails the pair (the `!` also keeps set -e from tripping on the non-zero return).
if ! { rotate_nexus_admin_password && create_nexus_repositories; }; then
  warn "Nexus setup did not finish -- the rest of the stack is up; re-run ./bootstrap.sh to retry"
fi

# setup_sourcebot -- claim the Sourcebot OWNER account and mark the org onboarded, so
# search.${LAB_DOMAIN} lands on a usable search page instead of a setup wizard.
#
# WHY THIS IS FIDDLY. Sourcebot has no owner-seeding env var, no admin CLI, and no
# registration API. Two facts drive the steps below:
#   1. The FIRST account to register becomes OWNER. Until someone claims it, whoever browses
#      to the instance first gets it -- so bootstrap claims it as LAB_USER.
#   2. Anonymous access (FORCE_ENABLE_ANONYMOUS_ACCESS in compose/sourcebot.yaml) is NOT
#      enough on its own: the app shell also gates on Org.isOnboarded, and every visitor --
#      anonymous included -- is redirected to /onboard until that flag is set.
#
# Registration rides NextAuth's credentials provider, which creates the account when the
# email doesn't exist yet; it needs the CSRF double-submit dance (GET /api/auth/csrf, then a
# form-encoded POST echoing the cookie jar). Onboarding is a Next.js *server action*, which
# is not reasonably callable over curl -- its action ID changes per build -- so we set the
# flag with a direct UPDATE against sourcebot-db instead. That write is unsupported by
# upstream and could break on a major version bump; if it does, finish the wizard by hand at
# https://search.${LAB_DOMAIN}/onboard and everything else still works.
#
# Idempotent: a re-run re-POSTs the same credentials (NextAuth signs the existing user in
# rather than creating a second) and the UPDATE is a no-op once the flag is true. Soft-fails
# throughout -- a hiccup here never wedges the rest of the bootstrap.
setup_sourcebot() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sourcebot \
    || { warn "sourcebot container is not running -- skipping"; return 1; }
  [[ "$exported" == "1" ]] || { warn "lab CA not exported -- skipping Sourcebot setup"; return 1; }

  local host="search.${LAB_DOMAIN}" jar code csrf i
  jar="$(mktemp)"; trap 'rm -f "$jar"' RETURN
  # Same posture as the Nexus block: Sourcebot publishes no host port, so reach it over HTTPS
  # through Caddy with the name pinned to HOST_IP and verified against the exported lab CA.
  local -a scurl=(curl -sS --max-time 20 --resolve "${host}:443:${HOST_IP}" --cacert "$CA_OUT" -c "$jar" -b "$jar")

  # Wait for readiness. First boot runs prisma migrations before serving, so Caddy 502s for a
  # while; any response under 500 means the app is answering.
  log "waiting for Sourcebot (${host})"
  code=000
  for i in $(seq 1 40); do
    code="$("${scurl[@]}" -o /dev/null -w '%{http_code}' "https://${host}/" 2>/dev/null || echo 000)"
    [[ "$code" != 000 && "$code" -lt 500 ]] && break
    sleep 3
  done
  [[ "$code" != 000 && "$code" -lt 500 ]] \
    || { warn "Sourcebot never became ready (last status: $code). Check 'docker compose ps sourcebot', then re-run ./bootstrap.sh (it's idempotent)."; return 1; }
  ok "Sourcebot is responding"

  # Claim OWNER. NextAuth's credentials authorize() creates the account when the email is
  # unknown, and Sourcebot's onCreateUser hook makes the first member OWNER.
  local email="${LAB_USER}@${host}"
  log "claiming the Sourcebot owner account ($email)"
  csrf="$("${scurl[@]}" "https://${host}/api/auth/csrf" 2>/dev/null | jq -r '.csrfToken // empty')"
  if [[ -z "$csrf" ]]; then
    warn "could not fetch a CSRF token -- register the owner by hand at https://${host}/onboard"
  else
    code="$("${scurl[@]}" -o /dev/null -w '%{http_code}' \
      -X POST "https://${host}/api/auth/callback/credentials" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "email=${email}" \
      --data-urlencode "password=${LAB_PASSWORD}" \
      --data-urlencode "csrfToken=${csrf}" \
      --data-urlencode "callbackUrl=https://${host}/" 2>/dev/null || echo 000)"
    # A successful credentials sign-in redirects (302); 200 is also accepted since NextAuth's
    # response shape varies. Anything else means the account was not claimed.
    if [[ "$code" == 302 || "$code" == 200 ]]; then
      ok "owner account claimed ($email / LAB_PASSWORD)"
    else
      warn "owner registration returned $code -- register by hand at https://${host}/onboard"
    fi
  fi

  # Mark the single-tenant org onboarded (id 1 is seeded by Sourcebot's own migration).
  log "marking the Sourcebot org onboarded"
  if docker compose exec -T sourcebot-db \
       psql -v ON_ERROR_STOP=1 -U sourcebot -d sourcebot \
       -c 'UPDATE "Org" SET "isOnboarded" = true WHERE id = 1;' >/dev/null 2>&1; then
    ok "org marked onboarded -- anonymous search is live"
  else
    warn "could not set isOnboarded -- finish the wizard at https://${host}/onboard"
    return 1
  fi
}
log "configuring Sourcebot (always-on)"
setup_sourcebot \
  || warn "Sourcebot auto-setup did not finish -- the rest of the stack is up; re-run ./bootstrap.sh to retry"

# Print the client-side setup instructions.
cat <<EOF

$(printf '\033[1;32mBootstrap complete.\033[0m')  Dashboard: https://home.$LAB_DOMAIN

Next steps on each client machine
  1. Use Technitium for DNS  (authoritative for *.$LAB_DOMAIN, forwards the rest):
       point your resolver / router at  $HOST_IP

  2. Trust the step-ca root CA so HTTPS is valid (no browser warnings):
       Linux : sudo cp lab-root-ca.crt /usr/local/share/ca-certificates/lab-ca.crt && sudo update-ca-certificates
       macOS : sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain lab-root-ca.crt
       Windows: certutil -addstore -f Root lab-root-ca.crt   (elevated)

  3. GitLab & Mattermost (opt-in, heavy) -- start them with:
       docker compose --profile full-lab up -d && ./bootstrap.sh
     GitLab:     https://gitlab.$LAB_DOMAIN   (login: root / LAB_PASSWORD; first boot takes minutes)
     Mattermost: https://chat.$LAB_DOMAIN     (login: $LAB_USER / LAB_PASSWORD)
     Change both passwords in their UIs afterward, and mirror them in .env. See Playbook.

  4. Mount the file share (passwordless / guest):
       Linux  : sudo mount -t cifs //files.$LAB_DOMAIN/lab /mnt/lab -o guest,vers=3.0
       Windows: net use Z: \\\\files.$LAB_DOMAIN\\lab    (enable insecure guest logons first;
                Windows blocks guest SMB by default -- see README)

  5. Code search -- Sourcebot at https://search.$LAB_DOMAIN (anonymous read-only browsing; this
     script already claimed the owner account as $LAB_USER@search.$LAB_DOMAIN / LAB_PASSWORD for
     the admin settings). Index code by staging repos, then let it re-index (or restart now):
       ./ingest-repos.sh <archive.tar.gz|dir|git-clone> ...   &&   docker compose restart sourcebot
     Note it indexes GIT REPOS only -- ingest-repos.sh converts archives into one-commit repos
     and preserves real history when you hand it an actual clone.

  6. Package registry -- Nexus at https://packages.$LAB_DOMAIN (Docker/OCI on docker.$LAB_DOMAIN).
     This script rotated the admin from the admin123 first-boot default, so log in as
     admin / LAB_PASSWORD, and created one HOSTED repo per format -- publish to them now:
       npm-hosted  pypi-hosted  cargo-hosted  go-hosted  raw-hosted  yum-hosted  apt-hosted
       docker-hosted  (push/pull at docker.$LAB_DOMAIN; 'docker login' to push, anonymous pull)
     Pull URLs are https://packages.$LAB_DOMAIN/repository/<name>/ -- see Playbook for the
     per-format client setup. apt clients import ./lab-apt-signing.asc (Nexus signs the
     Release metadata with the key this script generated). Want to CACHE npmjs/PyPI/crates.io
     for offline builds? Add proxy + group repos in the UI -- Playbook has the layout.
EOF
