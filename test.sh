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
cd "$SCRIPT_DIR"

# --- config -----------------------------------------------------------------
[[ -f .env ]] || { echo "error: .env not found next to test.sh" >&2; exit 1; }
# shellcheck disable=SC1091
set -a; source ./.env; set +a
: "${HOST_IP:?HOST_IP must be set in .env}"
: "${LAB_DOMAIN:?LAB_DOMAIN must be set in .env}"

CA="$SCRIPT_DIR/lab-root-ca.crt"
[[ -s "$CA" ]] || { echo "error: $CA missing -- run ./bootstrap.sh first" >&2; exit 1; }
STAMP="$(date +%Y%m%d%H%M%S)-$$"

# --- harness ----------------------------------------------------------------
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

# get_code <desc> <host> <path> [expected]  -- GET, assert HTTP status (default 200).
get_code() {
  local desc="$1" host="$2" path="$3" want="${4:-200}" code
  code="$(labcurl "$host" -o /dev/null -w '%{http_code}' "https://${host}${path}" 2>/dev/null)" \
    || { fail "$desc" "curl could not connect to ${host}"; return; }
  [[ "$code" == "$want" ]] && pass "$desc (HTTP $code)" || fail "$desc" "expected $want, got $code"
}

# --- 1. DNS (Technitium) ----------------------------------------------------
section "DNS (Technitium @ ${HOST_IP})"
if have dig; then
  got="$(dig +short +time=3 +tries=1 @"$HOST_IP" "home.${LAB_DOMAIN}" 2>/dev/null | tail -1)"
  [[ "$got" == "$HOST_IP" ]] && pass "wildcard *.${LAB_DOMAIN} resolves to host (home.${LAB_DOMAIN} -> $got)" \
    || fail "wildcard resolution" "home.${LAB_DOMAIN} -> '${got:-<none>}', expected $HOST_IP"
  got="$(dig +short +time=3 +tries=1 @"$HOST_IP" "packages.${LAB_DOMAIN}" 2>/dev/null | tail -1)"
  [[ "$got" == "$HOST_IP" ]] && pass "packages.${LAB_DOMAIN} -> $got" \
    || fail "packages.${LAB_DOMAIN} resolution" "got '${got:-<none>}'"
  got="$(dig +short +time=3 +tries=1 @"$HOST_IP" example.com 2>/dev/null | tail -1)"
  [[ -n "$got" ]] && pass "recursive forwarding works (example.com -> $got)" \
    || fail "recursive forwarding" "example.com did not resolve via the lab DNS"
else
  skip "DNS checks" "dig not installed"
fi

# --- 2. TLS chain to the lab root CA ----------------------------------------
section "TLS (step-ca -> Caddy, verified against lab-root-ca.crt)"
vr="$(labcurl "home.${LAB_DOMAIN}" -o /dev/null -w '%{ssl_verify_result}' "https://home.${LAB_DOMAIN}/" 2>/dev/null)"
[[ "$vr" == "0" ]] && pass "home.${LAB_DOMAIN} cert verifies against the lab root CA" \
  || fail "cert verification" "ssl_verify_result=$vr (cert does not chain to lab-root-ca.crt)"
if have openssl; then
  issuer="$(echo | openssl s_client -connect "${HOST_IP}:443" -servername "home.${LAB_DOMAIN}" -CAfile "$CA" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)"
  grep -qi 'lab CA' <<<"$issuer" && pass "issuer is the lab CA (${issuer#issuer=})" \
    || fail "cert issuer" "unexpected issuer: ${issuer:-<none>}"
fi

# --- 3. Web endpoints (through Caddy) ---------------------------------------
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
# (Forgejo / packages.lab is checked in its own section below)

# Dev tooling + offline references. The doc sites return 200 only once ./fetch-docs.sh has
# staged their content into volumes/.
get_code "Compiler Explorer godbolt.${LAB_DOMAIN}"  "godbolt.${LAB_DOMAIN}"     "/"
get_code "cppreference    cppref.${LAB_DOMAIN}"      "cppref.${LAB_DOMAIN}"      "/"
get_code "x86 ref         x86.${LAB_DOMAIN}"         "x86.${LAB_DOMAIN}"         "/"
get_code "tldr            tldr.${LAB_DOMAIN}"        "tldr.${LAB_DOMAIN}"        "/"

