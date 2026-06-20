# `.lab` stack — operations playbook

Day-two procedures for the `.lab` homelab stack. For what the stack *is* and how
clients consume it, see [`README.md`](README.md); this file is the step-by-step
"how do I…" reference.

Topology: two servers.

| Role | Hostname (example) | Runs |
|------|--------------------|------|
| **Docker host** | `dockerhost.lab` (`192.168.1.171`) | the whole compose stack |
| **Backup server** | `backup.lab` | pulls `rsync` snapshots from the docker host |

The git checkout is the source of truth. Everything except `volumes/`, `.env`, and
`lab-root-ca.crt` is reproducible from it. The canonical checkout path used throughout
is **`/opt/lab`**.

---

## Contents

1. [Stand up the two servers from scratch](#1-stand-up-the-two-servers-from-scratch)
2. [Add or remove a service](#2-add-or-remove-a-service)
3. [Backups — create and restore](#3-backups--create-and-restore)
4. [Issue a cert from the CA](#4-issue-a-cert-from-the-ca)
5. [Add DNS entries (Technitium web UI)](#5-add-dns-entries-technitium-web-ui)
6. [Smoke-test and health](#6-smoke-test-and-health)
7. [Enable DHCP (make the host the LAN's DHCP authority)](#7-enable-dhcp-make-the-host-the-lans-dhcp-authority)
8. [CI runner & offline docs](#8-ci-runner--offline-docs)

---

## 1. Stand up the two servers from scratch

### 1a. Docker host

Bring the whole stack up on a fresh Debian/Ubuntu box. Run as a user with `sudo`.

```bash
# --- packages: Docker Engine + compose plugin, plus rsync and an ssh server ---
sudo apt-get update
sudo apt-get install -y ca-certificates curl git rsync openssh-server
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER" && newgrp docker     # run docker without sudo

# (Ubuntu: swap the two `debian` strings above for `ubuntu`.)
```

```bash
# --- get the repo ---
sudo mkdir -p /opt/lab && sudo chown "$USER" /opt/lab
git clone <your-repo-url> /opt/lab        # or copy the tree in; rsync/scp/usb
cd /opt/lab

# --- secrets + host IP (.env is git-ignored; create from the template) ---
cp .env.example .env
$EDITOR .env                              # set HOST_IP to THIS box's LAN IP, set the
                                          # change-me passwords, keep LAB_DOMAIN=lab, and set
                                          # DOCKER_GID (getent group docker | cut -d: -f3;
                                          # the Forgejo runner needs it)

# --- runtime dirs (bind mounts; git-ignored). A few need specific ownership. ---
mkdir -p volumes/{caddy/data,caddy/config,stepca,technitium,forgejo,forgejo-runner,filebrowser,minio,share,privatebin,vaultwarden,cppreference,x86,tldr,code,term,opengrok/src,opengrok/data,opengrok/etc}
sudo chown 1000:1000  volumes/stepca         # step-ca runs as uid 1000
sudo chown 1000:1000  volumes/forgejo        # forgejo runs as uid 1000 (git)
sudo chown 1000:1000  volumes/forgejo-runner # runner runs as uid 1000
sudo chown 100:101    volumes/share          # samba/webdav write as uid 100 (smbuser)
sudo chown 65534:82   volumes/privatebin     # privatebin's php-fpm runs as uid 65534, gid 82
# (the doc dirs are served read-only by nginx. OpenGrok chowns volumes/opengrok/src to its own
#  uid 1111 on boot, so it needs no manual chown here -- but that mount must stay WRITABLE: a
#  :ro src makes the container exit at startup, surfacing as a Caddy 502. See §8.)

# --- pull every image + stage offline docs up front (ONLINE window; air-gap prep) ---
docker compose pull
./fetch-docs.sh                           # stage cppreference + x86 + tldr content (tldr build needs docker)
./build-profiles.sh                       # build the session profile images (code: Zig/Python; terminal: base/netutils)

# --- bring it up and wire DNS + CA + Forgejo (+ register the Actions runner) ---
docker compose up -d
./bootstrap.sh
```

`bootstrap.sh` creates the `lab` DNS zone, points `*.lab` + `lab` at `HOST_IP`, exports
the root CA to `./lab-root-ca.crt`, restarts Caddy to issue certs, and creates the Forgejo
admin user + public packages org. It is idempotent — re-run it any time.

> **Firewall:** if the host runs one, allow inbound `80`, `443/tcp+udp`, `53/tcp+udp`,
> `123/udp` (NTP), `445/tcp`, `139/tcp`, `9000/tcp`, and `22/tcp` (for the backup pull).
> Only if you enable the DHCP profile (§7), also allow `67/udp` on the LAN NIC.

Verify before moving on:

```bash
docker compose ps           # every service Up (Forgejo takes a few seconds to migrate)
./test.sh                   # end-to-end smoke test (see §6)
```

Then configure clients (resolve `*.lab`, trust `lab-root-ca.crt`) — see
[README → Client setup](README.md#client-setup-once-per-machine-that-uses-the-lab).

> **Packages:** Forgejo's registry works out of the box with no license — anonymous
> pull/download from the public `lab` org, authenticated push. The admin password lives in
> `.env` (the shared `LAB_PASSWORD`); change it in the UI later and mirror it back.

### 1b. Backup server

Pulls snapshots from the docker host (so the host can't reach — or wipe — the backups).
Run as `root` (reading the host's `volumes/` needs root on both ends).

```bash
sudo apt-get update && sudo apt-get install -y rsync openssh-client git
sudo git clone <your-repo-url> /opt/lab          # for the backup/ scripts (or copy them)

# 1. give this box an ssh key the docker host trusts (root, to read all of volumes/)
ssh-keygen -t ed25519 -f /root/.ssh/lab-backup -N ''
ssh-copy-id -i /root/.ssh/lab-backup root@dockerhost.lab    # or paste the .pub into the host

# 2. config
sudo install -d /etc/lab-backup
sudo cp /opt/lab/backup/config.env.example /etc/lab-backup/config.env
sudoedit /etc/lab-backup/config.env
#   SRC=root@dockerhost.lab:/opt/lab/volumes
#   DEST=/backups/lab               (this box's disk or a mounted NAS)
#   SSH_RSH="ssh -i /root/.ssh/lab-backup -o BatchMode=yes -o StrictHostKeyChecking=yes"
#   RESTORE_TARGET=/opt/lab/volumes

# 3. install the scripts + the every-3-hours timer
sudo install -m755 /opt/lab/backup/lab-backup.sh  /opt/lab-backup/lab-backup.sh
sudo install -m755 /opt/lab/backup/lab-restore.sh /opt/lab-backup/lab-restore.sh
sudo cp /opt/lab/backup/systemd/lab-backup.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now lab-backup.timer

# 4. prove it works now
sudo /opt/lab-backup/lab-backup.sh
/opt/lab-backup/lab-restore.sh list
```

Full detail (retention curve, hot vs. paused copy, off-site mirroring) is in
[`backup/README.md`](backup/README.md).

---

## 2. Add or remove a service

The wildcard `*.lab` DNS record already points every name at the host, and Caddy
discovers sites from container labels — so **adding a service needs no DNS or Caddy edit**,
just a compose file with the right labels.

### Add a service

1. Create `compose/<name>.yaml`. Minimal template for a web app behind Caddy that also
   shows up on the dashboard:

   ```yaml
   # <name> -- <one-line description>.
   services:
     <name>:
       image: <repo>@sha256:<digest>   # <readable tag>
       container_name: <name>
       restart: unless-stopped
       volumes:
         - ../volumes/<name>:/data     # only if it has state (mkdir it; see step 3)
       networks:
         - caddy
       labels:
         caddy: <name>.${LAB_DOMAIN}
         caddy.reverse_proxy: "{{upstreams <container-port>}}"
         homepage.group: Tools        # Infrastructure | Storage & Packages | Tools
         homepage.name: <Display Name>
         homepage.icon: <name>.png
         homepage.href: https://<name>.${LAB_DOMAIN}
         homepage.description: <short description>
         homepage.weight: "50"
   ```

   - **Not a web app** (e.g. it needs raw host ports like Samba): drop the `caddy` labels,
     put it on its own non-`caddy` network, and add `ports: ["${HOST_IP}:<p>:<p>"]`.
     Don't publish host ports from an `internal` network — Docker can't forward through one.
   - **Two sites on one container:** use ordinal label groups `caddy_0` / `caddy_1`
     (see `compose/minio.yaml`).

2. Add the file to the `include:` list in [`compose.yaml`](compose.yaml).

3. If it has persistent state, create its bind-mount dir (and chown if the image runs as
   a non-root uid): `mkdir -p volumes/<name>`.

4. Pin the image by digest (the stack convention):
   `docker pull <repo>:<tag>` then read the digest with
   `docker image inspect <repo>:<tag> --format '{{index .RepoDigests 0}}'`.

5. Apply and verify:

   ```bash
   docker compose up -d                 # creates the new container; leaves others alone
   docker compose logs -f <name>
   curl --resolve <name>.lab:443:$HOST_IP --cacert lab-root-ca.crt https://<name>.lab/
   ```

   The cert is issued on first request and is valid within ~30s (DNS already resolves via
   the wildcard). The dashboard tile appears automatically from the `homepage.*` labels.

### Remove a service

```bash
# 1. delete its line from compose.yaml's `include:` and remove compose/<name>.yaml
# 2. drop the container (and any now-orphaned ones):
docker compose up -d --remove-orphans
#    or target just it:   docker compose rm -sf <name>
# 3. optional: reclaim its data and config
sudo rm -rf volumes/<name>
rm -rf config/<name>
```

Caddy drops the site and the dashboard tile disappears on its own (label-driven). No DNS
change needed — the wildcard simply stops having a backend for that name.

### Add or rebuild a session profile (code or terminal)

Both `code.lab` and `terminal.lab` run the same `config/session-control/app.py` with a
per-kind config (`code.json` / `terminal.json`). Profiles are baked images, so changes are an
online/staging step. `<kind>` is `code` (FROM code-server) or `term` (FROM ttyd):

```bash
# 1. add or edit the Dockerfile (FROM the kind's pinned base; install tools/extensions)
$EDITOR profiles/<kind>/<name>/Dockerfile
# 2. register it (the control plane reads this; clients pick a profile by NAME only)
$EDITOR config/session-control/<code|terminal>.json   # add "<name>": {"image":"lab/<kind>-<name>:latest", ...}
# 3. (re)build -- needs internet (apt / toolchain download / Open VSX extensions)
./build-profiles.sh <kind>/<name>             # or `<kind>` for all of a kind; omit for everything
# 4. pick up the config change without rebuilding the control plane
docker compose restart code-control           # or term-control
```

Running sessions keep the image they were created with; *new* sessions of that profile use
the rebuilt image. Notes: code extensions install from **Open VSX** (Microsoft's first-party
extensions aren't there — use Open-VSX ids or build from source, as the `zig` profile does for
ZLS); the bind-mounted dir (`volumes/code/<name>/project` or `volumes/term/<name>/root`) is
rsync-backed up; deleting a session from the UI removes its container **and** wipes that dir.

> **Session not reachable?** `*.code.lab` / `*.terminal.lab` are one label deeper than `*.lab`,
> so they need their own wildcards — `bootstrap.sh` adds both. If sessions 404 in DNS, re-run it.

---

## 3. Backups — create and restore

Backups run on the **backup server** (set up in §1b). Each run is a dated `rsync`
hard-link snapshot of the docker host's `volumes/`; retention thins them to a 3h…3-month
curve. Mechanics and the retention list: [`backup/README.md`](backup/README.md).

### Create a backup now (off-schedule)

```bash
# on the backup server
sudo /opt/lab-backup/lab-backup.sh                       # uses /etc/lab-backup/config.env
sudo PAUSE_CONTAINERS=1 /opt/lab-backup/lab-backup.sh    # guaranteed-consistent DB copy
                                                         # (brief docker pause, not a restart)
```

### List snapshots

```bash
/opt/lab-backup/lab-restore.sh list
```

### Restore

```bash
# A) back onto the SAME docker host (stop the stack first so nothing is mid-write):
#    (run from /opt/lab on the host, or use --target)
ssh root@dockerhost.lab 'cd /opt/lab && docker compose down'
sudo /opt/lab-backup/lab-restore.sh restore latest --to root@dockerhost.lab:/opt/lab/volumes
ssh root@dockerhost.lab 'cd /opt/lab && docker compose up -d && ./bootstrap.sh'

# B) onto a BRAND-NEW host, before its first `up` (do §1a through the volumes step, then):
sudo /opt/lab-backup/lab-restore.sh restore latest --to root@newhost:/opt/lab/volumes
ssh root@newhost 'cd /opt/lab && docker compose up -d && ./bootstrap.sh'

# C) locally, if you run the restore on the machine that holds the volumes:
sudo /opt/lab-backup/lab-restore.sh restore 20260619T030000 --target /opt/lab/volumes
```

`--force` skips the overwrite prompt. The whole `volumes/` tree comes back with the same
paths, perms and UIDs (`rsync -aH --numeric-ids`), so the stack mounts it straight back in.

> **Not in the backups:** `.env` and `lab-root-ca.crt` are neither under `volumes/` nor in
> git — keep them in a password manager. The CA in `volumes/stepca/` *is* backed up; losing
> it means every client must re-trust a new root.

After any restore, run `./test.sh` on the host (§6).

---

## 4. Issue a cert from the CA

Caddy-proxied `*.lab` sites get their certs automatically. This is for **other** hosts or
devices (a standalone web server, a printer, a syslog box) that need a `.lab` cert trusted
by everything that already trusts `lab-root-ca.crt`.

### Option A — ACME (preferred; auto-renews)

step-ca is a normal ACME CA at `https://ca.lab:9000/acme/acme/directory`. Point any ACME
client at it; the only prerequisite is that the client trusts the root CA and can resolve
`*.lab`.

```bash
# example with acme.sh, issuing for myapp.lab
export CA_BUNDLE=/usr/local/share/ca-certificates/lab-ca.crt   # the trusted root
acme.sh --server https://ca.lab:9000/acme/acme/directory \
        --issue -d myapp.lab --standalone --ca-bundle "$CA_BUNDLE"
```

certbot (`--server https://ca.lab:9000/acme/acme/directory`) and step (`step ca certificate`)
work the same way. Caddy on another host can use the global `acme_ca` / `acme_ca_root`
options exactly like this stack's Caddy does.

### Option B — one-off, issued by hand inside the CA

No ACME round-trip; signs a leaf directly with the intermediate. Good for a device that
can't run an ACME client. (Verified procedure — `step` ships in the container.)

```bash
# issue myapp.lab (+ an IP SAN) valid 90 days, key unencrypted for server use
docker compose exec step-ca sh -c '
  cd /tmp
  step certificate create "myapp.lab" myapp.crt myapp.key \
    --ca /home/step/certs/intermediate_ca.crt \
    --ca-key /home/step/secrets/intermediate_ca_key \
    --ca-password-file /home/step/secrets/password \
    --san myapp.lab --san 192.168.1.50 \
    --not-after 2160h --bundle --no-password --insecure
'
# copy them out to the host, then to the device
docker compose cp step-ca:/tmp/myapp.crt ./myapp.crt
docker compose cp step-ca:/tmp/myapp.key ./myapp.key
docker compose exec step-ca rm -f /tmp/myapp.crt /tmp/myapp.key
```

`myapp.crt` is bundled (leaf + intermediate); any client that trusts `lab-root-ca.crt`
will accept it. Verify: `step certificate verify myapp.crt --roots lab-root-ca.crt`, or
`openssl verify -CAfile lab-root-ca.crt myapp.crt`.

---

## 5. Add DNS entries (Technitium web UI)

The `lab` zone is authoritative; `bootstrap.sh` seeds the `*.lab` wildcard and the `lab`
apex (both → `HOST_IP`). Add records for other hosts, devices, aliases, or service records.

1. Browse **`https://dns.lab`** and log in (the shared `LAB_USER` / `LAB_PASSWORD` from
   `.env`; Technitium's username is `admin`).
2. **Zones → `lab` → Add Record.**
3. Pick the type and fill it in:
   - **A** — `nas` → `192.168.1.50` (a real host; more specific than the wildcard, so it
     wins for that name).
   - **CNAME** — `grafana` → `home.lab` (an alias onto an existing name).
   - **MX / TXT / SRV** — as needed.
4. Save. TTLs are short (300s), so changes take effect within minutes; flush the client
   resolver cache if you're impatient.

Notes:

- The `*.lab` wildcard answers any name with no explicit record, so a brand-new
  Caddy-fronted service needs **no** DNS entry. Add explicit records only for things the
  wildcard shouldn't cover (other physical hosts, non-host record types).
- To forward a different private domain or change upstreams, use **Settings → Forwarders**.
- Scripting the same thing (what `bootstrap.sh` does) — the HTTP API:

  ```bash
  TOKEN=$(curl -s "http://127.0.0.1:5380/api/user/login?user=admin&pass=$PASS" | jq -r .token)
  curl -s "http://127.0.0.1:5380/api/zones/records/add?token=$TOKEN&zone=lab&domain=nas.lab&type=A&ipAddress=192.168.1.50&ttl=300"
  ```

  The API is published on the host's loopback (`127.0.0.1:5380`); from elsewhere, go
  through `https://dns.lab`.

---

## 6. Smoke-test and health

```bash
cd /opt/lab
docker compose ps                 # all Up; Forgejo takes a few seconds to migrate on first boot
./test.sh                         # end-to-end: DNS, TLS chain, every HTTP endpoint, step-ca,
                                  # WebDAV, SMB<->WebDAV interop, MinIO S3, Forgejo packages
docker compose logs -f <service>  # follow one service
```

`test.sh` reaches services with `curl --resolve` / container `--add-host` / SMB-by-IP, so
it passes from the host itself even though the host's own resolver isn't pointed at
Technitium. A green run also proves the step-ca → Caddy certificate chain is trusted, and
it does a real **PyPI publish+install** and **Docker push+pull** against Forgejo (cleaning
up the test packages afterward).

Common one-offs:

```bash
docker compose restart caddy                   # re-issue / reload after a TLS change
docker compose restart webdav                  # apply a config/nginx/nginx.conf edit
docker compose pull && docker compose up -d     # update images
docker compose cp step-ca:/home/step/certs/root_ca.crt ./lab-root-ca.crt   # re-export the CA
```

To rename the TLD, change `LAB_DOMAIN` in `.env`, then
`docker compose up -d --force-recreate && ./bootstrap.sh` — nothing else hardcodes it.

---

## 7. Enable DHCP (make the host the LAN's DHCP authority)

DHCP is **opt-in** and ships disabled (compose profile `dhcp`). Turn it on only when you
want *this host* to address the LAN — it then hands every client the lab's DNS and NTP
automatically, so joining the network is the entire client setup (the root CA still has to
be trusted by hand; DHCP can't push it).

> **Stop here if a router already runs DHCP.** Two DHCP servers on one segment hand out
> conflicting leases. Either disable the router's DHCP first, **or** don't run this at all
> and instead set the router's DNS (option 6) and NTP (option 42) to `HOST_IP` — that gets
> you the same zero-config clients with no second server. Only proceed below if this host
> is the *sole* DHCP server on the segment.

```bash
cd /opt/lab

# 1. find the host's LAN NIC (the one on the lab subnet)
ip -br link            # e.g. ens18 / eth0 / enp3s0

# 2. fill in the DHCP_* block in .env to match the LAN:
#      DHCP_INTERFACE=ens18              # the NIC from step 1
#      DHCP_RANGE_START=192.168.1.100    # pool start (keep clear of static IPs + HOST_IP)
#      DHCP_RANGE_END=192.168.1.200      # pool end
#      DHCP_NETMASK=255.255.255.0
#      DHCP_GATEWAY=192.168.1.1          # the LAN's real gateway/router
#      DHCP_LEASE=12h

# 3. start just the DHCP container (the rest of the stack keeps running untouched)
docker compose --profile dhcp up -d
docker compose logs -f dhcp            # watch for "DHCP, IP range ... lease time ..."
```

Verify a client gets a lease with the right options (DNS + NTP = `HOST_IP`, domain `lab`):

```bash
# on a client, request a fresh lease and inspect it
sudo dhclient -v <iface>                       # or: nmcli con up <con>
nmcli dev show <iface> | grep -E 'DNS|DOMAIN'  # should show HOST_IP and the lab domain
resolvectl status <iface> | grep -A1 'DNS Servers'
```

dnsmasq runs **DNS-disabled** (`--port=0`), so it only ever answers DHCP — Technitium stays
the only DNS server. It binds DHCP to `DHCP_INTERFACE` alone (`--bind-interfaces`), so it
won't leak onto other NICs. Leases are kept in the (ephemeral) container; a restart just
means clients re-request — harmless.

Turn it back off:

```bash
docker compose --profile dhcp down dhcp     # or: docker compose rm -sf dhcp
```

> A plain `docker compose up -d` (no `--profile dhcp`) never starts DHCP and never stops a
> running one — the profile gate keeps it out of the default lifecycle. Always include
> `--profile dhcp` in commands meant to manage it.

---

## 8. CI runner & offline docs

Day-two notes for the developer-tooling services layered on top of the core stack. Setup and
the air-gap details live in the [README](README.md); these are the "how do I…" one-liners. None
of these open new host ports — they all go through Caddy (`80`/`443`) or stay internal, so the
§1a firewall list is unchanged.

### Forgejo Actions runner

`bootstrap.sh` registers it automatically (shared-secret flow). To inspect or redo it:

```bash
docker compose logs --tail=20 forgejo-runner   # "waiting for registration" = not bootstrapped;
                                               # once registered the daemon logs a successful poll
./bootstrap.sh                                 # idempotent: registers if needed, else no-ops
# the forge lists its runners in the UI:  https://packages.lab/-/admin/actions/runners

# force a clean re-register (fresh identity). The secret/.runner live in the data volume and
# are owned by uid 1000, so wipe them from inside the container, not with host rm:
docker compose exec -T forgejo-runner sh -c 'rm -f /data/secret /data/.runner'
docker compose restart forgejo-runner && ./bootstrap.sh
```

Job labels / capacity are in `config/forgejo-runner/config.yaml`; edit then
`docker compose restart forgejo-runner`. Air-gap rules still apply: `runs-on:` images must be
pre-pulled and `uses:` actions mirrored into the forge (README → "Forgejo Actions (CI)").

**Stronger isolation (docker-in-docker).** The runner shares the host Docker socket by default.
To sandbox CI instead, run a `docker:dind` sidecar and point the runner at it
(`DOCKER_HOST=tcp://docker-in-docker:2375`, drop the socket mount) — the upstream layout is in
the [Forgejo runner docs](https://forgejo.org/docs/latest/admin/actions/runner-installation/).

### Offline docs (re-staging)

Content lives in `volumes/{cppreference,x86,tldr}`, served read-only. Refresh it from a box
with internet (the `tldr` target also needs `docker` — it builds the PWA in a node container),
then carry the dirs over:

```bash
./fetch-docs.sh                 # all of them
./fetch-docs.sh cppreference    # just one target
# if staged on another machine, rsync the dir(s) into the host's volumes/, then:
docker compose restart cppreference x86 tldr
```

### Code search (OpenGrok)

OpenGrok (`search.lab`) cross-references and full-text-searches whatever source trees sit under
`volumes/opengrok/src`, one project per top-level dir. It's anonymous and read-only — no login,
no bootstrap step. Stage code with `./ingest-repos.sh` (offline; extracts archives or copies a
dir in), then it reindexes on its timer (`SYNC_PERIOD_MINUTES`, default 15) or on restart:

```bash
./ingest-repos.sh ~/incoming/*.tar.gz      # or a directory: ./ingest-repos.sh ~/src/myproject
docker compose restart opengrok            # index now instead of waiting for the timer
```

**The chown pattern.** OpenGrok's entrypoint runs as root and **chowns `/opengrok/src` to its
`appuser` (uid 1111) on every boot.** Two consequences worth remembering:

- The src mount **must be writable**. A `:ro` mount makes the boot-time chown fail, the container
  exits, and the only symptom is a **Caddy 502** (an empty 502, not an OpenGrok error page).
  `compose/opengrok.yaml` mounts src read-write for exactly this reason — don't re-add `:ro`.
- After the first boot, `volumes/opengrok/src` is owned by uid 1111, so a later
  `./ingest-repos.sh` run as your own user can't write into it. Take ownership back first;
  OpenGrok silently re-chowns it on its next start (harmless — indexing only reads it):

  ```bash
  sudo chown -R "$USER" volumes/opengrok/src
  ./ingest-repos.sh ...
  docker compose restart opengrok
  ```

The service has a healthcheck against `/api/v1/system/ping`, so a crash-loop like the `:ro` case
shows up as **unhealthy** in `docker compose ps` instead of silently 502-ing.
