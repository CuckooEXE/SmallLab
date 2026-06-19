# `.lab` homelab stack

A single `docker compose` stack that gives a LAN its own `.lab` TLD with real, trusted
HTTPS, a dashboard, DNS, a universal package registry, object storage, a file share, and
a couple of offline tooling apps.

The cert story is the interesting part: **step-ca** runs an internal ACME CA and **Caddy
enrolls every site with it**, so there's exactly **one root to trust** on each client.
Technitium makes `*.lab` resolve to the host; `bootstrap.sh` wires DNS + the CA together.

> **Operating it:** day-two procedures — deploying the two servers from scratch, adding
> or removing a service, backup/restore, issuing a cert from the CA, adding DNS records —
> live in **[`Playbook.md`](Playbook.md)**.

## Services

| Service        | URL / address                                   | Host port(s)                 | What it is |
|----------------|-------------------------------------------------|------------------------------|------------|
| **Caddy**      | terminates all `https://*.lab`                  | `80`, `443` (tcp+udp)        | [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) — config from labels; gets certs from step-ca over ACME |
| **step-ca**    | `https://ca.lab:9000`                           | `9000`                       | [Smallstep](https://smallstep.com/docs/step-ca/) internal ACME CA — the one root every client trusts |
| **Homepage**   | `https://home.lab`                              | via Caddy                    | dashboard; auto-discovers services from container labels |
| **Technitium** | `https://dns.lab` (console)                     | `53/udp`, `53/tcp`, `127.0.0.1:5380` | [DNS server](https://technitium.com/dns/), authoritative for `*.lab`, forwards the rest |
| **Forgejo**    | `https://packages.lab`                          | via Caddy                    | [Forgejo](https://forgejo.org) Git forge + universal package registry — Docker/OCI, npm, PyPI, Maven, Cargo, … ; one host serves UI, REST API **and** `/v2/` |
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
| **Uptime Kuma**| `https://status.lab`                            | via Caddy                    | uptime / status + TLS-expiry monitoring |

Host-bound ports (`53`, `445`, `139`, `9000`) bind to `${HOST_IP}` only, so they don't
collide with `systemd-resolved` on `127.0.0.53` or a host smbd. Caddy binds `0.0.0.0`.

## Repository layout

```text
compose.yaml          # root: project name, shared networks, `include:` of the files below
compose/              # one file per service -- caddy.yaml, step-ca.yaml, technitium.yaml, ...
config/               # checked-in config the services read
  homepage/           #   dashboard config (+ files Homepage regenerates, git-ignored)
  filebrowser/        #   settings.json
  nginx/              #   WebDAV nginx.conf (mounted into the official nginx image)
volumes/              # runtime state -- bind mounts, git-ignored, NOT checked in
  caddy/ stepca/ technitium/ forgejo/ filebrowser/ minio/ share/
bootstrap.sh          # post-`up` DNS + CA + Forgejo wiring (idempotent)
.env                  # secrets + HOST_IP + LAB_DOMAIN (git-ignored; copy from .env.example)
backup/               # pull-based backup tooling (runs on the backup server)
Playbook.md           # day-two operations
test.sh               # end-to-end smoke test of every service
```

`docker compose` auto-discovers `compose.yaml` and merges every file under `compose/`
via `include:`. Paths inside an included file resolve **relative to that file**, which is
why they point at `../config/...` and `../volumes/...`. Each service keeps its runtime
state under `volumes/<service>/`, so all stateful data is one git-ignored tree.

## Quick start

```bash
# 1. secrets / host IP
cp .env.example .env
$EDITOR .env          # set HOST_IP to this box, change the change-me passwords

# 2. on a FRESH host, create the runtime dirs (bind mounts, git-ignored). Most
#    services run as root; three don't: own those to match before first `up`.
mkdir -p volumes/{caddy/data,caddy/config,stepca,technitium,forgejo,filebrowser,minio,share,privatebin,vaultwarden,uptime-kuma}
sudo chown 1000:1000  volumes/stepca     # step-ca runs as uid 1000
sudo chown 1000:1000  volumes/forgejo    # forgejo runs as uid 1000 (git)
sudo chown 100:101    volumes/share      # samba/webdav write as uid 100 (smbuser)
sudo chown 65534:82   volumes/privatebin # privatebin's php-fpm runs as uid 65534, gid 82

# 3. bring it up  (run from this dir; it finds compose.yaml + .env automatically)
docker compose up -d

# 4. configure DNS + export the root CA + kick Caddy to issue certs + set up Forgejo
./bootstrap.sh
```

`bootstrap.sh` waits for Technitium, creates the `lab` zone, points `*.lab` and `lab`
at `HOST_IP`, exports step-ca's root to `./lab-root-ca.crt`, restarts Caddy so it issues
certs, and creates the Forgejo admin user + public packages org. It's idempotent.

> **Cert timing:** HTTPS goes valid a few moments *after* `bootstrap.sh` runs, not at
> `up`. step-ca validates each `*.lab` name over HTTP-01, which needs the DNS records
> that bootstrap creates. If a site shows a cert error right after `up`, run bootstrap
> (or `docker compose restart caddy`) and give it ~30s.

## Client setup (once per machine that uses the lab)

Two things on each client: **resolve `*.lab`** and **trust the root CA** so HTTPS
doesn't warn. `192.168.1.171` below is the lab host (`HOST_IP` from `.env`).

### Trust the root CA

`bootstrap.sh` wrote `lab-root-ca.crt` next to the compose file — copy it to the client, then:

```bash
# Linux
sudo cp lab-root-ca.crt /usr/local/share/ca-certificates/lab-ca.crt && sudo update-ca-certificates
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain lab-root-ca.crt
# Windows (elevated)
certutil -addstore -f Root lab-root-ca.crt
```

Linux/macOS browsers use the system store; **Firefox has its own** — import it there too.
Docker needs the CA as well to push to Forgejo's registry (see [Using Forgejo](#using-forgejo-packages)).

### Resolve `*.lab`

Simplest: point the machine's (or router's) resolver at `192.168.1.171`. Technitium is
authoritative for `*.lab` and forwards everything else to `1.1.1.1` / `9.9.9.9` — so the
box's *entire* DNS runs through the lab host.

To keep your normal resolver and send **only `*.lab`** to the lab, use split DNS — pure
client config, nothing changes on the server. (A second `nameserver` line in `resolv.conf`
does **not** do this: multiple `nameserver`s are failover across *all* lookups, not
per-domain routing. You need a resolver that understands per-domain rules.)

- **Linux + systemd-resolved** (active when `resolvectl status` shows `resolv.conf mode:
  stub`). `~lab` is a routing-only domain — `*.lab` goes to the lab and isn't added as a
  search suffix:
  ```bash
  IFACE=$(ip route get 192.168.1.171 | grep -oP 'dev \K\S+')
  resolvectl dns "$IFACE" 192.168.1.171 && resolvectl domain "$IFACE" '~lab'   # runtime only
  ```
  Persist it on the managing connection — NetworkManager:
  `nmcli con mod "<con>" +ipv4.dns 192.168.1.171 +ipv4.dns-search '~lab' && nmcli con up "<con>"`;
  or systemd-networkd: `DNS=192.168.1.171` + `Domains=~lab` in the link's `.network` file.

- **Linux without systemd-resolved** (local `dnsmasq` stub; works no matter how
  `resolv.conf` is managed — the one `server=/lab/` line is the whole feature):
  ```bash
  sudo apt install -y dnsmasq
  echo 'server=/lab/192.168.1.171' | sudo tee /etc/dnsmasq.d/lab.conf && sudo systemctl restart dnsmasq
  # then point resolv.conf at 127.0.0.1 if dnsmasq isn't already the system resolver
  ```

- **macOS** (per-domain resolver file):
  ```bash
  echo "nameserver 192.168.1.171" | sudo tee /etc/resolver/lab
  ```
  Verify with `ping -c1 home.lab` — `dig`/`nslookup` **bypass** `/etc/resolver`; use
  `ping`, `curl`, or `dscacheutil -q host -a name home.lab`.

- **Windows + NRPT** (elevated PowerShell; leading dot matches all `*.lab`):
  ```powershell
  Add-DnsClientNrptRule -Namespace ".lab" -NameServers "192.168.1.171"
  Get-DnsClientNrptRule | ? Namespace -eq ".lab" | Remove-DnsClientNrptRule   # undo
  ```
  Push fleet-wide via Group Policy: *Computer Config → Policies → Windows Settings → Name
  Resolution Policy*.

## How TLS works (step-ca)

- step-ca auto-initializes a PKI on first boot (root + intermediate + an ACME
  provisioner named `acme`), persisted in `volumes/stepca/`.
- Caddy is configured **globally** (labels on the caddy container) with
  `acme_ca https://step-ca:9000/acme/acme/directory` and `acme_ca_root` pointed at
  step-ca's root (shared into Caddy read-only). No per-site `tls internal`.
- Other machines/devices/scripts can use the **same** CA directly at
  `https://ca.lab:9000/acme/acme/directory` (any ACME client, mTLS, SSH certs, …).
- **Cert lifetime is 90 days** (`bootstrap.sh` sets the ACME provisioner's
  `defaultTLSCertDuration`/`maxTLSCertDuration` to `2160h`; Caddy auto-renews at ~2/3
  life). Override with `STEPCA_CERT_TTL=720h ./bootstrap.sh`.

Issuing a cert by hand from the CA (for a non-Caddy host or device) is in
[`Playbook.md`](Playbook.md#issue-a-cert-from-the-ca).

## Using Forgejo (packages)

Forgejo at `https://packages.lab` is a Git forge with a built-in universal package
registry — a Docker/OCI registry plus PyPI, npm, Maven, Cargo, NuGet, Go, Helm, RubyGems,
Debian, RPM, … — all on one host, free, no license. **`bootstrap.sh` does the first-run
setup**: it creates the admin user (the shared `LAB_USER` / `LAB_PASSWORD` from
`.env`) and a **public** org named after `LAB_DOMAIN`, so anonymous pull/download works the
moment the stack is up. Packages are created on first push — there's no per-format repo to
pre-create. Uploads authenticate as the admin (or a token you mint in the UI under *Settings
→ Applications*); a public org's packages download anonymously.

Docker verifies registry TLS strictly, so trust the CA, then push with a login and pull
anonymously:

```bash
sudo mkdir -p /etc/docker/certs.d/packages.lab
sudo cp lab-root-ca.crt /etc/docker/certs.d/packages.lab/ca.crt

docker login packages.lab                              # admin creds or a token (push needs auth)
docker tag alpine packages.lab/lab/alpine:latest       # packages.lab/<org>/<image>
docker push packages.lab/lab/alpine:latest
docker pull packages.lab/lab/alpine:latest             # public org -> no login needed
```

PyPI (note the `/api/packages/<org>/pypi` base):

```bash
twine upload --repository-url https://packages.lab/api/packages/lab/pypi -u labadmin dist/*
pip install --index-url https://packages.lab/api/packages/lab/pypi/simple <pkg>   # anonymous
```

The per-format endpoints (npm, Maven, Cargo, …) are documented at
[Forgejo packages](https://forgejo.org/docs/latest/user/packages/); they all hang off
`https://packages.lab/api/packages/<org>/`.

> **Anonymous access:** download/pull works because the org is **public**. Uploads always
> authenticate. Change the admin password in the UI afterward and mirror it in `.env` so a
> re-run of `bootstrap.sh` keeps working.

## Using object storage (MinIO)

- Console: `https://s3-console.lab`  (login = the shared `LAB_USER` / `LAB_PASSWORD`)
- S3 endpoint: `https://s3.lab`

```bash
mc alias set lab https://s3.lab "$LAB_USER" "$LAB_PASSWORD"
mc mb lab/artifacts
aws --endpoint-url https://s3.lab s3 cp ./file s3://artifacts/   # any S3 SDK works
```

The image is pinned to the last release that ships a full admin console; swap to
`minio/minio` in `compose/minio.yaml` if you only need the S3 API + the `mc` CLI.

## Using the file share

The share is **passwordless** — anyone on the LAN gets guest read/write. No SMB
credentials.

```bash
# Linux
sudo mount -t cifs //files.lab/lab /mnt/lab -o guest,vers=3.0
# Windows (cmd) -- see the guest caveat below before this works
net use Z: \\files.lab\lab
```

> **Windows guest caveat:** Windows 10/11 block unauthenticated guest SMB by default
> ("you can't access this shared folder because your organization's security policies
> block unauthenticated guest access"). To allow it, enable insecure guest logons:
> `reg add HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f`
> (or the equivalent Group Policy: *Computer Config → Admin Templates → Network →
> Lanman Workstation → Enable insecure guest logons*). macOS/Linux just connect as guest.

Files also show up at `https://files.lab` (filebrowser) — **no login**, it drops you
straight into the file view.

## Using the file share over HTTP (curl)

`dav.lab` is an nginx face on the **same `volumes/share` tree**, so you can read and write
files with nothing but curl — no SMB, no client config, no auth. Files it writes are owned
exactly like Samba's (`smbuser`, `0664`), so SMB, FileBrowser and curl all see each other's
files.

```bash
# PUT -- upload to an exact path (missing parent dirs are auto-created)
curl -T ./report.pdf https://dav.lab/reports/2026/report.pdf

# PUT to a directory (trailing slash) -- curl appends the local filename for you
curl -T ./report.pdf https://dav.lab/reports/2026/

# GET -- download a file, or browse the HTML directory listing
curl -O https://dav.lab/reports/2026/report.pdf
curl    https://dav.lab/reports/2026/

# DELETE -- remove a file (or an empty directory)
curl -X DELETE https://dav.lab/reports/2026/report.pdf

# MKCOL -- make a directory
curl -X MKCOL https://dav.lab/reports/2027/
```

> **It's `dav.lab`, not `files.lab`** — `files.lab` is FileBrowser's web UI. To move this
> HTTP API onto a different name, edit the `caddy:` label on the `webdav` service in
> `compose/webdav.yaml`.

nginx's built-in WebDAV module handles `PUT`/`DELETE`/`MKCOL`/`COPY`/`MOVE`; `GET`/`HEAD`
serve files and HTML directory listings (`autoindex`). **`POST` is not supported.**

## Backups

Every 3 hours, `rsync` copies the stack's `volumes/` tree into a new dated directory, with
unchanged files hardlinked to the previous backup (`rsync --link-dest`) so many snapshots
cost about one copy plus deltas. A prune keeps the snapshot nearest each interval (3h … 3
months) and deletes anything older than 3 months. Each snapshot is a plain, browsable copy.

```bash
# recovery on a new host: rsync a snapshot back into volumes/, then start the stack
./backup/lab-restore.sh list                  # pick a snapshot
sudo ./backup/lab-restore.sh restore latest   # -> the repo's volumes/ (stop the stack first)
docker compose up -d && ./bootstrap.sh
```

Backups run hot (no container downtime); set `PAUSE_CONTAINERS=1` for a guaranteed
consistent copy of the embedded databases (a brief freeze, not a restart). Setup, the
retention curve, and disaster recovery are in [`backup/README.md`](backup/README.md) and
[`Playbook.md`](Playbook.md#backups).

## How the TLD stays DRY

`LAB_DOMAIN` in `.env` is interpolated into every `caddy:` *and* `homepage.*` container
label **and** read by `bootstrap.sh`. To rename the TLD, change that one variable, then
`docker compose up -d --force-recreate && ./bootstrap.sh`. Nothing else hardcodes the TLD.

The dashboard is built from **Docker-label discovery** — each container carries
`homepage.*` labels that Homepage reads off the socket (`config/homepage/docker.yaml`), so
there's no service list to hand-maintain. Homepage writes its full config on first boot
with *live* demo entries, so `services.yaml` and `bookmarks.yaml` are committed as empty
`[]` to suppress them, and `docker.yaml` is mandatory (its generated default is commented
out → discovery silently no-ops). Everything else under `config/homepage/` is regenerated
and gitignored via a whitelist.

## Common tasks

```bash
docker compose ps                              # status
docker compose logs -f caddy                   # follow one service (drop the name for all)
docker compose up -d                           # start / apply config changes
docker compose down                            # stop everything (volumes/ data is kept)
docker compose pull && docker compose up -d    # update images
docker compose restart caddy                   # bounce one service
docker compose restart webdav                  # apply a config/nginx/nginx.conf change
```

## Notes & caveats

- **Every image is pinned by digest** (`@sha256:…`, the exact builds smoke-tested here);
  the readable tag/version is in the trailing comment on each `image:` line. To bump one:
  `docker pull <repo>:<tag>` then swap in the new digest from
  `docker image inspect <repo>:<tag> --format '{{index .RepoDigests 0}}'`.
- **`.env` holds secrets** and is git-ignored; so are `lab-root-ca.crt` and everything
  under `volumes/`.
- **The CA you trust lives in `volumes/stepca/`** (step-ca's root), not in Caddy. Don't
  delete that directory or every client has to re-trust a new root — back it up.
- **Certs only validate for clients that trust the exported root CA** — inherent to a
  private TLD. A real domain + DNS-01 would get you publicly-trusted certs instead.
