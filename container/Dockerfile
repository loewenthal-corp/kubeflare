# kubeflare — FULL k3s (server + agent, real kubelet, real containerd).
#
# The Phase 0 probe run on the deployed platform showed Cloudflare Containers are
# Firecracker microVMs where PID 1 is uid 0 with all 41 capabilities, no seccomp
# filter, full cgroup v2 delegation, /dev/net/tun, /dev/fuse and working netfilter.
# So none of the rootless contortions are needed: this runs stock k3s.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 iptables python3 jq procps \
      mount util-linux ethtool socat conntrack kmod \
      nftables ipset \
    && rm -rf /var/lib/apt/lists/*

# k3s ships its own kubectl (`k3s kubectl`), so we do not install one separately.
# Pinned rather than resolved at build time: update.k3s.io answers the channel
# query with a 302 to the GitHub release page, not JSON, and the '+' in the tag
# has to be percent-encoded in the download path.
ARG K3S_VERSION=v1.36.2%2Bk3s1
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) k3s_bin=k3s;       cfd_arch=amd64 ;; \
      arm64) k3s_bin=k3s-arm64; cfd_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    echo "installing k3s ${K3S_VERSION} (${k3s_bin})"; \
    curl -fsSL -o /usr/local/bin/k3s \
      "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/${k3s_bin}"; \
    chmod +x /usr/local/bin/k3s; \
    curl -fsSL -o /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cfd_arch}"; \
    chmod +x /usr/local/bin/cloudflared; \
    /usr/local/bin/k3s --version

COPY entrypoint.sh /entrypoint.sh
COPY status-server.py /status-server.py
COPY manifests/ /manifests/
RUN chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/entrypoint.sh"]
