# Python workspace profile -- code-server + Python 3 + Pyright + Ruff.
#
# Built at staging (needs internet) by ../build.sh; referenced offline thereafter by the
# control plane (config/session-control/code.json -> lab/code-python).
#
# Extensions come from Open VSX (code-server's default registry); Microsoft's
# first-party Python extension is NOT on Open VSX, so we use the Pyright language
# server + Ruff, both of which are.
FROM codercom/code-server:4.125.0

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv; \
    rm -rf /var/lib/apt/lists/*; \
    python3 --version

# Create the user-data dir AS coder so the whole tree is coder-owned (running
# `install -d` as root leaves the parents root-owned -> code-server EACCES).
USER coder
RUN mkdir -p /home/coder/.local/share/code-server/User
COPY --chown=coder:coder settings.json /home/coder/.local/share/code-server/User/settings.json
RUN code-server --install-extension ms-pyright.pyright \
 && code-server --install-extension charliermarsh.ruff
