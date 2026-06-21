# SmallLab

SmallLab is a single `docker compose` stack that turns one Linux host into a self-contained
`.lab` environment for a LAN: trusted HTTPS on every service, a dashboard, DNS, NTP, a
universal package registry, object storage, a file share, on-demand dev sessions, a set of
browser-based dev tools, and a shelf of offline references — from one repo, with no runtime
dependency on the public internet.

What it accomplishes:

- **One TLD, real certs.** step-ca runs an internal ACME CA and Caddy enrolls every site with
  it, so each client trusts a single root and gets warning-free HTTPS for `*.lab`.
- **No per-service wiring.** Technitium resolves `*.lab` to the host, Caddy discovers sites
  from container labels, and the dashboard builds itself from the same labels — adding a
  service is one compose file.
- **Runs offline.** Images are pinned by digest, references and docs are staged ahead of time,
  and the stack serves its own DNS, time, and packages, so it works on an air-gapped LAN.
- **Reproducible.** Everything but `volumes/`, `.env`, and the exported CA is in git; backups
  are plain rsync snapshots.

> Day-two operations — onboarding clients, adding services, backups, issuing certs, and using
> each service — are in **[`Playbook.md`](Playbook.md)**.

## Services

| Service        | URL / address                                   | Host port(s)                 | What it is |
|----------------|-------------------------------------------------|------------------------------|------------|
| **Caddy**      | terminates all `https://*.lab`                  | `80`, `443` (tcp+udp)        | [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) — config from labels; gets certs from step-ca over ACME |
| **step-ca**    | `https://ca.lab:9000`                           | `9000`                       | [Smallstep](https://smallstep.com/docs/step-ca/) internal ACME CA — the one root every client trusts |
| **Homepage**   | `https://home.lab`                              | via Caddy                    | dashboard; auto-discovers services from container labels |
| **Technitium** | `https://dns.lab` (console)                     | `53/udp`, `53/tcp`, `127.0.0.1:5380` | [DNS server](https://technitium.com/dns/), authoritative for `*.lab`, forwards the rest |
| **NTP**        | `ntp.lab` (= `HOST_IP`)                          | `123/udp`                    | [chrony](https://chrony-project.org/) time source; serves the host clock to the LAN so TLS / TOTP / SMB don't break on client drift |
| **DHCP** *(opt-in)* | serves the LAN — `--profile dhcp`          | `67/udp` (host net)          | [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) in DHCP-only mode; hands clients lab DNS + NTP + domain. **Off by default** |
| **Forgejo**    | `https://packages.lab`                          | via Caddy                    | [Forgejo](https://forgejo.org) Git forge + universal package registry — Docker/OCI, npm, PyPI, Maven, Cargo, … ; one host serves UI, REST API **and** `/v2/` |
| **Forgejo Runner** | registers to Forgejo (internal)             | — (drives Docker socket)     | [Forgejo Actions](https://forgejo.org/docs/latest/admin/actions/) CI runner; runs workflows as containers. Auto-registered by `bootstrap.sh` |
| **MinIO**      | `https://s3.lab` (API), `https://s3-console.lab`| via Caddy                    | S3-compatible object storage + console |
| **Samba**      | `\\files.lab\lab`                               | `445/tcp`, `139/tcp`         | SMB share, **passwordless guest access** (no auth) |
| **Filebrowser**| `https://files.lab`                             | via Caddy                    | web face for the same share, **no login** (noauth) |
| **WebDAV**     | `https://dav.lab`                               | via Caddy                    | curl `GET`/`PUT`/`DELETE` to the same share (no auth) |
| **CyberChef**  | `https://cyberchef.lab`                         | via Caddy                    | offline data-mangling swiss army knife |
| **IT-Tools**   | `https://tools.lab`                             | via Caddy                    | offline dev / crypto / network utilities |
| **DevDocs**    | `https://devdocs.lab`                           | via Caddy                    | offline API docs browser — Python, C, Linux man pages, hundreds more (baked into the image) |
| **drawio**     | `https://draw.lab`                              | via Caddy                    | offline diagram editor — network maps, attack trees, report figures |
| **PrivateBin** | `https://paste.lab`                             | via Caddy                    | client-side-encrypted pastebin (server sees only ciphertext) |
| **Vaultwarden**| `https://vault.lab`                             | via Caddy                    | Bitwarden-compatible secrets vault |
| **Dozzle**     | `https://logs.lab`                              | via Caddy                    | live Docker log viewer for this stack |
| **Compiler Explorer** | `https://godbolt.lab`                    | via Caddy                    | [Compiler Explorer](https://github.com/compiler-explorer/compiler-explorer) (Godbolt) — interactive source→asm |
| **PlantUML**   | `https://plantuml.lab`                          | via Caddy                    | [PlantUML server](https://github.com/plantuml/plantuml-server) — render UML diagrams from text (Graphviz bundled, renders on-box) |
| **AST Explorer** | `https://ast.lab`                             | via Caddy                    | [AST Explorer](https://github.com/fkling/astexplorer) — parse source into an AST across ~80 parsers, in-browser |
| **JSON Crack** | `https://jsoncrack.lab`                         | via Caddy                    | [JSON Crack](https://github.com/AykutSarac/jsoncrack.com) — visualize JSON / YAML / CSV / XML as node graphs |
| **Mermaid Live** | `https://mermaid.lab`                         | via Caddy                    | [Mermaid Live Editor](https://github.com/mermaid-js/mermaid-live-editor) — diagrams-as-code, rendered in-browser |
| **SQLime**     | `https://sqlime.lab`                            | via Caddy                    | [SQLime](https://github.com/nalgeon/sqlime) — SQLite playground; the engine runs in-browser via WASM |
| **jq kung fu** | `https://jq.lab`                                | via Caddy                    | [jq kung fu](https://github.com/robertaboukhalil/jqkungfu) — run jq filters in-browser (jq compiled to WASM) |
| **OpenGrok**   | `https://search.lab`                            | via Caddy                    | source cross-reference + full-text code search over local repos (`./ingest-repos.sh`); read-only, no login |
| **Code Workspaces** | `https://code.lab`, sessions at `https://<name>.code.lab` | via Caddy        | on-demand [code-server](https://github.com/coder/code-server) sessions — create / open / stop / delete from a tiny UI; baked per-language profiles. **No login** (shared) |
| **Terminals**  | `https://terminal.lab`, sessions at `https://<name>.terminal.lab` | via Caddy   | on-demand [ttyd](https://github.com/tsl0922/ttyd) browser terminals (`tmux`); same create/stop/delete UI + baked tool profiles. **No login** (shared) |
| **cppreference** | `https://cppref.lab`                          | via Caddy                    | offline C / C++ standard library reference (static HTML) |
| **x86 ref**    | `https://x86.lab`                               | via Caddy                    | offline x86/x64 instruction reference (mirror of [c9x.me/x86](https://c9x.me/x86/)) |
| **tldr**       | `https://tldr.lab`                              | via Caddy                    | offline tldr-pages command cheatsheets ([tldr.inbrowser.app](https://github.com/InBrowserApp/tldr.inbrowser.app) PWA; pages baked into the bundle) |
| **Syscall tables** | `https://syscalls.lab`                      | via Caddy                    | offline x86-64 syscall tables by kernel version (v4.0–v6.17) — full signatures with arg names, C types & registers (built from [mebeim/linux-syscalls](https://github.com/mebeim/linux-syscalls), [Systrack](https://syscalls.mebeim.net)) |
| **ExplainShell** | `https://explainshell.lab`                    | via Caddy                    | [explainshell](https://github.com/idank/explainshell) — explains a shell command from its man pages; locally-built image, DB baked in |
| **DevHints**   | `https://devhints.lab`                          | via Caddy                    | offline developer cheatsheets (built from the [devhints.io](https://github.com/rstacruz/cheatsheets) Astro source) |
| **HackTricks** | `https://hacktricks.lab`                        | via Caddy                    | offline pentest methodology wiki (mdBook build of [HackTricks](https://github.com/HackTricks-wiki/hacktricks), English) |
| **GTFOBins**   | `https://gtfobins.lab`                          | via Caddy                    | offline Unix living-off-the-land binaries (built from the [GTFOBins](https://github.com/GTFOBins/GTFOBins.github.io) Jekyll source) |
| **LOLBAS**     | `https://lolbas.lab`                            | via Caddy                    | offline Windows living-off-the-land binaries (built from the [LOLBAS](https://github.com/LOLBAS-Project/LOLBAS-Project.github.io) Jekyll source) |
| **PayloadsAllTheThings** | `https://payloads.lab`                | via Caddy                    | offline [PayloadsAllTheThings](https://github.com/swisskyrepo/PayloadsAllTheThings) payload/technique reference (its mkdocs-material site, client-side search) |

Host-bound ports (`53`, `123`, `445`, `139`, `9000`) bind to `${HOST_IP}` only; Caddy binds
`0.0.0.0`. DHCP is the exception — it uses host networking on one NIC and starts only under
`--profile dhcp`.

## Repository layout

```text
compose.yaml          # root: project name, shared networks, `include:` of the files below
compose/              # one file per service -- caddy.yaml, step-ca.yaml, technitium.yaml, ...
config/               # checked-in config the services read
  homepage/           #   dashboard config + local icons
  filebrowser/        #   settings.json
  nginx/              #   WebDAV nginx config
  session-control/    #   shared session control plane: app.py + code.json + terminal.json
images/               # one dir per locally-built image -- Dockerfile (+ build-time conf) -> lab/<name>:latest
volumes/              # runtime state -- bind mounts, git-ignored, NOT checked in
dist/                 # build.sh output -- gzipped image tarballs for transfer (git-ignored)
bootstrap.sh          # post-`up` DNS + CA + Forgejo wiring (idempotent)
build.sh              # build every images/* + pull prebuilts + save tarballs to dist/ (staging step)
ingest-repos.sh       # stage source trees into OpenGrok
test.sh               # end-to-end smoke test of every service
backup/               # pull-based backup tooling (runs on the backup server)
.env                  # secrets + HOST_IP + LAB_DOMAIN (git-ignored; copy from .env.example)
Playbook.md           # day-two operations
```

`docker compose` auto-discovers `compose.yaml` and merges every file under `compose/` via
`include:`. Paths in an included file resolve relative to that file, hence the `../config/...`
and `../volumes/...` references.

## Scripts

| Script | What it does | When to use |
|--------|--------------|-------------|
| `bootstrap.sh` | Wires the running stack: creates the `lab` DNS zone + `*.lab`/`lab` records, exports the root CA to `lab-root-ca.crt`, restarts Caddy to issue certs, creates the Forgejo admin user + public org, and registers the Actions runner. Idempotent. | After `docker compose up -d` on first install, and after any `--force-recreate` or image bump that resets a container. Re-run any time to repair. |
| `build.sh` | The staging step: builds every custom image under `images/<name>/` into `lab/<name>:latest`, pulls the pinned prebuilt images the stack references, and saves both groups as gzipped tarballs under `dist/` for transfer (`docker load` on the target). Needs internet + docker. | In the provisioning window, and to refresh images later. |
| `ingest-repos.sh` | Extracts or copies source trees into `volumes/opengrok/src` for OpenGrok to index. Offline. | To add or update code on `search.lab`. |
| `test.sh` | End-to-end smoke test of every service (DNS, TLS chain, HTTP, step-ca, WebDAV/SMB, MinIO, Forgejo packages, sessions). Exits non-zero on any failure. | After install, a restore, or an image bump. |
| `backup/lab-backup.sh` | Takes one rsync hard-link snapshot of the host's `volumes/` and prunes to the retention curve. Runs on the backup server (its timer calls it every 3h). | Off-schedule backups; the timer handles the routine ones. |
| `backup/lab-restore.sh` | Lists snapshots and restores one into a host's `volumes/`. | Disaster recovery or seeding a new host. |

Usage details and the procedures that wrap these scripts are in [`Playbook.md`](Playbook.md).

## Install

SmallLab runs on two servers: a **docker host** (the whole stack) and a **backup server**
(pulls rsync snapshots from the host, so the host can't reach or wipe the backups). The
canonical checkout path is `/opt/lab`.

| Role | Hostname (example) | Runs |
|------|--------------------|------|
| **Docker host** | `dockerhost.lab` (`192.168.1.171`) | the whole compose stack |
| **Backup server** | `backup.lab` | pulls rsync snapshots from the docker host |

### Docker host

Fresh Debian/Ubuntu box, run as a user with `sudo`.

```bash
# packages: Docker Engine + compose plugin, plus rsync and an ssh server
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
# get the repo
sudo mkdir -p /opt/lab && sudo chown "$USER" /opt/lab
git clone <your-repo-url> /opt/lab        # or copy the tree in: rsync/scp/usb
cd /opt/lab

# secrets + host IP (.env is git-ignored; create from the template)
cp .env.example .env
$EDITOR .env                              # set HOST_IP to THIS box's LAN IP, set the change-me
                                          # passwords, keep LAB_DOMAIN=lab, and set DOCKER_GID
                                          # (getent group docker | cut -d: -f3)

# runtime dirs (bind mounts, git-ignored); a few need specific ownership
mkdir -p volumes/{caddy/data,caddy/config,stepca,technitium,forgejo,forgejo-runner,filebrowser,minio,share,privatebin,vaultwarden,code,term,opengrok/src,opengrok/data,opengrok/etc}
sudo chown 1000:1000  volumes/stepca         # step-ca runs as uid 1000
sudo chown 1000:1000  volumes/forgejo        # forgejo runs as uid 1000 (git)
sudo chown 1000:1000  volumes/forgejo-runner # runner runs as uid 1000
sudo chown 100:101    volumes/share          # samba/webdav write as uid 100 (smbuser)
sudo chown 65534:82   volumes/privatebin     # privatebin's php-fpm runs as uid 65534, gid 82
# (OpenGrok chowns volumes/opengrok/src to uid 1111 on boot, so leave that mount writable —
#  a :ro src makes the container exit.)

# build the custom images + pull the pinned prebuilts (needs internet — the air-gap prep window).
# build.sh also writes dist/*.tar.gz; for an air-gapped host, run build.sh on an online box, copy
# dist/ over, and `for f in dist/*.tar.gz; do docker load -i "$f"; done` in place of this line.
./build.sh

# bring it up and wire DNS + CA + Forgejo (+ register the Actions runner)
docker compose up -d
./bootstrap.sh
```

`bootstrap.sh` creates the `lab` DNS zone, points `*.lab` + `lab` at `HOST_IP`, exports the
root CA to `./lab-root-ca.crt`, restarts Caddy to issue certs, and creates the Forgejo admin
user + public packages org. It is idempotent — re-run it any time. HTTPS goes valid a few
moments **after** bootstrap, not at `up` (step-ca needs the DNS records to validate each name).

Verify, then onboard clients (see [Playbook → Onboard a client](Playbook.md#onboard-a-client)):

```bash
docker compose ps           # every service Up (Forgejo takes a few seconds to migrate)
./test.sh                   # end-to-end smoke test
```

> **Firewall:** if the host runs one, allow inbound `80`, `443/tcp+udp`, `53/tcp+udp`,
> `123/udp`, `445/tcp`, `139/tcp`, `9000/tcp`, and `22/tcp` (backup pull). With the DHCP
> profile on, also allow `67/udp` on the LAN NIC.

### Backup server

Pulls snapshots from the docker host. Run as `root` (reading the host's `volumes/` needs root
on both ends).

```bash
sudo apt-get update && sudo apt-get install -y rsync openssh-client git
sudo git clone <your-repo-url> /opt/lab          # for the backup/ scripts (or copy them)

# 1. give this box an ssh key the docker host trusts (root, to read all of volumes/)
ssh-keygen -t ed25519 -f /root/.ssh/lab-backup -N ''
ssh-copy-id -i /root/.ssh/lab-backup root@dockerhost.lab

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

Mechanics, the retention curve, and disaster recovery are in [`backup/README.md`](backup/README.md).

## Notes

- **Every image is pinned by digest** (`@sha256:…`); the readable tag is in the trailing
  comment on each `image:` line. Bump one with `docker pull <repo>:<tag>` then swap in the
  digest from `docker image inspect <repo>:<tag> --format '{{index .RepoDigests 0}}'`.
- **`.env`, `lab-root-ca.crt`, and `volumes/` are git-ignored.** Keep `.env` and the CA in a
  password manager — they're not reproducible from git.
- **The trusted root lives in `volumes/stepca/`** (step-ca's root), and is included in
  backups. Lose it and every client must re-trust a new root.
- **Certs validate only for clients that trust the exported root CA** — inherent to a private
  TLD. A real domain + DNS-01 would yield publicly trusted certs instead.
- **`LAB_DOMAIN` is the only place the TLD is set.** It is interpolated into every `caddy:` and
  `homepage.*` label and read by `bootstrap.sh`; see [Playbook → Rename the TLD](Playbook.md#rename-the-tld).
