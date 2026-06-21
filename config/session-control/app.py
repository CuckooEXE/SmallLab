#!/usr/bin/env python3
"""
session-control -- a tiny control plane for on-demand, per-session containers.

ONE generic service drives every "kind" of session (code-server workspaces,
ttyd terminals, ...). The kind-specific bits live entirely in a JSON config file
(CONTROL_FILE); the code below is kind-agnostic. Two compose services run this
same app.py with different configs:

  code.lab     -> code.json     -> code-server sessions at <name>.code.lab
  terminal.lab -> terminal.json -> ttyd terminals     at <name>.terminal.lab

It lists, creates, resumes, and deletes per-session containers. Each session gets
its own subdomain (routed live by caddy-docker-proxy off the labels we set), a
profile (a pre-built image with a baked toolchain -- see build.sh), and
a persistent bind-mounted directory.

PROFILES
--------
A profile is a pre-built image. The client picks a profile by NAME; we map that
name to an image via the config. The image string is therefore always server-side
and never client-supplied.

PERSISTENCE
-----------
Only one directory per session is bind-mounted (volumes/<kind>/<name>/<subdir>),
so it lands in the rsync backup. The rest of the container's writable layer is
preserved across stop/resume (docker stop/start, not rm) and wiped on delete.

SECURITY (this endpoint is intentionally UNAUTHENTICATED -- LAN-trust model)
---------------------------------------------------------------------------
  * No shell, ever. We talk to the Docker Engine API over its unix socket with
    JSON bodies -- there is no command string for input to be injected into.
  * Strict name allowlist (NAME_RE): `[a-z0-9-]`, <=31 chars. That one rule makes
    the name safe everywhere it is used (container name, subdomain, on-disk path,
    labels). Anything else -> 400.
  * Path traversal closed twice: the name can't contain `/` or `.`, AND we assert
    the resolved session path stays under DATA_DIR before any mkdir / rmtree.
  * Image is server-side only (from the config) -- clients send a profile name.
  * Destructive ops only ever touch containers carrying OUR managed label, looked
    up by name -- never an arbitrary id from the client.

The docker socket is root-equivalent; when auth is added to the stack, these
services should be first behind it (and consider a docker-socket-proxy).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import sys
import urllib.parse
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# --- configuration (from the environment; see compose/{code,term}-control.yaml)
LAB_DOMAIN = os.environ.get("LAB_DOMAIN", "lab")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8000"))
DOCKER_SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
CADDY_NETWORK = os.environ.get("CADDY_NETWORK", "caddy")
CONTROL_FILE = os.environ.get("CONTROL_FILE", "/app/code.json")
# Our own view of volumes/<kind> (bind-mounted in). We mkdir/chown session dirs
# here; the *host* path for those same dirs is discovered at startup below.
DATA_DIR = os.environ.get("DATA_DIR", "/data/sessions")

MANAGED_LABEL = "lab.managed"   # value comes from the config (per-kind)

# DNS-label-safe, lowercase, <=31 chars. The whole security model leans on this.
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")

CFG: dict = {}        # parsed CONTROL_FILE
HOST_DATA_DIR = ""    # host path backing DATA_DIR; filled at startup


# --- Docker Engine API over the unix socket ---------------------------------
class _UnixHTTPConnection(HTTPConnection):
    """http.client speaking to a unix socket instead of TCP."""

    def __init__(self, sock_path: str):
        super().__init__("localhost", timeout=60)  # numeric -> usable by settimeout
        self._sock_path = sock_path

    def connect(self) -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._sock_path)
        self.sock = s


class DockerError(RuntimeError):
    def __init__(self, status: int, body: str):
        super().__init__(f"docker API {status}: {body}")
        self.status = status
        self.body = body


def docker(method: str, path: str, body: object | None = None) -> object:
    """One Docker Engine API call. Returns parsed JSON (or None on empty body)."""
    conn = _UnixHTTPConnection(DOCKER_SOCK)
    headers = {"Host": "localhost", "Accept": "application/json"}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        if resp.status >= 400:
            raise DockerError(resp.status, raw.decode("utf-8", "replace"))
        return json.loads(raw) if raw else None
    finally:
        conn.close()


def _filters(d: dict) -> str:
    return urllib.parse.quote(json.dumps(d))


# --- startup: config + host-path discovery ----------------------------------
def load_config() -> dict:
    with open(CONTROL_FILE, encoding="utf-8") as fh:
        cfg = json.load(fh)
    for key in ("subdomain_base", "container_prefix", "managed_value", "session", "profiles"):
        if key not in cfg:
            raise RuntimeError(f"{CONTROL_FILE} is missing required key {key!r}")
    if not cfg["profiles"]:
        raise RuntimeError(f"{CONTROL_FILE} defines no profiles")
    for name, spec in cfg["profiles"].items():
        if not NAME_RE.match(name):
            raise RuntimeError(f"profile name {name!r} is not a valid label")
        if not spec.get("image"):
            raise RuntimeError(f"profile {name!r} has no image")
    sess = cfg["session"]
    for key in ("internal_port", "bind_subdir", "mount_target"):
        if key not in sess:
            raise RuntimeError(f"{CONTROL_FILE} session is missing required key {key!r}")
    return cfg


def discover_host_data_dir() -> str:
    """
    Find the *host* absolute path backing our DATA_DIR mount, so the per-session
    bind mounts we ask the daemon to create point at real host paths (the daemon
    resolves binds on the host, not inside this container). We inspect our own
    container (hostname == short id) and read the Source of the DATA_DIR mount.
    Falls back to $SESSIONS_HOST_DIR if explicitly set.
    """
    override = os.environ.get("SESSIONS_HOST_DIR")
    if override:
        return override.rstrip("/")
    me = socket.gethostname()
    for c in docker("GET", "/containers/json?all=1"):
        if not c.get("Id", "").startswith(me):
            continue
        for m in c.get("Mounts", []):
            if m.get("Destination") == DATA_DIR and m.get("Source"):
                return m["Source"].rstrip("/")
    raise RuntimeError(
        f"could not discover the host path of {DATA_DIR}; "
        "set SESSIONS_HOST_DIR explicitly"
    )


# --- session model -----------------------------------------------------------
def _safe_name(name: str) -> str:
    if not NAME_RE.match(name):
        raise ValueError(
            "name must match ^[a-z0-9][a-z0-9-]{0,30}$ (lowercase letters, "
            "digits, dashes; max 31 chars)"
        )
    return name


def _session_dir(name: str) -> str:
    """Session dir for `name`, with a belt-and-suspenders traversal check."""
    base = os.path.realpath(DATA_DIR)
    path = os.path.realpath(os.path.join(base, name))
    if os.path.dirname(path) != base:
        raise ValueError("refusing path outside the session root")
    return path


def _cname(name: str) -> str:
    return f"{CFG['container_prefix']}-{name}"


def _url(name: str) -> str:
    return f"https://{name}.{CFG['subdomain_base']}.{LAB_DOMAIN}"


def _container(name: str) -> dict | None:
    """Our session container for `name`, or None. Verified by our own label."""
    flt = _filters({
        "name": [f"^/{_cname(name)}$"],
        "label": [f"{MANAGED_LABEL}={CFG['managed_value']}"],
    })
    found = docker("GET", f"/containers/json?all=1&filters={flt}")
    return found[0] if found else None


def list_sessions() -> list[dict]:
    """Running/stopped session containers, merged with resumable on-disk dirs."""
    prefix = CFG["container_prefix"] + "-"
    flt = _filters({"label": [f"{MANAGED_LABEL}={CFG['managed_value']}"]})
    out: dict[str, dict] = {}
    for c in docker("GET", f"/containers/json?all=1&filters={flt}"):
        labels = c.get("Labels", {})
        cname = (c.get("Names") or ["/"])[0].lstrip("/")
        name = labels.get("lab.session") or (
            cname[len(prefix):] if cname.startswith(prefix) else cname
        )
        out[name] = {
            "name": name,
            "profile": labels.get("lab.profile", "?"),
            "state": c.get("State", "unknown"),   # running | exited | created
            "status": c.get("Status", ""),
            "url": _url(name),
            "exists": True,
        }
    try:
        for entry in os.listdir(DATA_DIR):
            if entry.startswith("_") or not NAME_RE.match(entry):
                continue
            if os.path.isdir(os.path.join(DATA_DIR, entry)):
                out.setdefault(entry, {
                    "name": entry, "profile": "?", "state": "stopped",
                    "status": "data on disk", "url": _url(entry), "exists": False,
                })
    except FileNotFoundError:
        pass
    return sorted(out.values(), key=lambda s: s["name"])


def create_or_resume(name: str, profile: str) -> dict:
    """Create a session from `profile`, or start it if it already exists."""
    _safe_name(name)
    profiles = CFG["profiles"]
    if profile not in profiles:
        raise ValueError(f"unknown profile {profile!r}; choose one of {sorted(profiles)}")

    existing = _container(name)
    if existing:
        if existing.get("State") != "running":
            docker("POST", f"/containers/{_cname(name)}/start")
        return {"name": name, "url": _url(name), "resumed": True}

    sess = CFG["session"]
    sdir = _session_dir(name)
    bindpath = os.path.join(sdir, sess["bind_subdir"])
    os.makedirs(bindpath, exist_ok=True)
    if sess.get("chown_uid") is not None:
        os.chown(sdir, sess["chown_uid"], sess["chown_gid"])
        os.chown(bindpath, sess["chown_uid"], sess["chown_gid"])

    spec = {
        "Image": profiles[profile]["image"],
        "Hostname": name,
        "Labels": {
            MANAGED_LABEL: CFG["managed_value"],
            "lab.session": name,
            "lab.profile": profile,
            "caddy": f"{name}.{CFG['subdomain_base']}.{LAB_DOMAIN}",
            "caddy.reverse_proxy": "{{upstreams %d}}" % sess["internal_port"],
            "homepage.group": CFG.get("homepage_group", "Sessions"),
            "homepage.name": name,
            "homepage.icon": CFG.get("homepage_icon", ""),
            "homepage.href": _url(name),
            "homepage.description": f"{CFG.get('homepage_description', 'session')} ({profile})",
            # Sort every session tile BELOW the control ("create") tile. Homepage orders a
            # group by weight ascending, so without this the unweighted session tiles default
            # to 0 and shove the create button (term/code-control, weight 1) to the bottom --
            # it then jumps around as sessions come and go. Keep this strictly above the
            # control tile's weight in compose/{term,code}-control.yaml.
            "homepage.weight": str(CFG.get("homepage_weight", 100)),
        },
        "HostConfig": {
            "Binds": [f"{HOST_DATA_DIR}/{name}/{sess['bind_subdir']}:{sess['mount_target']}"],
            "NetworkMode": CADDY_NETWORK,
            "RestartPolicy": {"Name": "unless-stopped"},
        },
    }
    if sess.get("entrypoint") is not None:
        spec["Entrypoint"] = sess["entrypoint"]
    if sess.get("cmd") is not None:
        spec["Cmd"] = sess["cmd"]
    if sess.get("user"):
        spec["User"] = sess["user"]

    docker("POST", f"/containers/create?name={_cname(name)}", spec)
    docker("POST", f"/containers/{_cname(name)}/start")
    return {"name": name, "url": _url(name), "resumed": False, "profile": profile}


def stop_session(name: str) -> dict:
    """Stop the container but keep its data (resumable)."""
    _safe_name(name)
    if not _container(name):
        raise KeyError(name)
    docker("POST", f"/containers/{_cname(name)}/stop?t=10")
    return {"name": name, "stopped": True}


def delete_session(name: str) -> dict:
    """Remove the container AND wipe its session volume."""
    _safe_name(name)
    if _container(name):
        docker("DELETE", f"/containers/{_cname(name)}?force=1")
    sdir = _session_dir(name)
    if os.path.isdir(sdir):
        shutil.rmtree(sdir)
    return {"name": name, "deleted": True}


# --- HTTP layer --------------------------------------------------------------
PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; {domain}</title>
<style>
 :root{{color-scheme:dark}}
 body{{font:15px/1.5 system-ui,sans-serif;margin:0;background:#11151c;color:#e6e9ef}}
 header{{padding:1.1rem 1.4rem;background:#0c0f14;border-bottom:1px solid #232a35}}
 header h1{{margin:0;font-size:1.15rem}} header p{{margin:.3rem 0 0;color:#8b94a3;font-size:.85rem}}
 main{{max-width:780px;margin:0 auto;padding:1.4rem}}
 form{{display:flex;gap:.6rem;margin:0 0 1.4rem;flex-wrap:wrap}}
 input,select{{padding:.55rem .7rem;background:#1a2029;border:1px solid #2c3543;border-radius:7px;color:#e6e9ef;font:inherit}}
 input{{flex:1;min-width:12rem}} input:invalid{{border-color:#b4452f}}
 button{{padding:.55rem .9rem;border:0;border-radius:7px;background:#3b82f6;color:#fff;font:inherit;cursor:pointer}}
 button.sec{{background:#2c3543}} button.danger{{background:#b4452f}}
 ul{{list-style:none;padding:0;margin:0}}
 li{{display:flex;align-items:center;gap:.7rem;padding:.7rem .8rem;border:1px solid #232a35;border-radius:9px;margin-bottom:.6rem;background:#161b23}}
 li .nm{{font-weight:600}} li .pf{{font-size:.72rem;color:#9aa4b2;background:#222a35;padding:.1rem .45rem;border-radius:5px}}
 li .st{{font-size:.78rem;color:#8b94a3}} li .sp{{flex:1}}
 .dot{{width:.6rem;height:.6rem;border-radius:50%;display:inline-block;margin-right:.4rem}}
 .run{{background:#37b24d}} .off{{background:#6b7280}}
 a.open{{text-decoration:none}} .empty{{color:#8b94a3;text-align:center;padding:2rem}}
 .err{{background:#3a1d18;border:1px solid #b4452f;color:#f3c1b6;padding:.6rem .8rem;border-radius:7px;margin-bottom:1rem;display:none}}
</style></head>
<body>
<header><h1>{title}</h1><p>{tagline}</p></header>
<main>
 <div class="err" id="err"></div>
 <form id="new" autocomplete="off">
  <input id="name" name="name" placeholder="new-session-name"
         pattern="[a-z0-9][a-z0-9-]{{0,30}}" maxlength="31" required
         title="lowercase letters, digits and dashes; max 31 chars">
  <select id="profile" title="profile"></select>
  <button type="submit">Create</button>
 </form>
 <ul id="list"><li class="empty">loading&hellip;</li></ul>
</main>
<script>
const $=s=>document.querySelector(s), list=$('#list'), err=$('#err');
function showErr(m){{err.textContent=m;err.style.display='block';setTimeout(()=>err.style.display='none',6000);}}
async function api(method,path,body){{
 const r=await fetch(path,{{method,headers:body?{{'Content-Type':'application/json'}}:{{}},body:body?JSON.stringify(body):null}});
 const t=await r.text(); let j={{}}; try{{j=t?JSON.parse(t):{{}}}}catch(e){{}}
 if(!r.ok) throw new Error(j.error||('HTTP '+r.status)); return j;
}}
function btn(t,c,fn){{const b=document.createElement('button');b.textContent=t;if(c)b.className=c;b.style.marginLeft='.4rem';b.onclick=fn;return b;}}
function row(s){{
 const li=document.createElement('li'), run=s.state==='running';
 li.innerHTML=`<span class="nm"><span class="dot ${{run?'run':'off'}}"></span>${{s.name}}</span>`+
   `<span class="pf">${{s.profile||'?'}}</span><span class="st">${{s.status||s.state}}</span><span class="sp"></span>`;
 const acts=document.createElement('span');
 if(run){{const a=document.createElement('a');a.className='open';a.href=s.url;a.target='_blank';
   a.innerHTML='<button>Open</button>';acts.append(a);
   acts.append(btn('Stop','sec',()=>act('POST','/api/sessions/'+s.name+'/stop')));
 }} else {{
   acts.append(btn('Resume','',()=>act('POST','/api/sessions',{{name:s.name}})));
 }}
 acts.append(btn('Delete','danger',()=>{{if(confirm('Delete '+s.name+' and wipe its files?'))act('DELETE','/api/sessions/'+s.name);}}));
 li.append(acts); return li;
}}
async function act(m,p,b){{try{{await api(m,p,b);await refresh();}}catch(e){{showErr(e.message);}}}}
async function loadProfiles(){{
 try{{const j=await api('GET','/api/profiles'); const sel=$('#profile');
  sel.innerHTML=''; j.profiles.forEach(p=>{{const o=document.createElement('option');
   o.value=p.name;o.textContent=p.name+(p.description?' — '+p.description:'');sel.append(o);}});
 }}catch(e){{showErr(e.message);}}
}}
async function refresh(){{
 try{{const j=await api('GET','/api/sessions');
  list.innerHTML=''; if(!j.sessions.length){{list.innerHTML='<li class="empty">no sessions yet</li>';return;}}
  j.sessions.forEach(s=>list.append(row(s)));
 }}catch(e){{showErr(e.message);}}
}}
$('#new').addEventListener('submit',async e=>{{e.preventDefault();
 const n=$('#name').value.trim(); if(!n)return;
 try{{const r=await api('POST','/api/sessions',{{name:n,profile:$('#profile').value}});
   $('#name').value='';await refresh();window.open(r.url,'_blank');}}catch(e){{showErr(e.message);}}
}});
loadProfiles(); refresh(); setInterval(refresh,5000);
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "session-control/1.0"
    protocol_version = "HTTP/1.1"

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, obj: object) -> None:
        self._send(status, json.dumps(obj).encode(), "application/json")

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            return {}
        if length > 64 * 1024:
            raise ValueError("request body too large")
        try:
            data = json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            raise ValueError("invalid JSON body")
        if not isinstance(data, dict):
            raise ValueError("expected a JSON object")
        return data

    def log_message(self, fmt: str, *args) -> None:
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()

    def do_GET(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            html = PAGE.format(
                title=CFG.get("title", "Sessions"),
                tagline=CFG.get("tagline", ""),
                domain=LAB_DOMAIN,
            )
            self._send(200, html.encode(), "text/html; charset=utf-8")
        elif path == "/healthz":
            self._json(200, {"ok": True})
        elif path == "/api/profiles":
            self._json(200, {"profiles": [
                {"name": n, "description": p.get("description", "")}
                for n, p in sorted(CFG["profiles"].items())
            ]})
        elif path == "/api/sessions":
            try:
                self._json(200, {"sessions": list_sessions()})
            except DockerError as e:
                self._json(502, {"error": f"docker: {e.body}"})
        else:
            self._json(404, {"error": "not found"})

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_POST(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        if path == "/api/sessions":
            self._lifecycle(lambda b: create_or_resume(
                b.get("name", ""), b.get("profile", "base")))
            return
        m = re.match(r"^/api/sessions/([^/]+)/stop$", path)
        if m:
            name = urllib.parse.unquote(m.group(1))
            self._lifecycle(lambda _b: stop_session(name), read_body=False)
            return
        self._json(404, {"error": "not found"})

    def do_DELETE(self) -> None:
        path = urllib.parse.urlparse(self.path).path
        m = re.match(r"^/api/sessions/([^/]+)$", path)
        if m:
            name = urllib.parse.unquote(m.group(1))
            self._lifecycle(lambda _b: delete_session(name), read_body=False)
            return
        self._json(404, {"error": "not found"})

    def _lifecycle(self, fn, read_body: bool = True) -> None:
        try:
            body = self._read_json() if read_body else {}
        except ValueError as e:
            self._json(400, {"error": str(e)})
            return
        try:
            self._json(200, fn(body))
        except ValueError as e:        # bad name / unknown profile / traversal
            self._json(400, {"error": str(e)})
        except KeyError as e:          # no such session
            self._json(404, {"error": f"no such session: {e.args[0]}"})
        except DockerError as e:
            self._json(502, {"error": f"docker: {e.body}"})


def main() -> int:
    global CFG, HOST_DATA_DIR
    try:
        CFG = load_config()
        HOST_DATA_DIR = discover_host_data_dir()
    except Exception as e:  # noqa: BLE001 -- fail loud at startup
        sys.stderr.write(f"FATAL: {e}\n")
        return 2
    sys.stdout.write(
        f"session-control: kind={CFG['subdomain_base']} domain={LAB_DOMAIN} "
        f"profiles={sorted(CFG['profiles'])} host_data_dir={HOST_DATA_DIR} :{LISTEN_PORT}\n"
    )
    sys.stdout.flush()
    httpd = ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
