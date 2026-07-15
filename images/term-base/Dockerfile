# Base terminal profile -- ttyd + tmux + a comfortable shell toolset.
#
# Built at staging (needs internet) by ../build.sh; referenced offline thereafter by the
# control plane (config/session-control/terminal.json -> lab/term-base).
#
# tmux is the key addition over the stock ttyd image: the control plane launches
# `ttyd tmux new -A -s main`, so reconnecting (or opening a second tab) reattaches the
# SAME session -> a shared, disconnect-surviving terminal.
FROM tsl0922/ttyd:latest

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tmux vim less git curl ca-certificates iproute2 procps bash-completion; \
    rm -rf /var/lib/apt/lists/*; \
    tmux -V
