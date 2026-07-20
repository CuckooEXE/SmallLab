#!/usr/bin/env bash
#
# test.sh -- end-to-end smoke test of the .lab stack.
#
# Exercises every service the way a client would: HTTPS through Caddy (verified
# against the exported root CA), DNS through Technitium, and the SMB / WebDAV / S3
# data paths. Run after `docker compose up -d && ./bootstrap.sh`.
#
# The host does NOT need to resolve *.lab: HTTPS tests pin each name to HOST_IP with
# `curl --resolve`, the S3 test uses a containerized `mc` with `--add-host`, and SMB
# connects to HOST_IP directly. Everything is verified against ./lab-root-ca.crt, so a
# green run also proves the step-ca -> Caddy certificate chain is trusted end to end.
#
#   ./test.sh
#
# Exit status is non-zero if any check FAILs (SKIPs don't fail the run).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

[[ -f .env ]] || { echo "error: .env not found next to test.sh" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source ./.env
set +a
: "${HOST_IP:?HOST_IP must be set in .env}"
: "${LAB_DOMAIN:?LAB_DOMAIN must be set in .env}"

CA="$SCRIPT_DIR/lab-root-ca.crt"
[[ -s "$CA" ]] || { echo "error: $CA missing -- run ./bootstrap.sh first" >&2; exit 1; }
STAMP="$(date +%Y%m%d%H%M%S)-$$"

# Test harness: result counters and the pass/fail/skip/section/have helpers.
PASS=0; FAIL=0; SKIP=0
pass()    { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
fail()    { printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
skip()    { printf '  \033[1;33mSKIP\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; SKIP=$((SKIP+1)); }
section() { printf '\n\033[1;34m== %s ==\033[0m\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

# labcurl <host> <curl-args...> -- HTTPS to a *.lab vhost, name pinned to HOST_IP,
# verified against the lab root CA. Port defaults to 443; pass --resolve yourself for
# a non-443 port (used for ca.lab:9000).
labcurl() { local host="$1"; shift; curl -sS --max-time 20 --resolve "${host}:443:${HOST_IP}" --cacert "$CA" "$@"; }

# get_code_any <desc> <host> <path> <code>...  -- GET, assert the status is one of <code>...
# For apps whose landing page may legitimately 200 or redirect depending on session state.
get_code_any() {
  local desc="$1" host="$2" path="$3"; shift 3
  local code want
  code="$(labcurl "$host" -o /dev/null -w '%{http_code}' "https://${host}${path}" 2>/dev/null)" \
    || { fail "$desc" "curl could not connect to ${host}"; return; }
  for want in "$@"; do
    [[ "$code" == "$want" ]] && { pass "$desc (HTTP $code)"; return; }
  done
  fail "$desc" "expected one of [$*], got $code"
}

# get_code <desc> <host> <path> [expected]  -- GET, assert HTTP status (default 200).
get_code() {
  local desc="$1" host="$2" path="$3" want="${4:-200}" code
  code="$(labcurl "$host" -o /dev/null -w '%{http_code}' "https://${host}${path}" 2>/dev/null)" \
    || { fail "$desc" "curl could not connect to ${host}"; return; }
  if [[ "$code" == "$want" ]]; then pass "$desc (HTTP $code)"; else fail "$desc" "expected $want, got $code"; fi
}

section "DNS (Technitium @ ${HOST_IP})"
if have dig; then
  got="$(dig +short +time=3 +tries=1 @"$HOST_IP" "home.${LAB_DOMAIN}" 2>/dev/null | tail -1)"
  if [[ "$got" == "$HOST_IP" ]]; then
    pass "wildcard *.${LAB_DOMAIN} resolves to host (home.${LAB_DOMAIN} -> $got)"
  else
    fail "wildcard resolution" "home.${LAB_DOMAIN} -> '${got:-<none>}', expected $HOST_IP"
  fi
  got="$(dig +short +time=3 +tries=1 @"$HOST_IP" "gitlab.${LAB_DOMAIN}" 2>/dev/null | tail -1)"
  if [[ "$got" == "$HOST_IP" ]]; then
    pass "gitlab.${LAB_DOMAIN} -> $got"
  else
    fail "gitlab.${LAB_DOMAIN} resolution" "got '${got:-<none>}'"
  fi
  got="$(dig +short +time=3 +tries=1 @"$HOST_IP" example.com 2>/dev/null | tail -1)"
  if [[ -n "$got" ]]; then
    pass "recursive forwarding works (example.com -> $got)"
  else
    fail "recursive forwarding" "example.com did not resolve via the lab DNS"
  fi
else
  skip "DNS checks" "dig not installed"
fi

section "TLS (step-ca -> Caddy, verified against lab-root-ca.crt)"
vr="$(labcurl "home.${LAB_DOMAIN}" -o /dev/null -w '%{ssl_verify_result}' "https://home.${LAB_DOMAIN}/" 2>/dev/null)"
if [[ "$vr" == "0" ]]; then
  pass "home.${LAB_DOMAIN} cert verifies against the lab root CA"
else
  fail "cert verification" "ssl_verify_result=$vr (cert does not chain to lab-root-ca.crt)"
fi
if have openssl; then
  issuer="$(echo | openssl s_client -connect "${HOST_IP}:443" -servername "home.${LAB_DOMAIN}" -CAfile "$CA" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
  # step-ca names its root/intermediate after STEPCA_NAME (.env), e.g. "self CA Intermediate CA".
  if grep -qiF "${STEPCA_NAME:-lab CA}" <<<"$issuer"; then
    pass "issuer is the lab CA (${issuer#issuer=})"
  else
    fail "cert issuer" "unexpected issuer: ${issuer:-<none>}"
  fi
fi

section "HTTP endpoints (through Caddy)"
get_code "Homepage        home.${LAB_DOMAIN}"        "home.${LAB_DOMAIN}"        "/"
get_code "Technitium UI   dns.${LAB_DOMAIN}"         "dns.${LAB_DOMAIN}"         "/"
get_code "FileBrowser     files.${LAB_DOMAIN}"       "files.${LAB_DOMAIN}"       "/"
get_code "CyberChef       cyberchef.${LAB_DOMAIN}"   "cyberchef.${LAB_DOMAIN}"   "/"
get_code "IT-Tools        tools.${LAB_DOMAIN}"       "tools.${LAB_DOMAIN}"       "/"
get_code "DevDocs         devdocs.${LAB_DOMAIN}"     "devdocs.${LAB_DOMAIN}"     "/"
get_code "drawio          draw.${LAB_DOMAIN}"        "draw.${LAB_DOMAIN}"        "/"
get_code "PrivateBin      paste.${LAB_DOMAIN}"       "paste.${LAB_DOMAIN}"       "/"
get_code "Vaultwarden     vault.${LAB_DOMAIN}"       "vault.${LAB_DOMAIN}"       "/alive"
get_code "Dozzle          logs.${LAB_DOMAIN}"        "logs.${LAB_DOMAIN}"        "/"
get_code "MinIO console   s3-console.${LAB_DOMAIN}"  "s3-console.${LAB_DOMAIN}"  "/"
# (GitLab / Mattermost are opt-in -- checked in the full-lab section below)

# Dev tooling + offline references. The doc sites return 200 only once ./build.sh has
# built their images (lab/<name>:latest) and they're present on the host.
get_code "Compiler Explorer godbolt.${LAB_DOMAIN}"  "godbolt.${LAB_DOMAIN}"     "/"
get_code "cppreference    cppref.${LAB_DOMAIN}"      "cppref.${LAB_DOMAIN}"      "/"
get_code "x86 ref         x86.${LAB_DOMAIN}"         "x86.${LAB_DOMAIN}"         "/"
get_code "ARM ref         arm.${LAB_DOMAIN}"         "arm.${LAB_DOMAIN}"         "/"
get_code "tldr            tldr.${LAB_DOMAIN}"        "tldr.${LAB_DOMAIN}"        "/"
get_code "Syscall tables  syscalls.${LAB_DOMAIN}"   "syscalls.${LAB_DOMAIN}"    "/"
get_code "DevHints        devhints.${LAB_DOMAIN}"    "devhints.${LAB_DOMAIN}"    "/"
get_code "ExplainShell    explainshell.${LAB_DOMAIN}" "explainshell.${LAB_DOMAIN}" "/"
get_code "HackTricks      hacktricks.${LAB_DOMAIN}"  "hacktricks.${LAB_DOMAIN}"  "/"
get_code "GTFOBins        gtfobins.${LAB_DOMAIN}"    "gtfobins.${LAB_DOMAIN}"    "/"
get_code "LOLBAS          lolbas.${LAB_DOMAIN}"      "lolbas.${LAB_DOMAIN}"      "/"
get_code "PayloadsAllTheThings payloads.${LAB_DOMAIN}" "payloads.${LAB_DOMAIN}" "/"

# Interactive programming tools + services. Built images (lab/<name>) come from ./build.sh; the
# rest are pinned upstream images -- all 200 once present on the host.
# Sourcebot's landing page serves anonymously once bootstrap.sh has claimed the owner and
# marked the org onboarded; before that it redirects to /onboard. Accept either -- this line
# proves the TLS + proxy + app path is healthy, not that onboarding ran (bootstrap reports that).
get_code_any "Sourcebot       search.${LAB_DOMAIN}"      "search.${LAB_DOMAIN}"      "/"  200 302 307
# PlantUML's welcome page 302-redirects / to a demo diagram (/uml/<hash>); that redirect is the
# server's readiness signal, so assert 302 rather than following through to the rendered 200.
get_code "PlantUML        plantuml.${LAB_DOMAIN}"    "plantuml.${LAB_DOMAIN}"    "/"    302
get_code "AST Explorer    ast.${LAB_DOMAIN}"         "ast.${LAB_DOMAIN}"         "/"
get_code "JSON Crack      jsoncrack.${LAB_DOMAIN}"   "jsoncrack.${LAB_DOMAIN}"   "/"
get_code "Mermaid Live    mermaid.${LAB_DOMAIN}"     "mermaid.${LAB_DOMAIN}"     "/"
get_code "SQLime          sqlime.${LAB_DOMAIN}"      "sqlime.${LAB_DOMAIN}"      "/"
get_code "jq kung fu      jq.${LAB_DOMAIN}"          "jq.${LAB_DOMAIN}"          "/"
get_code "LibreTranslate  translate.${LAB_DOMAIN}"   "translate.${LAB_DOMAIN}"   "/"
get_code "Stirling-PDF    pdf.${LAB_DOMAIN}"         "pdf.${LAB_DOMAIN}"         "/"
get_code "ConvertX        convert.${LAB_DOMAIN}"     "convert.${LAB_DOMAIN}"     "/"
get_code "sist2 search    find.${LAB_DOMAIN}"        "find.${LAB_DOMAIN}"        "/"

section "step-ca (ACME CA)"
body="$(curl -sS --max-time 15 --resolve "ca.${LAB_DOMAIN}:9000:${HOST_IP}" --cacert "$CA" "https://ca.${LAB_DOMAIN}:9000/health" 2>/dev/null)"
if grep -q '"status":"ok"' <<<"$body"; then
  pass "ca.${LAB_DOMAIN}:9000/health is ok"
else
  fail "step-ca health" "response: ${body:-<none>}"
fi

section "WebDAV (dav.${LAB_DOMAIN})"
dav="https://dav.${LAB_DOMAIN}"
f="smoke-${STAMP}.txt"; d="smoke-dir-${STAMP}"; content="webdav-content-${STAMP}"
tmp="$(mktemp)"; printf '%s' "$content" > "$tmp"
code="$(labcurl "dav.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' -T "$tmp" "${dav}/${f}" 2>/dev/null)"
if [[ "$code" == 201 ]]; then pass "PUT ${f} (HTTP $code)"; else fail "WebDAV PUT" "expected 201, got $code"; fi
got="$(labcurl "dav.${LAB_DOMAIN}" "${dav}/${f}" 2>/dev/null)"
if [[ "$got" == "$content" ]]; then pass "GET ${f} round-trips identical bytes"; else fail "WebDAV GET" "body mismatch: '${got}'"; fi
code="$(labcurl "dav.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' -X MKCOL "${dav}/${d}/" 2>/dev/null)"
if [[ "$code" == 201 ]]; then pass "MKCOL ${d}/ (HTTP $code)"; else fail "WebDAV MKCOL" "expected 201, got $code"; fi
code="$(labcurl "dav.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' -X DELETE "${dav}/${d}/" 2>/dev/null)"
if [[ "$code" == 204 ]]; then pass "DELETE ${d}/ (HTTP $code)"; else fail "WebDAV DELETE dir" "expected 204, got $code"; fi
rm -f "$tmp"
# Leave ${f} in place for the interop check below, which deletes it afterward.

section "File share interop (WebDAV <-> Samba, same tree)"
if have smbclient; then
  out="$(mktemp)"
  if smbclient -N "//${HOST_IP}/lab" -c "get ${f} ${out}" >/dev/null 2>&1 \
     && [[ "$(cat "$out")" == "$content" ]]; then
    pass "file written over WebDAV reads back identical over SMB guest"
  else
    fail "WebDAV/SMB interop" "could not read ${f} over SMB, or content differed"
  fi
  rm -f "$out"
  # standalone SMB write/read/delete round-trip
  sf="smb-${STAMP}.txt"; sin="$(mktemp)"; sout="$(mktemp)"; printf 'smb-content-%s' "$STAMP" > "$sin"
  if smbclient -N "//${HOST_IP}/lab" -c "put ${sin} ${sf}; get ${sf} ${sout}; del ${sf}" >/dev/null 2>&1 \
     && diff -q "$sin" "$sout" >/dev/null 2>&1; then
    pass "SMB guest put/get/delete round-trip"
  else
    fail "SMB round-trip" "guest put/get/delete failed or content differed"
  fi
  rm -f "$sin" "$sout"
  # Samba's recycle VFS moves SMB-deleted files to .deleted/ rather than unlinking them;
  # purge our copy via WebDAV (a real delete on the same tree) so the test leaves nothing.
  labcurl "dav.${LAB_DOMAIN}" -o /dev/null -X DELETE "${dav}/.deleted/${sf}" 2>/dev/null || true
else
  skip "SMB interop checks" "smbclient not installed"
fi
# clean up the WebDAV test file
labcurl "dav.${LAB_DOMAIN}" -o /dev/null -X DELETE "${dav}/${f}" 2>/dev/null || true

section "MinIO object storage (s3.${LAB_DOMAIN})"
if have docker && docker image inspect minio/mc:latest >/dev/null 2>&1; then
  bucket="smoke-${STAMP}"
  if docker run --rm \
       --add-host "s3.${LAB_DOMAIN}:${HOST_IP}" \
       -e MC_HOST_lab="https://${LAB_USER}:${LAB_PASSWORD}@s3.${LAB_DOMAIN}" \
       -v "${CA}:/root/.mc/certs/CAs/lab.crt:ro" \
       --entrypoint /bin/sh minio/mc:latest -c "
         set -e
         echo 's3-content-${STAMP}' > /tmp/o.txt
         mc mb --ignore-existing lab/${bucket}
         mc cp /tmp/o.txt lab/${bucket}/o.txt
         test \"\$(mc cat lab/${bucket}/o.txt)\" = 's3-content-${STAMP}'
         mc rm lab/${bucket}/o.txt
         mc rb lab/${bucket}
       " >/dev/null 2>&1; then
    pass "S3 bucket create / put / get / delete round-trip (verified TLS via Caddy)"
  else
    fail "MinIO S3" "mc lifecycle against https://s3.${LAB_DOMAIN} failed"
  fi
else
  skip "MinIO S3 check" "needs the minio/mc image (docker pull minio/mc)"
fi

# Nexus is always-on (no compose profile) -- the artifact backbone, same tier as MinIO above.
# packages.lab serves the web UI and every non-Docker format (npm/pip/apt/raw/go/...) on :8081;
# /service/rest/v1/status is an unauthenticated readiness probe that only 200s once the DB has
# finished initialising (first boot takes ~1-2 min, during which Caddy 502s).
section "Nexus Repository (packages.${LAB_DOMAIN} + docker.${LAB_DOMAIN})"
get_code "Nexus UI        packages.${LAB_DOMAIN}"     "packages.${LAB_DOMAIN}"    "/"
get_code "Nexus status    packages.${LAB_DOMAIN}"     "packages.${LAB_DOMAIN}"    "/service/rest/v1/status"
# The hosted repos bootstrap.sh creates (one per format). The repo endpoint answers anonymously,
# so no credentials are needed: 200 = the repo is there, 404 = bootstrap never got to it.
for nxrepo in npm-hosted pypi-hosted cargo-hosted go-hosted raw-hosted yum-hosted apt-hosted; do
  get_code "Nexus repo      ${nxrepo}" "packages.${LAB_DOMAIN}" "/service/rest/v1/repositories/${nxrepo}"
done
# docker.lab is docker-hosted's registry connector on :8082, created by bootstrap.sh along with
# the repo. The OCI /v2/ base returns 401 (the Docker Bearer Token challenge -- a live registry;
# the docker client follows it to /v2/token) or 200. Anything else means the connector isn't
# listening: either bootstrap hasn't run, or Caddy dropped the docker.lab block (check
# `docker logs caddy` for "unrecognized directive").
dcode="$(labcurl "docker.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' "https://docker.${LAB_DOMAIN}/v2/" 2>/dev/null || echo 000)"
if [[ "$dcode" == 200 || "$dcode" == 401 ]]; then
  pass "Nexus Docker registry docker.${LAB_DOMAIN}/v2/ (HTTP $dcode)"
else
  fail "Nexus Docker registry" "docker.${LAB_DOMAIN}/v2/ -> ${dcode} (re-run ./bootstrap.sh)"
fi

# GitLab and Mattermost are opt-in (--profile full-lab); each check runs only when its
# container is up, and SKIPs (never FAILs) when the profile is off.
section "full-lab profile (GitLab & Mattermost -- opt-in)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx gitlab; then
  get_code "GitLab sign-in  gitlab.${LAB_DOMAIN}" "gitlab.${LAB_DOMAIN}" "/users/sign_in"
else
  skip "GitLab checks" "not enabled -- start with: docker compose --profile full-lab up -d"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mattermost; then
  body="$(labcurl "chat.${LAB_DOMAIN}" "https://chat.${LAB_DOMAIN}/api/v4/system/ping" 2>/dev/null)"
  if grep -q '"status" *: *"OK"' <<<"$body"; then
    pass "Mattermost ping  chat.${LAB_DOMAIN} (status OK)"
  else
    fail "Mattermost ping" "response: ${body:-<none>}"
  fi
else
  skip "Mattermost checks" "not enabled -- start with: docker compose --profile full-lab up -d"
fi

# Ollama + Open WebUI are opt-in (--profile ai-<cpu|nvidia|amd|intel>); every accelerator
# variant runs as the container `ollama`, so one name check covers all four. SKIPs when off.
section "AI profile (Ollama & Open WebUI -- opt-in)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ollama; then
  body="$(labcurl "ollama.${LAB_DOMAIN}" "https://ollama.${LAB_DOMAIN}/api/version" 2>/dev/null)"
  if grep -q '"version"' <<<"$body"; then
    pass "Ollama API   ollama.${LAB_DOMAIN}/api/version ($(grep -oE '"version" *: *"[^"]+"' <<<"$body"))"
  else
    fail "Ollama API" "GET /api/version -> ${body:-<none>} (accelerator backend still loading?)"
  fi
  # Context length is server-side only: the /v1 endpoint can't carry num_ctx, so if this regresses
  # to Ollama's 4096 default, clients like OpenCode don't error -- their prompts are silently
  # truncated and the model just gets quietly worse. Assert the env, then the effective value.
  want_ctx=32768
  got_ctx="$(docker compose exec -T ollama sh -c 'printf %s "$OLLAMA_CONTEXT_LENGTH"' 2>/dev/null | tr -d '\r')"
  if [ "$got_ctx" = "$want_ctx" ]; then
    pass "Ollama ctx   OLLAMA_CONTEXT_LENGTH=${got_ctx}"
  else
    fail "Ollama ctx" "OLLAMA_CONTEXT_LENGTH=${got_ctx:-<unset>}, want ${want_ctx} (compose/ollama.yaml)"
  fi
  # /api/ps reports context_length per loaded model -- the value actually in force. Only
  # meaningful with a model resident, so SKIP rather than fail on an idle runtime.
  ps_body="$(labcurl "ollama.${LAB_DOMAIN}" "https://ollama.${LAB_DOMAIN}/api/ps" 2>/dev/null)"
  if grep -q '"context_length"' <<<"$ps_body"; then
    eff_ctx="$(grep -oE '"context_length" *: *[0-9]+' <<<"$ps_body" | grep -oE '[0-9]+$' | head -1)"
    if [ "$eff_ctx" = "$want_ctx" ]; then
      pass "Ollama ctx   loaded model serving ${eff_ctx} tokens"
    else
      fail "Ollama ctx" "loaded model serving ${eff_ctx} tokens, want ${want_ctx} (Modelfile num_ctx overriding?)"
    fi
  else
    skip "Ollama ctx (effective)" "no model resident -- load one: docker compose exec ollama ollama run llama3.2:3b hi"
  fi
else
  skip "Ollama checks" "not enabled -- start with: docker compose --profile ai-cpu up -d"
fi
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx open-webui; then
  get_code "Open WebUI   ai.${LAB_DOMAIN}" "ai.${LAB_DOMAIN}" "/"
else
  skip "Open WebUI checks" "not enabled -- start with: docker compose --profile ai-cpu up -d"
fi

# Send a real SNTP client query and assert a server-mode reply with a sane stratum. Our
# chrony serves the host clock as `local stratum 10`, so it answers even with no upstream.
section "NTP (chrony @ ${HOST_IP}:123)"
if have python3; then
  if ntp_out="$(python3 - "$HOST_IP" 2>/dev/null <<'PY'
import socket, struct, sys, time
host = sys.argv[1]
pkt = b'\x23' + 47 * b'\x00'              # LI=0 VN=4 Mode=3 (client)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(5)
try:
    s.sendto(pkt, (host, 123)); data, _ = s.recvfrom(48)
except Exception as e:
    print("ERR", e); sys.exit(1)
if len(data) < 48:
    print("SHORT"); sys.exit(1)
mode = data[0] & 7; stratum = data[1]
txsec = struct.unpack('!I', data[40:44])[0] - 2208988800   # NTP epoch -> Unix
print(f"mode={mode} stratum={stratum} skew={abs(txsec - int(time.time()))}s")
sys.exit(0 if mode == 4 and 1 <= stratum <= 15 else 2)
PY
)"; then
    pass "NTP server answers a client query ($ntp_out)"
  else
    fail "NTP" "no valid NTP reply from ${HOST_IP}:123 (${ntp_out:-no output})"
  fi
else
  skip "NTP check" "python3 not installed"
fi

# Every tile icon must serve from Homepage itself (/icons/*), not a CDN, or the dashboard is
# blank on an air-gapped LAN. Assert each checked-in icon serves as 200 image/*.
section "Homepage local icons (served by Homepage, not a CDN)"
icondir="$SCRIPT_DIR/config/homepage/icons"
if [[ -d "$icondir" ]] && compgen -G "$icondir/*" >/dev/null; then
  n_ok=0; n_bad=0
  for f in "$icondir"/*; do
    base="$(basename "$f")"
    ct="$(labcurl "home.${LAB_DOMAIN}" -o /dev/null -w '%{http_code} %{content_type}' \
            "https://home.${LAB_DOMAIN}/icons/${base}" 2>/dev/null)"
    if [[ "$ct" == 200\ image/* ]]; then n_ok=$((n_ok+1)); else n_bad=$((n_bad+1)); echo "        miss: $base -> ${ct:-no response}"; fi
  done
  if [[ $n_bad -eq 0 ]]; then
    pass "all $n_ok dashboard icons served locally (HTTP 200, image/*)"
  else
    fail "local icons" "$n_bad/$((n_ok+n_bad)) icons not served as image/* by Homepage"
  fi
else
  skip "local icons" "config/homepage/icons is empty or missing"
fi

# Homepage orders a group by ascending weight, so the control ("create") tile must have a
# lower weight than the sessions or it sinks below them. This static check asserts the
# control-tile weight (compose/<x>-control.yaml) is less than the session weight
# (config/session-control/<x>.json -> homepage_weight). Needs no live stack.
section "Homepage create-tile pinned above sessions"
# hweight_yaml <file> -- first homepage.weight value in a compose file.
hweight_yaml() { sed -nE 's/^[[:space:]]*homepage\.weight:[[:space:]]*"?([0-9]+)"?.*/\1/p' "$1" | head -1; }
# hweight_json <file> -- first homepage_weight value in a session-control config.
hweight_json() { sed -nE 's/.*"homepage_weight"[[:space:]]*:[[:space:]]*"?([0-9]+)"?.*/\1/p' "$1" | head -1; }
# check_pin <label> <control-yaml> <session-json> -- pass if the control weight sorts above
# (numerically below) the session weight.
check_pin() {
  local label="$1" cw sw
  cw="$(hweight_yaml "$SCRIPT_DIR/$2")"; sw="$(hweight_json "$SCRIPT_DIR/$3")"
  if [[ -z "$cw" || -z "$sw" ]]; then
    fail "${label}: tile weights" "could not read weights (control='${cw:-?}' from $2, session='${sw:-?}' from $3)"
  elif (( cw < sw )); then
    pass "${label}: create tile pinned above sessions (control weight $cw < session weight $sw)"
  else
    fail "${label}: create tile ordering" "control weight $cw must be < session weight $sw, else the create button sinks below sessions"
  fi
}
check_pin "terminals"  "compose/term-control.yaml" "config/session-control/terminal.json"
check_pin "workspaces" "compose/code-control.yaml" "config/session-control/code.json"

section "DHCP (dnsmasq -- opt-in)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx dhcp; then
  pass "DHCP container running (enabled via --profile dhcp)"
else
  skip "DHCP checks" "not enabled -- start with: docker compose --profile dhcp up -d"
fi

# Both control planes (code.lab, terminal.lab) run the same session-control app, so one
# parameterized check covers both: control UI up, profiles API, name sanitization, and a
# full create -> reach-through-Caddy -> delete lifecycle.
# check_session_kind <label> <prefix> <subdomain-base> <profile> <session-health-path>
check_session_kind() {
  local label="$1" prefix="$2" base="$3" prof="$4" hpath="$5"
  local cc="${base}.${LAB_DOMAIN}"
  get_code "${label}: control UI ${cc}" "$cc" "/"
  if labcurl "$cc" "https://${cc}/api/profiles" 2>/dev/null | grep -q "\"${prof}\""; then
    pass "${label}: profiles API lists '${prof}'"
  else
    fail "${label}: profiles API" "${cc}/api/profiles did not list '${prof}'"
  fi
  # Input sanitization: a bad session name must be rejected, not executed.
  local badcode
  badcode="$(labcurl "$cc" -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data '{"name":"BAD name; rm -rf /","profile":"base"}' \
    "https://${cc}/api/sessions" 2>/dev/null)"
  if [[ "$badcode" == 400 ]]; then
    pass "${label}: rejects an invalid session name (HTTP 400)"
  else
    fail "${label}: name sanitization" "expected 400 for a bad name, got $badcode"
  fi
  # Full lifecycle: create a throwaway session, reach it through Caddy, tear it down.
  local sn="smoke-${STAMP}" shost="smoke-${STAMP}.${base}.${LAB_DOMAIN}" crcode scode dcode
  crcode="$(labcurl "$cc" -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data "{\"name\":\"${sn}\",\"profile\":\"${prof}\"}" \
    "https://${cc}/api/sessions" 2>/dev/null)"
  if [[ "$crcode" == 200 ]]; then
    pass "${label}: created ${sn} (HTTP $crcode)"
    scode=000
    for _ in $(seq 1 20); do            # the session needs a moment to bind
      scode="$(labcurl "$shost" -o /dev/null -w '%{http_code}' "https://${shost}${hpath}" 2>/dev/null || echo 000)"
      [[ "$scode" == 200 ]] && break
      sleep 1
    done
    if [[ "$scode" == 200 ]]; then
      pass "${label}: session reachable through Caddy (${shost}${hpath} 200)"
    else
      fail "${label}: session reachability" "${shost}${hpath} never returned 200 (last: $scode)"
    fi
    dcode="$(labcurl "$cc" -o /dev/null -w '%{http_code}' -X DELETE "https://${cc}/api/sessions/${sn}" 2>/dev/null)"
    if [[ "$dcode" == 200 ]]; then
      pass "${label}: deleted ${sn} (HTTP $dcode)"
    else
      fail "${label}: session delete" "expected 200, got $dcode"
    fi
    if have docker; then
      if [[ -z "$(docker ps -aq -f "name=^${prefix}-${sn}$" 2>/dev/null)" ]]; then
        pass "${label}: session container removed"
      else
        fail "${label}: session cleanup" "${prefix}-${sn} still present"
      fi
    fi
  else
    labcurl "$cc" -o /dev/null -X DELETE "https://${cc}/api/sessions/${sn}" 2>/dev/null || true
    skip "${label}: session lifecycle" "create returned $crcode (is ${prefix}-control up and the profile image built?)"
  fi
}

section "Code workspaces (code.${LAB_DOMAIN})"
check_session_kind "code" "code" "code" "base" "/healthz"

section "Terminals (terminal.${LAB_DOMAIN})"
check_session_kind "terminal" "term" "terminal" "base" "/"

printf '\n\033[1m── summary ──\033[0m\n'
printf '  \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m, \033[1;33m%d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -eq 0 ]]; then
  printf '\n\033[1;32mAll checks passed.\033[0m\n'; exit 0
else
  printf '\n\033[1;31m%d check(s) failed.\033[0m\n' "$FAIL"; exit 1
fi
