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
#   8. teaches uptime-kuma (Node) and vaultwarden (system store) to trust the lab root CA,
#      so their OUTBOUND HTTPS to *.${LAB_DOMAIN} verifies instead of erroring
#   9. configures Forgejo: creates the admin user and a PUBLIC packages org (named after
#      ${LAB_DOMAIN}) so package paths read packages.<dom>/<org>/...
#
# Everything is driven by curl against the Technitium and Forgejo APIs (plus one
# `forgejo admin user create` exec). Idempotent: re-running overwrites the A records,
# no-ops the zone create, and leaves an existing Technitium/Forgejo user or org untouched.
#
set -euo pipefail

# --- locate & load config ---------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] || { echo "error: .env not found next to bootstrap.sh" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source ./.env; set +a

: "${HOST_IP:?HOST_IP must be set in .env}"
: "${LAB_DOMAIN:?LAB_DOMAIN must be set in .env}"
: "${LAB_USER:?LAB_USER must be set in .env}"
: "${LAB_PASSWORD:?LAB_PASSWORD must be set in .env}"

# Forgejo packages org. Defaults to ${LAB_DOMAIN}, so package paths read
# packages.<dom>/<org>/... The Forgejo admin login is the shared LAB_USER / LAB_PASSWORD.
FORGEJO_ORG="${FORGEJO_ORG:-$LAB_DOMAIN}"
FORGEJO_WAIT_RETRIES="${FORGEJO_WAIT_RETRIES:-60}"   # readiness poll: this many x 3s (~3 min) for first boot

TECH="http://127.0.0.1:5380"            # Technitium API, published on loopback
CA_OUT="$SCRIPT_DIR/lab-root-ca.crt"    # step-ca's root -> the CA clients must trust
CA_SRC="/home/step/certs/root_ca.crt"   # path inside the step-ca container
STEPCA_CERT_TTL="${STEPCA_CERT_TTL:-2160h}"   # ACME cert lifetime (2160h = 90 days)

# --- pretty output ----------------------------------------------------------
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

# --- 1. wait for Technitium -------------------------------------------------
log "waiting for Technitium at $TECH"
for i in $(seq 1 60); do
  if curl -fsS --max-time 3 "$TECH/api/user/login" >/dev/null 2>&1; then
    ok "API is responding"; break
  fi
  [[ $i -eq 60 ]] && die "Technitium did not come up within ~2 min (is the stack running?)"
  sleep 2
done

# --- 2. authenticate --------------------------------------------------------
# Technitium's built-in admin is always named "admin" (no env renames it); only its
# password comes from .env, so we log in as admin / LAB_PASSWORD.
log "logging in to Technitium as 'admin'"
resp="$(curl -fsS --max-time 15 \
  "$TECH/api/user/login?user=admin&pass=$(urlenc "$LAB_PASSWORD")")" \
  || die "could not reach the Technitium API"
[[ "$(jq -r '.status // "error"' <<<"$resp")" == "ok" ]] \
  || die "login failed: $(jq -r '.errorMessage // "bad credentials"' <<<"$resp") -- check LAB_PASSWORD"
TOKEN="$(jq -r '.token' <<<"$resp")"
ok "authenticated"

# --- 2b. ensure the shared admin user (LAB_USER) in Technitium --------------
# Technitium's built-in admin can't be renamed, so to give the DNS console the SAME login
# as everything else, add LAB_USER to the Administrators group alongside it (same password).
# The built-in 'admin' stays as a fallback. Skipped when LAB_USER is literally 'admin'.
# Idempotent: an existing user is kept and its Administrators membership re-asserted.
ensure_technitium_admin_user() {
  [[ "$LAB_USER" == "admin" ]] && { ok "Technitium login is the built-in 'admin'"; return 0; }
  log "ensuring Technitium admin user '$LAB_USER'"
  local resp
  resp="$(tapi admin/users/create \
    "user=$(urlenc "$LAB_USER")" "displayName=$(urlenc "Lab Admin")" "pass=$(urlenc "$LAB_PASSWORD")")" || true
  case "$(jq -r '.status // "error"' <<<"$resp")" in
    ok) ok "user '$LAB_USER' created" ;;
    *)  grep -qi 'already exists' <<<"$resp" && ok "user '$LAB_USER' already exists" \
          || { warn "could not create Technitium user: $(jq -r '.errorMessage // .' <<<"$resp")"; return 1; } ;;
  esac
  # Re-assert Administrators membership (idempotent for a new or pre-existing user).
  resp="$(tapi admin/users/set "user=$(urlenc "$LAB_USER")" "memberOfGroups=Administrators")" || true
  [[ "$(jq -r '.status // "error"' <<<"$resp")" == "ok" ]] \
    && ok "'$LAB_USER' is in the Administrators group" \
    || { warn "could not add '$LAB_USER' to Administrators: $(jq -r '.errorMessage // .' <<<"$resp")"; return 1; }
}
ensure_technitium_admin_user \
  || warn "Technitium user setup incomplete -- the built-in 'admin' still works; re-run ./bootstrap.sh"

