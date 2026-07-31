# kubeflare — FULL k3s (server + agent, real kubelet, real containerd).
#
# The Phase 0 probe run on the deployed platform showed Cloudflare Containers are
# Firecracker microVMs where PID 1 is uid 0 with all 41 capabilities, no seccomp
# filter, full cgroup v2 delegation, /dev/net/tun, /dev/fuse and working netfilter.
# So none of the rootless contortions are needed: this runs stock k3s.
#
# NOTE: the build context is the REPO ROOT (wrangler.jsonc sets
# image_build_context), because svcproxy/ lives outside container/. Every COPY
# path here is therefore repo-relative.

# svcproxy: the userspace ClusterIP proxy (this kernel can run no kube-proxy
# backend — see docs/FINDINGS.md §5.2 and svcproxy/README.md).
FROM golang:1.26 AS svcproxy-build
WORKDIR /src
COPY svcproxy/ .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/kubeflare-svcproxy .

# lbcontroller: implements type: LoadBalancer by provisioning Cloudflare Tunnel
# public hostnames. Separate from svcproxy on purpose — this one needs a
# Cloudflare API token, and the dataplane should not.
FROM golang:1.26 AS lbcontroller-build
WORKDIR /src
COPY lbcontroller/ .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/kubeflare-lbcontroller .

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl iproute2 iptables python3 jq procps \
      mount util-linux ethtool socat conntrack kmod \
      nftables ipset \
      fuse3 \
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

# Litestream replicates kine's SQLite DB to R2 so the cluster survives the
# ephemeral disk. 0.5.x is the LTX rewrite; pin a recent patch release —
# restore-correctness fixes were still landing through 0.5.12.
ARG LITESTREAM_VERSION=0.5.15
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) ls_arch=x86_64 ;; \
      arm64) ls_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/litestream.tar.gz \
      "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-${LITESTREAM_VERSION}-linux-${ls_arch}.tar.gz"; \
    tar -C /usr/local/bin -xzf /tmp/litestream.tar.gz litestream; \
    rm /tmp/litestream.tar.gz; \
    /usr/local/bin/litestream version

# JuiceFS backs the optional juicefs-r2 StorageClass: a POSIX filesystem whose
# data lives in R2 and whose metadata is a local SQLite DB on the same litestream
# pipeline as kine's. Pinned, not "latest": the release asset URL has no /latest
# alias and 1.4.x is the current stable line.
#
# fuse3 above is belt and braces. JuiceFS sets go-fuse's DirectMount, so as root
# it mounts with mount(2) on /dev/fuse and needs no suid helper; fusermount3 is
# only the fallback path (and makes a manual `fusermount3 -u` possible).
ARG JUICEFS_VERSION=1.4.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) jfs_arch=amd64 ;; \
      arm64) jfs_arch=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/juicefs.tar.gz \
      "https://github.com/juicedata/juicefs/releases/download/v${JUICEFS_VERSION}/juicefs-${JUICEFS_VERSION}-linux-${jfs_arch}.tar.gz"; \
    tar -C /usr/local/bin -xzf /tmp/juicefs.tar.gz juicefs; \
    rm /tmp/juicefs.tar.gz; \
    /usr/local/bin/juicefs version

COPY --from=lbcontroller-build /out/kubeflare-lbcontroller /usr/local/bin/kubeflare-lbcontroller
COPY --from=svcproxy-build /out/kubeflare-svcproxy /usr/local/bin/kubeflare-svcproxy
COPY container/entrypoint.sh /entrypoint.sh
COPY container/status-server.py /status-server.py
COPY container/litestream.yml /etc/litestream.yml
COPY container/manifests/ /manifests/
# Applied only when the entrypoint has a live JuiceFS mount — a StorageClass
# whose backing filesystem is missing would provision PVs onto the ephemeral
# disk while claiming to be durable, so it must not exist unless the mount does.
COPY container/manifests-optional/ /manifests-optional/
RUN chmod +x /entrypoint.sh

# Bumped to force a new image digest when only config changed, so Cloudflare
# actually rolls a fresh instance instead of reusing the old one.
ARG KUBEFLARE_REBUILD=2
RUN echo "rebuild=$KUBEFLARE_REBUILD" > /etc/kubeflare-build

EXPOSE 8080
CMD ["/entrypoint.sh"]
