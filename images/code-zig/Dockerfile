# Zig workspace profile -- code-server + Zig toolchain + ZLS + the Zig extension.
#
# Built at staging (needs internet) by ../build.sh; referenced offline thereafter by the
# control plane (config/session-control/code.json -> lab/code-zig).
#
# ZLS is built FROM SOURCE with the zig we just installed -- this avoids depending
# on ZLS release asset URLs (their naming has churned across versions) and keeps the
# zig/ZLS versions in lockstep.
FROM codercom/code-server@sha256:9a7848dd2627158e3873f88bd8743807a4168e4d580f26ec0cbc132a9d9ee78e

# Keep these in lockstep (ZLS x.y tracks Zig x.y).
ARG ZIG_VERSION=0.13.0
ARG ZLS_VERSION=0.13.0

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xz-utils; \
    rm -rf /var/lib/apt/lists/*; \
    # Zig: relocatable tarball -> /opt/zig, on PATH via /usr/local/bin.
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -sf /opt/zig/zig /usr/local/bin/zig; \
    zig version; \
    # ZLS from source, pinned to the matching tag.
    git clone --depth 1 --branch "${ZLS_VERSION}" https://github.com/zigtools/zls /tmp/zls; \
    cd /tmp/zls; \
    zig build -Doptimize=ReleaseSafe; \
    install -m0755 zig-out/bin/zls /usr/local/bin/zls; \
    cd /; rm -rf /tmp/zls /root/.cache/zig; \
    zls --version

# Bake default settings into the image's user-data dir. Sessions do NOT bind-mount
# over this dir, so these defaults survive (only the project/ dir is mounted).
# Create the dir AS coder so the whole tree is coder-owned (running `install -d`
# as root leaves the parents root-owned -> code-server EACCES on extension install).
USER coder
RUN mkdir -p /home/coder/.local/share/code-server/User
COPY --chown=coder:coder settings.json /home/coder/.local/share/code-server/User/settings.json
RUN code-server --install-extension ziglang.vscode-zig