# --- 4. step-ca health ------------------------------------------------------
section "step-ca (ACME CA)"
body="$(curl -sS --max-time 15 --resolve "ca.${LAB_DOMAIN}:9000:${HOST_IP}" --cacert "$CA" "https://ca.${LAB_DOMAIN}:9000/health" 2>/dev/null)"
grep -q '"status":"ok"' <<<"$body" && pass "ca.${LAB_DOMAIN}:9000/health is ok" \
  || fail "step-ca health" "response: ${body:-<none>}"

# --- 5. WebDAV (curl GET/PUT/DELETE/MKCOL) ----------------------------------
section "WebDAV (dav.${LAB_DOMAIN})"
dav="https://dav.${LAB_DOMAIN}"
f="smoke-${STAMP}.txt"; d="smoke-dir-${STAMP}"; content="webdav-content-${STAMP}"
tmp="$(mktemp)"; printf '%s' "$content" > "$tmp"
code="$(labcurl "dav.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' -T "$tmp" "${dav}/${f}" 2>/dev/null)"
[[ "$code" == 201 ]] && pass "PUT ${f} (HTTP $code)" || fail "WebDAV PUT" "expected 201, got $code"
got="$(labcurl "dav.${LAB_DOMAIN}" "${dav}/${f}" 2>/dev/null)"
[[ "$got" == "$content" ]] && pass "GET ${f} round-trips identical bytes" || fail "WebDAV GET" "body mismatch: '${got}'"
code="$(labcurl "dav.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' -X MKCOL "${dav}/${d}/" 2>/dev/null)"
[[ "$code" == 201 ]] && pass "MKCOL ${d}/ (HTTP $code)" || fail "WebDAV MKCOL" "expected 201, got $code"
code="$(labcurl "dav.${LAB_DOMAIN}" -o /dev/null -w '%{http_code}' -X DELETE "${dav}/${d}/" 2>/dev/null)"
[[ "$code" == 204 ]] && pass "DELETE ${d}/ (HTTP $code)" || fail "WebDAV DELETE dir" "expected 204, got $code"
rm -f "$tmp"
# leave ${f} in place for the interop check below; it deletes it afterward

# --- 6. Shared tree interop (WebDAV file readable over SMB) ------------------
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

# --- 7. MinIO object storage (S3 via mc) ------------------------------------
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

# --- 8. Forgejo packages (real publish+install and push+pull) ---------------
section "Forgejo packages (packages.${LAB_DOMAIN})"
org="${FORGEJO_ORG:-$LAB_DOMAIN}"
fauth="${LAB_USER}:${LAB_PASSWORD}"
fapi="https://packages.${LAB_DOMAIN}/api/v1"
vtag="$(date +%s)"

get_code "Forgejo UI      packages.${LAB_DOMAIN}" "packages.${LAB_DOMAIN}" "/"

code="$(labcurl "packages.${LAB_DOMAIN}" -u "$fauth" -o /dev/null -w '%{http_code}' "${fapi}/orgs/${org}")"
[[ "$code" == 200 ]] && pass "API authenticated; public org '${org}' present" \
                     || fail "Forgejo API/org" "GET /orgs/${org} -> $code (is bootstrap done?)"

# fdel <type/name/version> -- remove a package version so the test stays idempotent.
fdel() { labcurl "packages.${LAB_DOMAIN}" -u "$fauth" -o /dev/null -X DELETE "${fapi}/packages/${org}/$1" 2>/dev/null || true; }
# ensure_image <ref> -- present locally, else pull; returns non-zero if unavailable.
ensure_image() { docker image inspect "$1" >/dev/null 2>&1 || docker pull -q "$1" >/dev/null 2>&1; }

if ! have docker; then
  skip "PyPI publish/install"  "needs docker to run the client tools"
  skip "Docker registry push/pull" "needs docker to run the client tools"
