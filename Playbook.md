# SmallLab — operations playbook

Day-two procedures for SmallLab. Each play states what it does and when you'd reach for it,
then the exact steps. For what the stack is, the service list, and first install, see
[`README.md`](README.md).

Conventions: commands run from the repo root (`/opt/lab`) on the **docker host** unless a play
says otherwise; the backup plays run on the **backup server**. `192.168.1.171` stands in for
`HOST_IP`.

## Plays

- [Onboard a client](#onboard-a-client)
- [Add a service](#add-a-service)
- [Remove a service](#remove-a-service)
- [Add or rebuild a session profile](#add-or-rebuild-a-session-profile)
- [Use a code workspace or terminal](#use-a-code-workspace-or-terminal)
- [Use the package registry (Forgejo)](#use-the-package-registry-forgejo)
- [Forgejo Actions (runner & workflows)](#forgejo-actions-runner--workflows)
- [Use object storage (MinIO)](#use-object-storage-minio)
- [Use the file share](#use-the-file-share)
- [Issue a cert from the CA](#issue-a-cert-from-the-ca)
- [Add DNS records](#add-dns-records)
- [Run a backup](#run-a-backup)
- [Restore a snapshot](#restore-a-snapshot)
- [Preserve the root CA across a rebuild](#preserve-the-root-ca-across-a-rebuild)
- [Enable or disable DHCP](#enable-or-disable-dhcp)
- [Index code in OpenGrok](#index-code-in-opengrok)
- [Rebuild images](#rebuild-images)
- [Smoke-test and health](#smoke-test-and-health)
- [Update images and everyday compose](#update-images-and-everyday-compose)
- [Rename the TLD](#rename-the-tld)

---

## Onboard a client

**Description.** Make one machine trust the lab root CA and resolve `*.lab`.
**When to use.** Any new client that will browse or consume lab services (unless DHCP already
configures it — see [Enable or disable DHCP](#enable-or-disable-dhcp)).

Trust the root CA (copy `lab-root-ca.crt` from the host first):

```bash
# Linux
sudo cp lab-root-ca.crt /usr/local/share/ca-certificates/lab-ca.crt && sudo update-ca-certificates
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain lab-root-ca.crt
# Windows (elevated)
certutil -addstore -f Root lab-root-ca.crt
```

Firefox keeps its own store — import it there too. Docker needs the CA to push to the registry
(see [Use the package registry](#use-the-package-registry-forgejo)).

Resolve `*.lab` — point the whole resolver at the host, or send only `*.lab` to it (split DNS):

```bash
# Linux + systemd-resolved (per-interface; ~lab routes only *.lab to the lab)
IFACE=$(ip route get 192.168.1.171 | grep -oP 'dev \K\S+')
resolvectl dns "$IFACE" 192.168.1.171 && resolvectl domain "$IFACE" '~lab'   # runtime
# persist via NetworkManager:
nmcli con mod "<con>" +ipv4.dns 192.168.1.171 +ipv4.dns-search '~lab' && nmcli con up "<con>"

# Linux without systemd-resolved (local dnsmasq stub)
sudo apt install -y dnsmasq
echo 'server=/lab/192.168.1.171' | sudo tee /etc/dnsmasq.d/lab.conf && sudo systemctl restart dnsmasq

# macOS (per-domain resolver; verify with ping/curl, not dig — dig bypasses /etc/resolver)
echo "nameserver 192.168.1.171" | sudo tee /etc/resolver/lab

# Windows + NRPT (elevated PowerShell; leading dot matches all *.lab)
Add-DnsClientNrptRule -Namespace ".lab" -NameServers "192.168.1.171"
```

A second `nameserver` line in `resolv.conf` does **not** do split DNS (multiple nameservers are
failover across all lookups). Optionally point the client's time at the lab too:

```bash
echo "server 192.168.1.171 iburst" | sudo tee /etc/chrony/conf.d/lab.conf && sudo systemctl restart chrony
```

---

## Add a service

**Description.** Add a new container that Caddy fronts and the dashboard shows.
**When to use.** Bringing any new app into the stack.

1. Create `compose/<name>.yaml`:

   ```yaml
   # <name> -- <one-line description> (<name>.lab).
   services:
     <name>:
       image: <repo>@sha256:<digest>   # <readable tag>
       container_name: <name>
       restart: unless-stopped
       volumes:
         - ../volumes/<name>:/data     # only if it has state
       networks:
         - caddy
       labels:
         caddy: <name>.${LAB_DOMAIN}
         caddy.reverse_proxy: "{{upstreams <container-port>}}"
         homepage.group: Tools        # Infrastructure | Storage & Packages | Tools | Reference
         homepage.name: <Display Name>
         homepage.icon: /icons/<name>.png
         homepage.href: https://<name>.${LAB_DOMAIN}
         homepage.description: <short description>
         homepage.weight: "50"
   ```

   - **Not a web app** (raw host ports, like Samba): drop the `caddy` labels, use the `backend`
     network, and add `ports: ["${HOST_IP}:<p>:<p>"]`.
   - **Two sites on one container:** use ordinal label groups `caddy_0` / `caddy_1` (see
     `compose/minio.yaml`).
   - **Building your own image** (not a prebuilt): put the build context in `images/<name>/`
     (Dockerfile + any build-time conf), set `image: lab/<name>:latest`, and run `./build.sh <name>`
     — skip the digest-pin step below (it applies only to prebuilt images).

2. Add the file to `include:` in [`compose.yaml`](compose.yaml).
3. If it has state, create its bind-mount dir: `mkdir -p volumes/<name>` (chown to the image's
   uid if it runs non-root).
4. Pin the digest: `docker pull <repo>:<tag>` then
   `docker image inspect <repo>:<tag> --format '{{index .RepoDigests 0}}'`.
5. Apply and verify:

   ```bash
   docker compose up -d                 # creates the new container; leaves others alone
   curl --resolve <name>.lab:443:$HOST_IP --cacert lab-root-ca.crt https://<name>.lab/
   ```

No DNS or Caddy edit is needed — the `*.lab` wildcard already resolves and Caddy reads the
labels. The cert is issued on first request (~30s); the dashboard tile appears automatically.

---

## Remove a service

**Description.** Drop a service and its tile.
**When to use.** Retiring an app.

```bash
# 1. delete its line from compose.yaml's include: and remove compose/<name>.yaml
# 2. drop the container (and any orphaned ones)
docker compose up -d --remove-orphans      # or target it: docker compose rm -sf <name>
# 3. optional: reclaim its data and config
sudo rm -rf volumes/<name> config/<name>
```

Caddy drops the site and the tile disappears on its own.

---

## Add or rebuild a session profile

**Description.** Add or refresh a baked image for a code-workspace or terminal profile.
**When to use.** Adding a language/toolchain to the session menu, or updating an existing one.
`<kind>` is `code` (FROM code-server) or `term` (FROM ttyd).

```bash
# 1. add or edit the Dockerfile (FROM the kind's pinned base image; install tools/extensions)
$EDITOR images/<kind>-<name>/Dockerfile
# 2. register it (clients pick a profile by NAME only)
$EDITOR config/session-control/<code|terminal>.json   # "<name>": {"image":"lab/<kind>-<name>:latest", ...}
# 3. (re)build -- needs internet (apt / toolchain / Open VSX extensions)
./build.sh <kind>-<name>                    # rebuild just this image; omit args to build everything
# 4. pick up the config change without rebuilding the control plane
docker compose restart code-control        # or term-control
```

Running sessions keep their original image; new sessions use the rebuilt one. Code extensions
install from **Open VSX** (Microsoft's first-party extensions aren't there — use Open-VSX ids or
build from source, as the `zig` profile does for ZLS).

---

## Use a code workspace or terminal

**Description.** Create, reach, and tear down on-demand code-server or ttyd sessions.
**When to use.** You want a throwaway dev environment or a shared browser terminal.

From [`https://code.lab`](https://code.lab) or [`https://terminal.lab`](https://terminal.lab):
**Create** (name `[a-z0-9-]`, ≤31 chars + profile) → a container spins up at
`https://<name>.<kind>.lab`; **Open/Resume** a running or stopped session (files persist);
**Stop** keeps data; **Delete** removes the container and wipes its data. Terminals run
`tmux new -A -s main`, so a reconnect or second tab reattaches the same session.

Scriptable over the same API (swap `code` → `terminal`):

```bash
C="https://code.lab"; R="--resolve code.lab:443:$HOST_IP --cacert lab-root-ca.crt"
curl -sS $R "$C/api/profiles"
curl -sS $R -X POST "$C/api/sessions" -H 'content-type: application/json' -d '{"name":"poc","profile":"zig"}'
curl -sS $R "$C/api/sessions"
curl -sS $R -X POST   "$C/api/sessions/poc/stop"
curl -sS $R -X DELETE "$C/api/sessions/poc"
```

One dir per session is bind-mounted and lands in backups: `volumes/code/<name>/project` for
workspaces, `volumes/term/<name>/root` for terminals.

---

## Use the package registry (Forgejo)

**Description.** Push and pull container images and language packages through `packages.lab`.
**When to use.** Publishing or installing artifacts in-lab. `bootstrap.sh` creates the admin
user and a **public** org (named after `LAB_DOMAIN`), so anonymous pull/download works; uploads
authenticate. Packages are created on first push.

Docker (trust the CA first; push needs auth, public pull is anonymous):

```bash
sudo mkdir -p /etc/docker/certs.d/packages.lab
sudo cp lab-root-ca.crt /etc/docker/certs.d/packages.lab/ca.crt
docker login packages.lab                              # admin creds or a token
docker tag alpine packages.lab/lab/alpine:latest       # packages.lab/<org>/<image>
docker push packages.lab/lab/alpine:latest
docker pull packages.lab/lab/alpine:latest             # public org -> no login
```

PyPI (note the `/api/packages/<org>/pypi` base):

```bash
twine upload --repository-url https://packages.lab/api/packages/lab/pypi -u labadmin dist/*
pip install --index-url https://packages.lab/api/packages/lab/pypi/simple <pkg>   # anonymous
```

Other formats (npm, Maven, Cargo, …) hang off `https://packages.lab/api/packages/<org>/` — see
the [Forgejo packages docs](https://forgejo.org/docs/latest/user/packages/). Change the admin
password in the UI afterward and mirror it in `.env`.

---

## Forgejo Actions (runner & workflows)

**Description.** Run CI workflows on the registered Actions runner; inspect or re-register it.
**When to use.** Setting up CI, debugging a runner that isn't picking up jobs, or rotating its
identity.

A minimal workflow (`.forgejo/workflows/ci.yml` in a repo):

```yaml
on: [push]
jobs:
  build:
    runs-on: docker          # the `docker` label -> runs in node:22-bookworm
    steps:
      - run: echo "built on $(uname -a)"
```

Air-gap rules: `runs-on:` images must be pre-pulled on the host (the runner is `force_pull:
false`); `uses:` actions resolve from this forge, so mirror the action repos into an org or use
plain `run:` git steps. Labels/capacity live in `config/forgejo-runner/config.yaml`; edit then
`docker compose restart forgejo-runner`.

Inspect or re-register:

```bash
docker compose logs --tail=20 forgejo-runner   # "waiting for registration" = not bootstrapped
./bootstrap.sh                                 # idempotent: registers if needed
# runners in the UI: https://packages.lab/-/admin/actions/runners

# force a clean re-register (the secret/.runner live in the data volume, owned by uid 1000):
docker compose exec -T forgejo-runner sh -c 'rm -f /data/secret /data/.runner'
docker compose restart forgejo-runner && ./bootstrap.sh
```

For stronger isolation, point the runner at a `docker:dind` sidecar instead of the host socket
(`DOCKER_HOST=tcp://docker-in-docker:2375`, drop the socket mount).

---

## Use object storage (MinIO)

**Description.** S3-compatible buckets via the console or any S3 client.
**When to use.** Storing artifacts/objects in-lab.

```bash
mc alias set lab https://s3.lab "$LAB_USER" "$LAB_PASSWORD"
mc mb lab/artifacts
aws --endpoint-url https://s3.lab s3 cp ./file s3://artifacts/   # any S3 SDK works
```

Console: `https://s3-console.lab` (login = `LAB_USER` / `LAB_PASSWORD`). The image is pinned to
the last release with a full console; swap to `minio/minio` in `compose/minio.yaml` for API-only.

---

## Use the file share

**Description.** Read/write one shared tree over SMB, the web, or curl — all the same files.
**When to use.** Moving files around the LAN with no auth.

```bash
# SMB (passwordless guest)
sudo mount -t cifs //files.lab/lab /mnt/lab -o guest,vers=3.0     # Linux
net use Z: \\files.lab\lab                                       # Windows (see caveat)

# curl / WebDAV (dav.lab)
curl -T ./report.pdf https://dav.lab/reports/2026/report.pdf      # PUT (parents auto-created)
curl -O https://dav.lab/reports/2026/report.pdf                   # GET
curl    https://dav.lab/reports/2026/                             # directory listing
curl -X DELETE https://dav.lab/reports/2026/report.pdf            # DELETE
curl -X MKCOL  https://dav.lab/reports/2027/                      # make a directory
```

`files.lab` is the FileBrowser web UI (no login). WebDAV covers PUT/DELETE/MKCOL/COPY/MOVE;
`POST` is unsupported. **Windows guest caveat:** Windows 10/11 block guest SMB by default — allow
it with `reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v
AllowInsecureGuestAuth /t REG_DWORD /d 1 /f`.

Full-text search across everything in this tree is at [`find.lab`](https://find.lab) (sist2 —
content, OCR, thumbnails, type/size/date facets), re-indexed hourly. It's read-only and needs no
setup; restart the container to index immediately: `docker compose restart sist2`.

---

## Issue a cert from the CA

**Description.** Get a `.lab` cert for a host/device that isn't behind Caddy.
**When to use.** A standalone web server, printer, or appliance needs a cert trusted by
everything that already trusts `lab-root-ca.crt`. (Caddy-proxied `*.lab` sites are automatic.)

**ACME (preferred; auto-renews).** step-ca is a normal ACME CA; point any client at
`https://ca.lab:9000/acme/acme/directory` (the client must trust the root and resolve `*.lab`):

```bash
export CA_BUNDLE=/usr/local/share/ca-certificates/lab-ca.crt
acme.sh --server https://ca.lab:9000/acme/acme/directory \
        --issue -d myapp.lab --standalone --ca-bundle "$CA_BUNDLE"
```

**One-off, signed by hand** (device that can't run ACME):

```bash
docker compose exec step-ca sh -c '
  cd /tmp
  step certificate create "myapp.lab" myapp.crt myapp.key \
    --ca /home/step/certs/intermediate_ca.crt \
    --ca-key /home/step/secrets/intermediate_ca_key \
    --ca-password-file /home/step/secrets/password \
    --san myapp.lab --san 192.168.1.50 \
    --not-after 2160h --bundle --no-password --insecure
'
docker compose cp step-ca:/tmp/myapp.crt ./myapp.crt
docker compose cp step-ca:/tmp/myapp.key ./myapp.key
docker compose exec step-ca rm -f /tmp/myapp.crt /tmp/myapp.key
```

Verify: `step certificate verify myapp.crt --roots lab-root-ca.crt`.

---

## Add DNS records

**Description.** Add records to the authoritative `lab` zone.
**When to use.** A real host, device, alias, or non-A record type — anything the `*.lab`
wildcard shouldn't cover (the wildcard already answers any name with no explicit record, so a
new Caddy-fronted service needs no entry).

Web UI: `https://dns.lab` → log in (`LAB_USER` / `LAB_PASSWORD`; Technitium's username is
`admin`) → **Zones → `lab` → Add Record**. A more specific record (e.g. `nas` → `192.168.1.50`)
wins over the wildcard. TTLs are 300s. Scripted (what `bootstrap.sh` does, via the loopback API):

```bash
TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=$PASS" | jq -r .token)
curl -s "http://127.0.0.1:5380/api/zones/records/add?token=$TOKEN&zone=lab&domain=nas.lab&type=A&ipAddress=192.168.1.50&ttl=300"
```

---

## Run a backup

**Description.** Take an rsync hard-link snapshot of the host's `volumes/` now, off-schedule.
**When to use.** Before a risky change, or to verify the backup path. (The timer already runs it
every 3 hours.) Run on the **backup server**.

```bash
sudo /opt/lab-backup/lab-backup.sh                       # hot copy, uses /etc/lab-backup/config.env
sudo PAUSE_CONTAINERS=1 /opt/lab-backup/lab-backup.sh    # guaranteed-consistent DB copy (brief freeze)
/opt/lab-backup/lab-restore.sh list                      # what's available
```

---

## Restore a snapshot

**Description.** Put a snapshot back into a host's `volumes/`, then start the stack.
**When to use.** Disaster recovery, or seeding a brand-new host. Run on the **backup server**.

```bash
/opt/lab-backup/lab-restore.sh list                       # pick a snapshot (or 'latest')

# A) back onto the SAME host (stop the stack first):
ssh root@dockerhost.lab 'cd /opt/lab && docker compose down'
sudo /opt/lab-backup/lab-restore.sh restore latest --to root@dockerhost.lab:/opt/lab/volumes
ssh root@dockerhost.lab 'cd /opt/lab && docker compose up -d && ./bootstrap.sh'

# B) onto a BRAND-NEW host, before its first up (do the install up to the volumes step first):
sudo /opt/lab-backup/lab-restore.sh restore latest --to root@newhost:/opt/lab/volumes

# C) locally, on the machine holding the volumes:
sudo /opt/lab-backup/lab-restore.sh restore 20260619T030000 --target /opt/lab/volumes
```

`--force` skips the overwrite prompt. The tree comes back with the same paths/perms/UIDs, so the
stack mounts it straight back. `.env` and `lab-root-ca.crt` are not in the backup — restore those
from your password manager. Run `./test.sh` afterward.

---

## Preserve the root CA across a rebuild

**Description.** Wipe and rebuild the whole stack from scratch while keeping the SAME trusted
root, so clients never have to re-trust a new CA. The entire CA lives in `volumes/stepca/` (root +
intermediate certs, their keys, and the key password) — the exported `lab-root-ca.crt` is only the
public cert and is NOT enough on its own.
**When to use.** Resetting all state on a host, or moving the CA to a brand-new host.

```bash
# 1. save the CA (private keys + password are inside -- treat it like a secret)
sudo tar czf lab-ca-backup.tgz -C volumes stepca

# 2. bring the stack up fresh, restoring ONLY the CA before first boot
docker compose down --remove-orphans
rm -rf volumes/*                                   # wipe all state
mkdir -p volumes/{caddy/data,caddy/config,stepca,...}   # recreate the skeleton (README -> Install)
sudo tar xzf lab-ca-backup.tgz -C volumes          # drop the saved CA back in
sudo chown -R 1000:1000 volumes/stepca             # step-ca runs as uid 1000

docker compose up -d && ./bootstrap.sh
```

step-ca only auto-inits when its volume is empty, so with `volumes/stepca/` already populated it
boots the identical root + intermediate — no re-init. Caddy re-enrolls fresh leaf certs from the
same CA over ACME, and every client that already trusts `lab-root-ca.crt` stays valid. This is just
a [Restore a snapshot](#restore-a-snapshot) limited to `volumes/stepca/`; to carry the CA to a new
host, copy `lab-ca-backup.tgz` over and untar it before the first `up`.

---

## Enable or disable DHCP

**Description.** Make the host the LAN's DHCP authority (hands out lab DNS + NTP + domain).
**When to use.** You want machines configured by just joining the LAN, and **this host is the
sole DHCP server on the segment** — never run a second DHCP server. If a router already does
DHCP, leave this off and set the router's DNS (option 6) and NTP (option 42) to `HOST_IP`
instead.

```bash
# 1. set the DHCP_* block in .env (LAN NIC, address range, gateway, lease)
ip -br link                              # find the LAN NIC
# 2. start it alongside the running stack
docker compose --profile dhcp up -d
docker compose logs -f dhcp              # watch for "DHCP, IP range ..."
# off again:
docker compose --profile dhcp down dhcp
```

dnsmasq runs DNS-disabled (`--port=0`), bound to the one NIC, so it never competes with
Technitium. Clients still need to trust the root CA (DHCP can't push it) —
[Onboard a client](#onboard-a-client).

---

## Index code in OpenGrok

**Description.** Stage source trees for cross-reference + full-text search at `grok.lab`.
**When to use.** You want to read or grep a codebase in-lab. Fully offline.

```bash
./ingest-repos.sh ~/incoming/*.tar.gz      # extracts archives, or copies a directory in
docker compose restart opengrok            # index now instead of waiting for the timer
```

One project per top-level dir under `volumes/opengrok/src`; reindexed on startup and every
`SYNC_PERIOD_MINUTES`. If a later ingest can't write the dir (OpenGrok chowns it to uid 1111 on
boot), take it back first: `sudo chown -R "$USER" volumes/opengrok/src`.

---

## Rebuild images

**Description.** Rebuild the locally-built images (each is a self-contained `lab/<name>:latest`
from `images/<name>/Dockerfile`). Needs internet + docker (the build clones/downloads content).

```bash
./build.sh                      # build every images/*, pull prebuilts, write dist/*.tar.gz
./build.sh payloads jsoncrack   # rebuild specific images only (skips pull + bundle)
docker compose up -d            # pick up the rebuilt images
```

Built on a separate box? `./build.sh` writes `dist/lab-images.tar.gz` (custom) and
`dist/prebuilt-images.tar.gz`; carry them over, `for f in dist/*.tar.gz; do docker load -i "$f"; done`,
then `docker compose up -d`.

---

## Smoke-test and health

**Description.** Verify every service end-to-end (DNS, TLS chain, HTTP, step-ca, WebDAV, SMB,
MinIO, Forgejo packages, sessions).
**When to use.** After install, a restore, or an image bump.

```bash
docker compose ps                 # all Up; Forgejo migrates for a few seconds on first boot
./test.sh                         # exits non-zero if any check fails (skips don't fail it)
docker compose logs -f <service>  # follow one service
```

`test.sh` reaches services with `curl --resolve` / `--add-host` / SMB-by-IP, so it passes from
the host even when the host's own resolver isn't pointed at Technitium.

---

## Update images and everyday compose

**Description.** The common lifecycle commands.
**When to use.** Routine maintenance.

```bash
docker compose pull && docker compose up -d    # update images
docker compose restart caddy                   # re-issue / reload after a TLS change
docker compose restart webdav                  # apply a config/nginx/nginx.conf edit
docker compose down                            # stop everything (volumes/ data is kept)
docker compose cp step-ca:/home/step/certs/root_ca.crt ./lab-root-ca.crt   # re-export the CA
```

---

## Rename the TLD

**Description.** Change the lab's TLD from `lab` to something else.
**When to use.** Rarely — the default `lab` is fine for most setups.

```bash
$EDITOR .env                                   # change LAB_DOMAIN
docker compose up -d --force-recreate && ./bootstrap.sh
```

`LAB_DOMAIN` is interpolated into every `caddy:` and `homepage.*` label and read by
`bootstrap.sh`; nothing else hardcodes the TLD.
