# Netutils terminal profile -- base shell + common network / recon CLI tools.
#
# Built at staging (needs internet) by ../build.sh; referenced offline thereafter by the
# control plane (config/session-control/terminal.json -> lab/term-netutils).
# Self-contained (FROM the ttyd base, not lab/term-base) so profiles have no build order.
FROM tsl0922/ttyd:latest

USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tmux vim less git curl ca-certificates iproute2 procps bash-completion \
        nmap tcpdump netcat-openbsd dnsutils iputils-ping socat jq openssl whois; \
    rm -rf /var/lib/apt/lists/*; \
    nmap --version | head -1