# --- 3. create the zone -----------------------------------------------------
log "ensuring primary zone '$LAB_DOMAIN'"
resp="$(tapi zones/create "zone=$(urlenc "$LAB_DOMAIN")" "type=Primary")" || true
case "$(jq -r '.status // "error"' <<<"$resp")" in
  ok) ok "zone created" ;;
  *)  grep -qi 'already exists' <<<"$resp" && ok "zone already exists" \
        || die "zone create failed: $resp" ;;
esac

# --- 4. point the records at the host --------------------------------------
add_a() {  # add_a <name> <ip>
  local name="$1" ip="$2" resp
  resp="$(tapi zones/records/add \
    "domain=$(urlenc "$name")" "zone=$(urlenc "$LAB_DOMAIN")" \
    "type=A" "ipAddress=$ip" "ttl=300" "overwrite=true")"
  [[ "$(jq -r '.status // "error"' <<<"$resp")" == "ok" ]] \
    || die "failed to add A $name -> $ip: $resp"
  ok "A  $name -> $ip"
}
log "writing A records -> $HOST_IP"
add_a "*.$LAB_DOMAIN" "$HOST_IP"   # wildcard covers home.lab, dns.lab, packages.lab, ...
add_a "$LAB_DOMAIN"   "$HOST_IP"   # apex, for bare \\lab style references

# --- 5. export step-ca's root CA -------------------------------------------
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

# --- 6. set the ACME certificate lifetime (step-ca default is 24h) ---------
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

# --- 7. reload Caddy now that DNS resolves and the CA exists ----------------
# Caddy can only obtain certs once *.lab resolves (step 4) and it trusts step-ca's
# root (mounted from the shared volume). Restarting makes issuance happen now
# instead of on Caddy's next retry.
if [[ "$exported" == "1" ]]; then
  log "reloading Caddy to trigger certificate issuance"
  docker compose restart caddy >/dev/null 2>&1 && ok "Caddy reloaded" \
    || warn "could not restart Caddy; run 'docker compose restart caddy' yourself"
fi

# --- 8. teach uptime-kuma + vaultwarden to trust the lab CA ----------------
# These two make OUTBOUND HTTPS calls to *.lab and so need the lab root in their OWN trust
# store (a client connecting *to* a service only needs the CA on the client side):
#   * uptime-kuma (Node) reads NODE_EXTRA_CA_CERTS, which compose points at
#     /app/data/lab-root-ca.crt -- inside its persistent data volume, so the trust survives
#     recreates. Drop the exported CA there and restart.
#   * vaultwarden's binary is OpenSSL-linked, so it trusts the system store: install the CA
#     under /usr/local/share/ca-certificates and run update-ca-certificates. That lives in
#     the container's writable layer (lost on --force-recreate / image bump), but re-running
#     bootstrap re-applies it -- which is already the post-recreate routine.
# Soft-fails throughout: a hiccup here never wedges the rest of the bootstrap.
trust_lab_ca() {
  [[ "$exported" == "1" ]] || { warn "lab CA not exported -- skipping container CA trust"; return; }

  # uptime-kuma: file in the data volume; NODE_EXTRA_CA_CERTS is already set in compose.
  if docker compose cp "$CA_OUT" uptime-kuma:/app/data/lab-root-ca.crt >/dev/null 2>&1 \
     && docker compose restart uptime-kuma >/dev/null 2>&1; then
    ok "uptime-kuma trusts the lab CA (NODE_EXTRA_CA_CERTS)"
  else
    warn "could not install the CA into uptime-kuma -- is it up? ('docker compose ps uptime-kuma')"
  fi

  # vaultwarden: system trust store (OpenSSL-linked binary), then restart so it reloads it.
  if docker compose cp "$CA_OUT" vaultwarden:/usr/local/share/ca-certificates/lab-root-ca.crt >/dev/null 2>&1 \
     && docker compose exec -T vaultwarden update-ca-certificates >/dev/null 2>&1 \
     && docker compose restart vaultwarden >/dev/null 2>&1; then
    ok "vaultwarden trusts the lab CA (system store)"
  else
    warn "could not install the CA into vaultwarden -- is it up? ('docker compose ps vaultwarden')"
  fi
}
log "teaching uptime-kuma + vaultwarden to trust the lab CA"
trust_lab_ca

