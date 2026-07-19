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
- [Run the full-lab profile (GitLab & Mattermost)](#run-the-full-lab-profile-gitlab--mattermost)
- [Run local LLMs (Ollama) with GPU or CPU](#run-local-llms-ollama-with-gpu-or-cpu)
- [Download and manage Ollama models](#download-and-manage-ollama-models)
- [Use object storage (MinIO)](#use-object-storage-minio)
- [Use the package registry (Nexus)](#use-the-package-registry-nexus)
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

Firefox keeps its own store — import it there too. git needs the CA to clone from GitLab over
HTTPS (see [Run the full-lab profile](#run-the-full-lab-profile-gitlab--mattermost)).

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
       image: <repo>:<tag>
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
     — skip the pull step below (it applies only to prebuilt images).

2. Add the file to `include:` in [`compose.yaml`](compose.yaml).
3. If it has state, create its bind-mount dir: `mkdir -p volumes/<name>` (chown to the image's
   uid if it runs non-root).
4. Pull the image: `docker pull <repo>:<tag>` (prefer a specific version tag over `latest`
   where upstream publishes one).
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

## Run the full-lab profile (GitLab & Mattermost)

**Description.** The opt-in heavy tier: GitLab CE (`gitlab.lab` — repos, issues, CI/CD, package
registries) and Mattermost team chat (`chat.lab`, plus its `mattermost-db` PostgreSQL sidecar).
Gated behind the `full-lab` compose profile, so a plain `docker compose up -d` never starts it.
**When to use.** The host has the headroom (GitLab alone wants ~4 GB RAM) and you want a full
forge and team chat in-lab.

```bash
# 1. runtime dirs, once (skip if created at install time)
mkdir -p volumes/gitlab/{config,logs,data} volumes/mattermost/{config,data,logs,plugins,client-plugins,bleve-indexes} volumes/mattermost-db
sudo chown -R 2000:2000 volumes/mattermost   # mattermost runs as uid 2000

# 2. start it alongside the running stack; seed the Mattermost admin + team
docker compose --profile full-lab up -d
docker compose logs -f gitlab                # first boot migrates for SEVERAL MINUTES
./bootstrap.sh                               # idempotent; seeds Mattermost (GitLab self-seeds)

# off again (data kept in volumes/):
docker compose --profile full-lab down gitlab mattermost mattermost-db
```

Logins: GitLab is the **fixed `root` user** / `LAB_PASSWORD` (seeded on first boot only —
change it in the UI afterward and mirror it in `.env`); Mattermost is `LAB_USER` /
`LAB_PASSWORD` in the team named after `LAB_DOMAIN`. Both self-signups are off — admins create
users.

Git over HTTPS (no ssh port is published; the client must trust the lab CA):

```bash
git config --global http."https://gitlab.lab/".sslCAInfo ~/lab-root-ca.crt
git clone https://gitlab.lab/<group>/<repo>.git      # auth: root or a token from the UI
```

GitLab's built-in package registries (PyPI, npm, Maven, …) hang off
`https://gitlab.lab/api/v4/projects/<id>/packages/` — see the
[GitLab package registry docs](https://docs.gitlab.com/user/packages/). The container registry
and CI runners are **not** wired up: enabling the registry needs a second vhost
(`registry_external_url` in `compose/gitlab.yaml`), and CI jobs need a `gitlab-runner`
container registered against `https://gitlab.lab`.

Mattermost admin tasks go through the System Console (`https://chat.lab` → System Console) or
`mmctl`, e.g. `docker compose --profile full-lab exec mattermost mmctl --local user create ...`.

---

## Run local LLMs (Ollama) with GPU or CPU

**Description.** Ollama LLM runtime (`ollama.lab` API) + Open WebUI (`ai.lab` chat + model
management). Opt-in and heavy, gated behind one **per-accelerator** compose profile.
**When to use.** You want local, offline inference. CPU works on any host with no setup; the
GPU profiles need a one-time host driver install.

**Drivers are not in the image.** A GPU's *kernel driver* (`nvidia.ko`, `amdgpu`, `i915`) lives
on the **host**; the Ollama image only carries the *userspace* runtime (CUDA/ROCm/oneAPI). So on
a fresh server you install the vendor stack on the host once, then start the matching profile.
`./gpu-setup.sh` detects the GPU and prints the exact steps.

```bash
# 0. runtime dirs, once (skip if created at install time)
mkdir -p volumes/ollama volumes/open-webui

# 1. see what this host needs and which profile to use (read-only)
./gpu-setup.sh
```

Then pick **exactly one** accelerator profile (running two would collide — both bind the
container name `ollama`):

```bash
docker compose --profile ai-cpu    up -d   # CPU only -- no drivers, works anywhere
docker compose --profile ai-nvidia up -d   # NVIDIA (CUDA)
docker compose --profile ai-amd    up -d   # AMD (ROCm)
docker compose --profile ai-intel  up -d   # Intel (EXPERIMENTAL -- IPEX-LLM, see caveat)
```

Per-vendor host setup (what `gpu-setup.sh` walks you through):

- **NVIDIA** — install the proprietary driver (`nvidia-smi` must work), then the **NVIDIA
  Container Toolkit** so containers can see the GPU: `sudo ./gpu-setup.sh --install-nvidia-ct`
  (Debian/Ubuntu; automates the toolkit repo + `nvidia-ctk runtime configure` + docker restart).
- **AMD** — install `amdgpu` + ROCm for your card
  ([ROCm install](https://rocm.docs.amd.com/projects/install-on-linux/)); ensure `/dev/kfd` and
  `/dev/dri` exist. Unsupported consumer cards fall back to CPU unless you set
  `HSA_OVERRIDE_GFX_VERSION` (uncomment it in `compose/ollama.yaml`).
- **Intel (experimental)** — mainline Ollama has **no** Intel GPU backend, so `ai-intel` uses
  Intel's IPEX-LLM build (a different image with a different bootstrap that lags mainline).
  Install Intel's compute runtime + Level-Zero on the host, set `DEVICE=iGPU` or `DEVICE=Arc` in
  `compose/ollama.yaml`, and verify the container's start command against current IPEX-LLM docs.

All four variants share `volumes/ollama`, so models you pull persist across an accelerator
switch. Pull and run models (Open WebUI can also do this from the browser):

```bash
docker compose exec ollama ollama pull llama3.2       # into the shared model volume
docker compose exec ollama ollama run  llama3.2 "hi"  # quick CLI test
curl https://ollama.lab/api/generate -d '{"model":"llama3.2","prompt":"hi","stream":false}' \
  --resolve ollama.lab:443:$HOST_IP --cacert lab-root-ca.crt
```

Confirm the GPU is actually in use (not a silent CPU fallback): `docker compose logs ollama`
should name the accelerator, and during a run `nvidia-smi` / `rocm-smi` / `intel_gpu_top` should
show load. Off again (data kept): `docker compose --profile ai-<...> down ollama open-webui`.

**Air-gap:** all four images are staged by `./build.sh` (the AMD and Intel images are large —
several GB each). Models themselves are **not** bundled; pull them during your online staging
window (`ollama pull ...` writes to `volumes/ollama`, which then rides along in backups).

---

## Download and manage Ollama models

**Description.** Pull models into the shared `volumes/ollama` store, import your own GGUFs, and
prune what you no longer need.
**When to use.** After the Ollama profile is up (see [Run local LLMs](#run-local-llms-ollama-with-gpu-or-cpu))
and you want to add, inspect, or remove models — including sideloading onto an air-gapped host.

**Pick a model that fits.** Browse the catalog at [ollama.com/library](https://ollama.com/library).
A name is `family:tag`, where the tag encodes size and/or quantization (`llama3.2:3b`,
`qwen2.5-coder:7b`, `mistral:7b-instruct-q4_K_M`); a bare `llama3.2` resolves to a default
tag. Rule of thumb: the model has to fit in **VRAM** on a GPU profile (or **RAM** on `ai-cpu`),
so a 7B at `q4_K_M` needs ~5–6 GB. Overshoot and Ollama spills to CPU or OOMs — check with
`docker compose logs ollama` after the first run.

Pull, list, inspect, and remove from the CLI (all write to the shared volume):

```bash
docker compose exec ollama ollama pull llama3.2:3b     # download into volumes/ollama
docker compose exec ollama ollama list                 # installed models + on-disk sizes
docker compose exec ollama ollama show llama3.2:3b     # params, context length, quant, license
docker compose exec ollama ollama run  llama3.2:3b "hi"  # quick smoke test
docker compose exec ollama ollama rm   llama3.2:3b     # reclaim the disk when done
```

From the browser: Open WebUI (`ai.lab`) → the model picker's **"Pull a model from Ollama.com"**
field (or **Admin → Settings → Models**) does the same pull; `WEBUI_AUTH=false` means it's open.

**Import an external GGUF** (e.g. a quant from HuggingFace not in the Ollama library). The host
dir `volumes/ollama` is mounted at `/root/.ollama` in the container, so drop the file there and
point a one-line Modelfile at it:

```bash
cp mymodel.Q4_K_M.gguf volumes/ollama/                                  # -> /root/.ollama/ inside
printf 'FROM /root/.ollama/mymodel.Q4_K_M.gguf\n' > volumes/ollama/Modelfile
docker compose exec ollama ollama create mymodel -f /root/.ollama/Modelfile
docker compose exec ollama ollama run mymodel "hi"
rm volumes/ollama/mymodel.Q4_K_M.gguf volumes/ollama/Modelfile          # Ollama copied it into its store
```

**Air-gap: sideload from an online host.** Models aren't bundled by `./build.sh`; pull them where
there's internet, then ship the shared store. Everything lives under `volumes/ollama/models`
(`blobs/` + `manifests/`), which merges cleanly:

```bash
# on an ONLINE host with the profile up:
docker compose exec ollama ollama pull llama3.2:3b
tar -C volumes -czf ollama-models.tgz ollama/models      # blobs + manifests only

# copy ollama-models.tgz to the air-gapped host, then there (stack up or down):
tar -C volumes -xzf ollama-models.tgz                    # merges into the shared store
docker compose exec ollama ollama list                   # confirm they appear
```

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

## Use the package registry (Nexus)

**Description.** [Sonatype Nexus Repository OSS](https://help.sonatype.com/en/sonatype-nexus-repository.html)
— the lab's Artifactory-style "push anything" store. Create **hosted** repos (host your own
packages), **proxy** repos (mirror/cache an upstream), and **group** repos (one URL fronting
several) for npm, PyPI, apt (Debian), raw (any file/tarball), Go, Maven, and more.
**When to use.** Publishing internal packages, or mirroring public ones so builds work offline.

**First boot (once).** Nexus runs as a fixed non-root uid `200`, so its data dir must be owned by
it before the stack comes up, then log in and take over the admin password:

```bash
mkdir -p volumes/nexus && sudo chown -R 200:200 volumes/nexus
docker compose up -d nexus            # first start takes ~1-2 min (DB init); packages.lab 502s until ready
# Log in at https://packages.lab as  admin / admin123  -> change the password to LAB_PASSWORD,
# mirror it in .env. (NEXUS_SECURITY_RANDOMPASSWORD=false sets that known initial password.)
```

Create repos under **Server administration → Repositories → Create repository** (or the REST API).
Each format is path-routed under `packages.lab/repository/<name>/`, so no compose change is ever
needed to add one. The pattern below is the same for every format: one **hosted** repo (you
publish to it), one **proxy** repo (mirrors/caches an upstream), and one **group** repo fronting
both (you consume from it — groups are read-only, so pull from the group, push to the hosted).
Nexus gates publishing by default, so every push authenticates as `LAB_USER` / `LAB_PASSWORD`.
Client setup per format:

```bash
# --- npm ---  create: npm-hosted (push), npm-proxy (registry.npmjs.org), npm-group (pull)
npm config set registry https://packages.lab/repository/npm-group/          # pull (hosted + proxy)
npm install <pkg>
npm login   --registry https://packages.lab/repository/npm-hosted/          # LAB_USER / LAB_PASSWORD
npm publish --registry https://packages.lab/repository/npm-hosted/          # push

# --- pip / PyPI ---  create: pypi-hosted (push), pypi-proxy (pypi.org), pypi-group (pull)
pip install --index-url https://packages.lab/repository/pypi-group/simple/ <pkg>          # pull
twine upload --repository-url https://packages.lab/repository/pypi-hosted/ \
  -u "$LAB_USER" -p "$LAB_PASSWORD" dist/*                                   # push (or put creds in ~/.pypirc)

# --- cargo (Rust) ---  create: cargo-hosted (push), cargo-proxy (crates.io), cargo-group (pull)
# ~/.cargo/config.toml -- the sparse+ prefix is REQUIRED:
#   [registries.lab]         index = "sparse+https://packages.lab/repository/cargo-group/"
#   [registries.lab-hosted]  index = "sparse+https://packages.lab/repository/cargo-hosted/"
#   [source.crates-io]       replace-with = "lab"        # resolve crates.io deps through Nexus
cargo build                                                                  # pull
export CARGO_REGISTRIES_LAB_HOSTED_TOKEN="Basic $(printf '%s' "$LAB_USER:$LAB_PASSWORD" | base64)"
cargo publish --registry lab-hosted                                          # push

# --- Go modules ---  create: go-hosted (push, needs Nexus >= 3.93), go-proxy (proxy.golang.org), go-group (pull)
printf 'machine packages.lab\nlogin %s\npassword %s\n' "$LAB_USER" "$LAB_PASSWORD" >> ~/.netrc && chmod 600 ~/.netrc
go env -w GOAUTH=netrc GOPROXY=https://packages.lab/repository/go-group/ GOSUMDB=off
go get github.com/you/module@v1.2.3                                          # pull
# push: PUT the module zip at the Go proxy layout <module>/@v/<version>.zip (Nexus reads go.mod from it):
curl -u "$LAB_USER:$LAB_PASSWORD" --upload-file module.zip \
  https://packages.lab/repository/go-hosted/github.com/you/module/@v/v1.2.3.zip

# --- raw (any file / tarball) ---  create: raw-hosted (push), raw-proxy (mirror an HTTP file tree), raw-group
curl -u "$LAB_USER:$LAB_PASSWORD" --upload-file ./artifact.tar.gz \
  https://packages.lab/repository/raw-hosted/dist/artifact.tar.gz           # push (path auto-created)
curl -O https://packages.lab/repository/raw-hosted/dist/artifact.tar.gz     # pull

# --- apt / Debian ---  create: apt-proxy (deb.debian.org/debian) and/or apt-hosted (needs a PGP signing key)
echo "deb https://packages.lab/repository/apt-proxy/ bookworm main" | sudo tee /etc/apt/sources.list.d/lab.list
sudo apt update                                                             # pull (upstream's signature verifies as-is)
# push a .deb to a hosted repo (create it with a generated GPG key; Nexus signs the METADATA, not the package):
curl -u "$LAB_USER:$LAB_PASSWORD" -H "Content-Type: multipart/form-data" \
  --data-binary @./mypkg_1.0_amd64.deb https://packages.lab/repository/apt-hosted/
# hosted-repo clients import that repo's public key, then add its <distribution>:
#   echo "deb https://packages.lab/repository/apt-hosted/ <distribution> main" | sudo tee /etc/apt/sources.list.d/lab-hosted.list

# --- yum / RPM ---  create: yum-hosted (push; set "Repodata Depth"), yum-proxy (a Rocky/Alma/EPEL mirror), yum-group
# pull: /etc/yum.repos.d/lab.repo -> [lab] baseurl=https://packages.lab/repository/yum-group/  enabled=1  gpgcheck=0
sudo dnf install <pkg>
curl -u "$LAB_USER:$LAB_PASSWORD" --upload-file ./mypkg-1.0-1.x86_64.rpm \
  https://packages.lab/repository/yum-hosted/mypkg-1.0-1.x86_64.rpm         # push (metadata rebuilds ~60s later)
```

**Docker / OCI (`docker.lab`).** Create a Docker **group** repo with an HTTP connector on **8082**
(that's the port `compose/nexus.yaml` maps to `docker.lab`), add a **hosted** member (your images)
and a **docker.io proxy** member (pull-through mirror), and set the group's **Writable repository**
to the hosted member — one endpoint then does both push and pull:

```bash
docker login docker.lab                                  # admin / your password (or grant anon the push privilege)
docker tag myapp:latest docker.lab/myapp:latest
docker push docker.lab/myapp:latest                      # -> hosted member
docker pull docker.lab/library/alpine:latest             # -> cached from docker.io via the proxy member
```

Clients must trust the lab root CA (`lab-root-ca.crt`) already — the Docker daemon uses the system
store, so no `insecure-registries` entry is needed once the CA is installed (see the setup steps).
GitLab's built-in registries (`gitlab.lab`, full-lab profile) still cover npm/PyPI/Maven tied to
projects; Nexus is the always-on, format-agnostic store that also does Debian mirrors, raw files,
and Docker.

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
MinIO, sessions; GitLab/Mattermost when the `full-lab` profile is up — skipped otherwise).
**When to use.** After install, a restore, or an image bump.

```bash
docker compose ps                 # all Up; GitLab (if enabled) migrates for minutes on first boot
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
