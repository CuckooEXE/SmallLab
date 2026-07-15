# SmallLab

SmallLab is a single `docker compose` stack that turns one Linux host into a self-contained
`.lab` environment for a LAN: trusted HTTPS on every service, a dashboard, DNS, NTP, object
storage, a file share, on-demand dev sessions, a set of browser-based dev tools, a shelf of
offline references, and an opt-in `full-lab` profile that adds GitLab and Mattermost — from
one repo, with no runtime dependency on the public internet.

What it accomplishes:

- **One TLD, real certs.** step-ca runs an internal ACME CA and Caddy enrolls every site with
  it, so each client trusts a single root and gets warning-free HTTPS for `*.lab`.
- **No per-service wiring.** Technitium resolves `*.lab` to the host, Caddy discovers sites
  from container labels, and the dashboard builds itself from the same labels — adding a
  service is one compose file.
- **Runs offline.** Images are pinned by version tag, references and docs are staged ahead of time,
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
| **GitLab** *(opt-in)* | `https://gitlab.lab` — `--profile full-lab` | via Caddy                    | [GitLab CE](https://docs.gitlab.com/install/docker/) DevOps forge — repos, issues, CI/CD, built-in package registries (PyPI, npm, Maven, …). Admin is the fixed `root` user. **Off by default** (heavy: ~4 GB RAM) |
| **Mattermost** *(opt-in)* | `https://chat.lab` — `--profile full-lab` | via Caddy                | [Mattermost](https://mattermost.com) Team Edition chat (+ its PostgreSQL sidecar `mattermost-db`). Admin seeded by `bootstrap.sh`. **Off by default** |
| **Ollama** *(opt-in)* | `https://ollama.lab` — `--profile ai-<cpu\|nvidia\|amd\|intel>` | via Caddy      | [Ollama](https://ollama.com) local LLM runtime (HTTP API). Pick one accelerator profile; CPU needs no drivers, GPU needs host setup (`./gpu-setup.sh`). **Off by default** |
| **Open WebUI** *(opt-in)* | `https://ai.lab` — same `ai-*` profiles       | via Caddy                    | [Open WebUI](https://github.com/open-webui/open-webui) browser chat + model management, talks to Ollama. No login (LAN-trust). **Off by default** |
| **MinIO**      | `https://s3.lab` (API), `https://s3-console.lab`| via Caddy                    | S3-compatible object storage + console |
| **Samba**      | `\\files.lab\lab`                               | `445/tcp`, `139/tcp`         | SMB share, **passwordless guest access** (no auth) |
| **Filebrowser**| `https://files.lab`                             | via Caddy                    | web face for the same share, **no login** (noauth) |
| **WebDAV**     | `https://dav.lab`                               | via Caddy                    | curl `GET`/`PUT`/`DELETE` to the same share (no auth) |
| **sist2**      | `https://find.lab`                              | via Caddy                    | full-text search over the file share — [sist2](https://github.com/sist2app/sist2) (SQLite/FTS5), re-indexed hourly; thumbnails, OCR, type/size/date facets |
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
| **LibreTranslate** | `https://translate.lab`                     | via Caddy                    | [LibreTranslate](https://github.com/LibreTranslate/LibreTranslate) — offline machine translation (API + UI); language models baked into the image |
| **Stirling-PDF** | `https://pdf.lab`                             | via Caddy                    | [Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF) — upload a PDF → OCR → extract text, plus a full PDF toolbox; telemetry off |
| **ConvertX**   | `https://convert.lab`                           | via Caddy                    | [ConvertX](https://github.com/C4illin/ConvertX) — convert files between ~1000 formats (images / docs / audio / video); batch upload, no login |
| **OpenGrok**   | `https://grok.lab`                              | via Caddy                    | source cross-reference + full-text code search over local repos (`./ingest-repos.sh`); read-only, no login |
| **Code Workspaces** | `https://code.lab`, sessions at `https://<name>.code.lab` | via Caddy        | on-demand [code-server](https://github.com/coder/code-server) sessions — create / open / stop / delete from a tiny UI; baked per-language profiles. **No login** (shared) |
| **Terminals**  | `https://terminal.lab`, sessions at `https://<name>.terminal.lab` | via Caddy   | on-demand [ttyd](https://github.com/tsl0922/ttyd) browser terminals (`tmux`); same create/stop/delete UI + baked tool profiles. **No login** (shared) |
| **cppreference** | `https://cppref.lab`                          | via Caddy                    | offline C / C++ standard library reference (static HTML) |
| **x86 ref**    | `https://x86.lab`                               | via Caddy                    | offline x86/x64 instruction reference (mirror of [c9x.me/x86](https://c9x.me/x86/)) |
| **ARM ref**    | `https://arm.lab`                               | via Caddy                    | offline AArch64 (A64) instruction reference (mirror of [Yedidia's ARM64 reference](https://www.scs.stanford.edu/~zyedidia/arm64/), generated from ARM's machine-readable spec) |
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
`--profile dhcp`. GitLab, Mattermost, and its database start only under `--profile full-lab`
(see [Playbook → Run the full-lab profile](Playbook.md#run-the-full-lab-profile-gitlab--mattermost));
neither publishes a host port — no git-over-ssh, clone over HTTPS. Ollama + Open WebUI start only
under one `--profile ai-<cpu|nvidia|amd|intel>` accelerator profile (see
[Playbook → Run local LLMs](Playbook.md#run-local-llms-ollama-with-gpu-or-cpu)).

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
bootstrap.sh          # post-`up` DNS + CA wiring (+ Mattermost seeding); idempotent
build.sh              # build every images/* + pull prebuilts + save tarballs to dist/ (staging step)
ingest-repos.sh       # stage source trees into OpenGrok
gpu-setup.sh          # detect the host GPU + report driver/toolkit steps for the Ollama profiles
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
| `bootstrap.sh` | Wires the running stack: creates the `lab` DNS zone + `*.lab`/`lab` records, exports the root CA to `lab-root-ca.crt`, restarts Caddy to issue certs, and (when the `full-lab` profile is up) seeds the Mattermost admin + default team. Idempotent. | After `docker compose up -d` on first install, and after any `--force-recreate` or image bump that resets a container. Re-run any time to repair. |
| `build.sh` | The staging step: builds every custom image under `images/<name>/` into `lab/<name>:latest`, pulls the pinned prebuilt images the stack references, and saves both groups as gzipped tarballs under `dist/` for transfer (`docker load` on the target). Needs internet + docker. | In the provisioning window, and to refresh images later. |
| `ingest-repos.sh` | Extracts or copies source trees into `volumes/opengrok/src` for OpenGrok to index. Offline. | To add or update code on `grok.lab`. |
| `gpu-setup.sh` | Detects the host GPU (`lspci`/`/dev/dri`), reports which driver + container toolkit each vendor needs, and prints the matching `--profile ai-*`. Read-only by default; `--install-nvidia-ct` installs the NVIDIA Container Toolkit on Debian/Ubuntu. | On a fresh server before starting an Ollama GPU profile. |
| `test.sh` | End-to-end smoke test of every service (DNS, TLS chain, HTTP, step-ca, WebDAV/SMB, MinIO, sessions; GitLab/Mattermost when the `full-lab` profile is up). Exits non-zero on any failure. | After install, a restore, or an image bump. |
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
                                          # passwords, keep LAB_DOMAIN=lab

# runtime dirs (bind mounts, git-ignored); a few need specific ownership
mkdir -p volumes/{caddy/data,caddy/config,stepca,technitium,filebrowser,minio,share,sist2,convertx,privatebin,vaultwarden,code,term,opengrok/src,opengrok/data,opengrok/etc}
mkdir -p volumes/gitlab/{config,logs,data} volumes/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes} volumes/mattermost-db   # full-lab profile (harmless if unused)
mkdir -p volumes/ollama volumes/open-webui                                     # ai-* profiles (harmless if unused)
sudo chown 1000:1000  volumes/stepca         # step-ca runs as uid 1000
sudo chown -R 2000:2000 volumes/mattermost   # mattermost runs as uid 2000
sudo chown 100:101    volumes/share          # samba/webdav write as uid 100 (smbuser)
sudo chown 65534:82   volumes/privatebin     # privatebin's php-fpm runs as uid 65534, gid 82
# (OpenGrok chowns volumes/opengrok/src to uid 1111 on boot, so leave that mount writable —
#  a :ro src makes the container exit.)

# build the custom images + pull the pinned prebuilts (needs internet — the air-gap prep window).
# build.sh also writes dist/*.tar.gz; for an air-gapped host, run build.sh on an online box, copy
# dist/ over, and `for f in dist/*.tar.gz; do docker load -i "$f"; done` in place of this line.
./build.sh

# bring it up and wire DNS + CA
docker compose up -d                          # add --profile full-lab for GitLab + Mattermost
./bootstrap.sh
```

`bootstrap.sh` creates the `lab` DNS zone, points `*.lab` + `lab` at `HOST_IP`, exports the
root CA to `./lab-root-ca.crt`, restarts Caddy to issue certs, and — when the `full-lab`
profile is up — seeds the Mattermost admin + default team. It is idempotent — re-run it any
time. HTTPS goes valid a few moments **after** bootstrap, not at `up` (step-ca needs the DNS
records to validate each name).

Verify, then onboard clients (see [Playbook → Onboard a client](Playbook.md#onboard-a-client)):

```bash
docker compose ps           # every service Up (GitLab, if enabled, migrates for minutes on first boot)
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

- **Every image is referenced by name and tag** (`<repo>:<tag>`), pinned to a specific
  version where upstream publishes one. Digest pins (`@sha256:…`) were dropped because
  `docker save`/`docker load` round-trips lose the image name when it was pulled by bare
  digest. Bump one with `docker pull <repo>:<tag>` and update the tag on the `image:` line.
- **`.env`, `lab-root-ca.crt`, and `volumes/` are git-ignored.** Keep `.env` and the CA in a
  password manager — they're not reproducible from git.
- **The trusted root lives in `volumes/stepca/`** (root + intermediate, their keys, and the key
  password) and is included in backups. Lose it and every client must re-trust a new root; to
  rebuild the stack while keeping it, see
  [Playbook → Preserve the root CA](Playbook.md#preserve-the-root-ca-across-a-rebuild).
- **Certs validate only for clients that trust the exported root CA** — inherent to a private
  TLD. A real domain + DNS-01 would yield publicly trusted certs instead.
- **`LAB_DOMAIN` is the only place the TLD is set.** It is interpolated into every `caddy:` and
  `homepage.*` label and read by `bootstrap.sh`; see [Playbook → Rename the TLD](Playbook.md#rename-the-tld).