# --- 9. Forgejo: admin user + public packages org --------------------------
# Forgejo runs headless (INSTALL_LOCK=true) so on first boot it has no users. Create the
# admin via the CLI inside the container, then create a PUBLIC org named ${FORGEJO_ORG}
# over the REST API so its packages are anonymously pullable. Packages themselves are
# created on first push (twine upload, npm publish, docker push) -- nothing to pre-make.
# Idempotent: an existing user/org is left untouched. Soft-fails so a hiccup here never
# wedges the rest of the bootstrap; a re-run finishes the job.
setup_forgejo() {
  local host="packages.${LAB_DOMAIN}"
  local base="https://${host}/api/v1"
  local org="$FORGEJO_ORG"
  local email="${LAB_USER}@${host}"

  # curl bound to the vhost (the host's resolver may not point at Technitium) + lab CA.
  local -a fc=(curl -sS --max-time 20 --resolve "${host}:443:${HOST_IP}"
               -u "${LAB_USER}:${LAB_PASSWORD}")
  if [[ -s "$CA_OUT" ]]; then
    fc+=(--cacert "$CA_OUT")
  else
    warn "lab CA ($CA_OUT) missing -- contacting Forgejo without TLS verification"
    fc+=(--insecure)
  fi

  # --- wait for the HTTP API to report healthy --------------------------------
  log "waiting for Forgejo at https://${host}"
  local i ready=0
  for i in $(seq 1 "$FORGEJO_WAIT_RETRIES"); do
    if "${fc[@]}" "https://${host}/api/healthz" 2>/dev/null | grep -q '"status": *"pass"'; then
      ok "Forgejo is responding"; ready=1; break
    fi
    sleep 3
  done
  [[ "$ready" == 1 ]] || { warn "Forgejo never became ready. Check 'docker compose ps forgejo',
        then re-run ./bootstrap.sh (it's idempotent)."; return 1; }

  # --- ensure the admin user (CLI, inside the container) ----------------------
  log "ensuring Forgejo admin '$LAB_USER'"
  local out
  if out="$(docker compose exec -T --user git forgejo forgejo admin user create \
        --admin --username "$LAB_USER" --password "$LAB_PASSWORD" \
        --email "$email" --must-change-password=false 2>&1)"; then
    ok "admin user created"
  elif grep -qiE 'already exist' <<<"$out"; then
    ok "admin user already exists"
  else
    warn "could not create admin user: $out"; return 1
  fi

  # --- ensure the public packages org -----------------------------------------
  log "ensuring public org '$org'"
  local code
  code="$("${fc[@]}" -o /dev/null -w '%{http_code}' "${base}/orgs/${org}")"
  if [[ "$code" == 200 ]]; then
    ok "org '$org' already exists"
  else
    code="$("${fc[@]}" -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
            --data "$(jq -nc --arg n "$org" '{username:$n, visibility:"public"}')" "${base}/orgs")"
    [[ "$code" == 2?? ]] && ok "org '$org' created (public)" \
      || { warn "creating org '$org' failed (HTTP $code)"; return 1; }
  fi

  ok "Forgejo configured: admin '$LAB_USER', public org '$org'"
}

log "configuring Forgejo (admin user + packages org)"
setup_forgejo \
  || warn "Forgejo auto-setup did not finish -- the rest of the stack is up; re-run ./bootstrap.sh to retry"

# --- 10. Forgejo Actions runner: register via the shared-secret flow ---------
# Air-gapped registration with no token round-trip: a 40-hex secret is the shared identity.
# ALL runner-volume reads/writes go through `docker compose exec` (i.e. as the container's
# own uid 1000), so they work regardless of who owns volumes/forgejo-runner on the host --
# the host user that runs bootstrap is NOT uid 1000 and can't write into that dir directly.
# Idempotent + soft-failing: if the runner is already registered we stop; otherwise the
# secret is generated once, persisted in the data volume, and reused on every re-run (a fresh
# secret would register a *second* runner, since the secret's first 16 hex are its identity).
setup_forgejo_runner() {
  local name="lab-runner"

  # already registered? (.runner lives in the runner's data volume, written by the container)
  if docker compose exec -T forgejo-runner test -s /data/.runner 2>/dev/null; then
    ok "runner already registered (/data/.runner present)"; return 0
  fi

  # 1. shared secret: reuse the persisted one, else generate on the host (openssl) and persist
  #    it INTO the data volume via the container (umask 077 -> mode 600, owned by uid 1000).
  # `|| true` INSIDE the container: a missing /data/secret (the normal first-run case) must
  # read as "empty", not as a failure -- otherwise pipefail would propagate cat's non-zero and
  # we'd bail before generating one. A genuinely-down container makes `exec` itself fail, which
  # the inner `|| true` can't mask, so the outer `||` still catches that case correctly.
  local secret
  secret="$(docker compose exec -T forgejo-runner sh -c 'cat /data/secret 2>/dev/null || true' | tr -d '\r\n')" \
    || { warn "could not reach the forgejo-runner container (down or crash-looping). Check:
        docker compose ps forgejo-runner ; docker compose logs --tail=40 forgejo-runner
   If it loops on a stale registration, clear it and bring it up clean, then re-run bootstrap:
        sudo rm -f volumes/forgejo-runner/.runner volumes/forgejo-runner/secret
        docker compose up -d forgejo-runner"; return 1; }
  if [[ ! "$secret" =~ ^[0-9a-fA-F]{40}$ ]]; then
    secret="$(openssl rand -hex 20)"
    if printf '%s' "$secret" | docker compose exec -T forgejo-runner sh -c 'umask 077; cat > /data/secret' 2>/dev/null; then
      ok "generated runner secret -> volumes/forgejo-runner/secret"
    else
      warn "could not write /data/secret in the runner container. volumes/forgejo-runner must be
        owned by uid 1000 (the runner's user) -- Docker creates it as root if it's missing at
        first 'up'. Fix on the host, then re-run bootstrap:
        sudo chown -R 1000:1000 volumes/forgejo-runner"; return 1
    fi
  fi

  # 2. register on the forge (idempotent global runner). The shared LAB posture already passes
  #    secrets on the exec argv (see the admin-create above), so --secret is fine here.
  log "registering Forgejo runner '$name' on the forge"
  if docker compose exec -T --user git forgejo \
       forgejo forgejo-cli actions register --name "$name" --secret "$secret" >/dev/null 2>&1; then
    ok "runner registered on the forge"
  else
    warn "could not register the runner (is forgejo up?) -- re-run ./bootstrap.sh"; return 1
  fi

  # 3. write the runner file on the runner side (creates /data/.runner as uid 1000).
  log "creating the runner registration file"
  if docker compose exec -T forgejo-runner \
       forgejo-runner create-runner-file --instance http://forgejo:3000 \
         --secret "$secret" --name "$name" --config /data/config.yaml >/dev/null 2>&1; then
    ok "runner file created -- the daemon will pick up jobs shortly"
  else
    warn "could not create the runner file (is the forgejo-runner container up?) -- re-run ./bootstrap.sh"; return 1
  fi
}
log "configuring the Forgejo Actions runner"
setup_forgejo_runner \
  || warn "Forgejo runner setup did not finish -- the rest of the stack is up; re-run ./bootstrap.sh to retry"

# --- next steps -------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32mBootstrap complete.\033[0m')  Dashboard: https://home.$LAB_DOMAIN

Next steps on each client machine
  1. Use Technitium for DNS  (authoritative for *.$LAB_DOMAIN, forwards the rest):
       point your resolver / router at  $HOST_IP

  2. Trust the step-ca root CA so HTTPS is valid (no browser warnings):
       Linux : sudo cp lab-root-ca.crt /usr/local/share/ca-certificates/lab-ca.crt && sudo update-ca-certificates
       macOS : sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain lab-root-ca.crt
       Windows: certutil -addstore -f Root lab-root-ca.crt   (elevated)

  3. Packages -- Forgejo at https://packages.$LAB_DOMAIN (Docker must trust the CA):
       sudo mkdir -p /etc/docker/certs.d/packages.$LAB_DOMAIN
       sudo cp lab-root-ca.crt /etc/docker/certs.d/packages.$LAB_DOMAIN/ca.crt
     A PUBLIC org '$FORGEJO_ORG' was created; anonymous pull/download works now. Push
     authenticates as the admin (or a token you create in the UI):
       docker login packages.$LAB_DOMAIN -u $LAB_USER
       docker tag alpine packages.$LAB_DOMAIN/$FORGEJO_ORG/alpine:latest
       docker push packages.$LAB_DOMAIN/$FORGEJO_ORG/alpine:latest
       twine upload --repository-url https://packages.$LAB_DOMAIN/api/packages/$FORGEJO_ORG/pypi -u $LAB_USER dist/*
     Change the admin password in the UI afterward, and mirror it in .env. See README.

  4. Mount the file share (passwordless / guest):
       Linux  : sudo mount -t cifs //files.$LAB_DOMAIN/lab /mnt/lab -o guest,vers=3.0
       Windows: net use Z: \\\\files.$LAB_DOMAIN\\lab    (enable insecure guest logons first;
                Windows blocks guest SMB by default -- see README)
EOF