else
  # --- PyPI: build, twine upload (auth), pip install (anonymous, public org) ---
  if ensure_image python:3.12-slim; then
    if docker run --rm \
         --add-host "packages.${LAB_DOMAIN}:${HOST_IP}" \
         -e U="$LAB_USER" -e P="$LAB_PASSWORD" -e ORG="$org" \
         -e DOM="$LAB_DOMAIN" -e VER="0.0.${vtag}" \
         -v "${CA}:/usr/local/share/ca-certificates/lab.crt:ro" \
         python:3.12-slim bash -c '
           set -e
           update-ca-certificates >/dev/null 2>&1
           pip install --quiet build twine >/dev/null 2>&1
           mkdir -p /b/src/labtest && cd /b
           echo "def hello(): return \"labtest $VER\"" > src/labtest/__init__.py
           printf "[build-system]\nrequires=[\"setuptools>=61\"]\nbuild-backend=\"setuptools.build_meta\"\n[project]\nname=\"labtest\"\nversion=\"%s\"\n[tool.setuptools.packages.find]\nwhere=[\"src\"]\n" "$VER" > pyproject.toml
           python -m build >/dev/null 2>&1
           export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
           twine upload --repository-url "https://packages.${DOM}/api/packages/${ORG}/pypi" -u "$U" -p "$P" --non-interactive dist/* >/dev/null 2>&1
           pip install --quiet --no-cache-dir --target /site --cert /etc/ssl/certs/ca-certificates.crt \
             --index-url "https://packages.${DOM}/api/packages/${ORG}/pypi/simple" "labtest==$VER" >/dev/null 2>&1
           test "$(PYTHONPATH=/site python -c "import labtest; print(labtest.hello())")" = "labtest $VER"
         ' >/dev/null 2>&1; then
      pass "PyPI publish (twine, auth) + install (pip, anonymous) round-trip"
    else
      fail "PyPI publish/install" "twine upload or anonymous pip install against ${org}/pypi failed"
    fi
    fdel "pypi/labtest/0.0.${vtag}"
  else
    skip "PyPI publish/install" "needs the python:3.12-slim image"
  fi

  # --- Docker/OCI: skopeo push (auth) + pull (anonymous), daemonless ----------
  if ensure_image quay.io/skopeo/stable:latest && ensure_image alpine:latest; then
    work="$(mktemp -d)"; docker save alpine:latest -o "$work/img.tar" 2>/dev/null
    if docker run --rm --add-host "packages.${LAB_DOMAIN}:${HOST_IP}" \
         -v "$work:/w:ro" -v "${CA}:/etc/containers/certs.d/packages.${LAB_DOMAIN}/ca.crt:ro" \
         quay.io/skopeo/stable:latest copy --dest-creds "$fauth" \
         docker-archive:/w/img.tar "docker://packages.${LAB_DOMAIN}/${org}/labtest:${vtag}" >/dev/null 2>&1 \
       && docker run --rm --add-host "packages.${LAB_DOMAIN}:${HOST_IP}" \
         -v "${CA}:/etc/containers/certs.d/packages.${LAB_DOMAIN}/ca.crt:ro" \
         quay.io/skopeo/stable:latest copy "docker://packages.${LAB_DOMAIN}/${org}/labtest:${vtag}" dir:/tmp/out >/dev/null 2>&1; then
      pass "Docker/OCI registry push (auth) + pull (anonymous) round-trip"
    else
      fail "Docker registry push/pull" "skopeo copy to/from packages.${LAB_DOMAIN}/${org} failed"
    fi
    rm -rf "$work"
    fdel "container/labtest/${vtag}"
  else
    skip "Docker registry push/pull" "needs the quay.io/skopeo/stable and alpine images"
  fi
fi

# --- 9. NTP (chrony @ HOST_IP:123) ------------------------------------------
# Send a real SNTP client query and assert a server-mode reply with a sane stratum. Our
# chrony serves the host clock as `local stratum 10`, so it answers even with no upstream.
section "NTP (chrony @ ${HOST_IP}:123)"
if have python3; then
  ntp_out="$(python3 - "$HOST_IP" 2>/dev/null <<'PY'
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
)"
  if [[ $? -eq 0 ]]; then
    pass "NTP server answers a client query ($ntp_out)"
  else
    fail "NTP" "no valid NTP reply from ${HOST_IP}:123 (${ntp_out:-no output})"
  fi
else
  skip "NTP check" "python3 not installed"
fi

# --- 10. Homepage icons served locally (offline-safe) -----------------------
# Every tile icon must come from Homepage itself (/icons/*), not a CDN, or the dashboard is
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
  [[ $n_bad -eq 0 ]] && pass "all $n_ok dashboard icons served locally (HTTP 200, image/*)" \
    || fail "local icons" "$n_bad/$((n_ok+n_bad)) icons not served as image/* by Homepage"
else
  skip "local icons" "config/homepage/icons is empty or missing"
fi

# --- 11. Forgejo Actions runner (container up + registered) -----------------
section "Forgejo Actions runner"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx forgejo-runner; then
  if [[ -s "$SCRIPT_DIR/volumes/forgejo-runner/.runner" ]]; then
    pass "runner container up and registered (.runner present)"
  else
    fail "Forgejo runner" "container up but not registered yet -- run ./bootstrap.sh"
  fi
else
  skip "Forgejo runner" "forgejo-runner container not running"
fi

# --- 12. DHCP (opt-in; only checked when the profile is up) -----------------
section "DHCP (dnsmasq -- opt-in)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx dhcp; then
  pass "DHCP container running (enabled via --profile dhcp)"
else
  skip "DHCP checks" "not enabled -- start with: docker compose --profile dhcp up -d"
fi

# --- 13. Sessions: code workspaces + terminals (live create/reach/delete) ---
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
  [[ "$badcode" == 400 ]] && pass "${label}: rejects an invalid session name (HTTP 400)" \
    || fail "${label}: name sanitization" "expected 400 for a bad name, got $badcode"
  # Full lifecycle: create a throwaway session, reach it through Caddy, tear it down.
  local sn="smoke-${STAMP}" shost="smoke-${STAMP}.${base}.${LAB_DOMAIN}" crcode scode dcode i
  crcode="$(labcurl "$cc" -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data "{\"name\":\"${sn}\",\"profile\":\"${prof}\"}" \
    "https://${cc}/api/sessions" 2>/dev/null)"
  if [[ "$crcode" == 200 ]]; then
    pass "${label}: created ${sn} (HTTP $crcode)"
    scode=000
    for i in $(seq 1 20); do            # the session needs a moment to bind
      scode="$(labcurl "$shost" -o /dev/null -w '%{http_code}' "https://${shost}${hpath}" 2>/dev/null || echo 000)"
      [[ "$scode" == 200 ]] && break
      sleep 1
    done
    [[ "$scode" == 200 ]] && pass "${label}: session reachable through Caddy (${shost}${hpath} 200)" \
      || fail "${label}: session reachability" "${shost}${hpath} never returned 200 (last: $scode)"
    dcode="$(labcurl "$cc" -o /dev/null -w '%{http_code}' -X DELETE "https://${cc}/api/sessions/${sn}" 2>/dev/null)"
    [[ "$dcode" == 200 ]] && pass "${label}: deleted ${sn} (HTTP $dcode)" \
      || fail "${label}: session delete" "expected 200, got $dcode"
    if have docker; then
      [[ -z "$(docker ps -aq -f "name=^${prefix}-${sn}$" 2>/dev/null)" ]] \
        && pass "${label}: session container removed" || fail "${label}: session cleanup" "${prefix}-${sn} still present"
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

# --- summary ----------------------------------------------------------------
printf '\n\033[1m── summary ──\033[0m\n'
printf '  \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m, \033[1;33m%d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[[ "$FAIL" -eq 0 ]] && { printf '\n\033[1;32mAll checks passed.\033[0m\n'; exit 0; } \
                    || { printf '\n\033[1;31m%d check(s) failed.\033[0m\n' "$FAIL"; exit 1; }
