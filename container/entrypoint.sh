#!/bin/bash
# PID 1 for the kubeflare container.
#
# Ordering matters: the status server binds :8080 first, because Cloudflare treats
# the container as ready only once defaultPort accepts connections, and k3s takes
# 30-60s to come up. Then k3s, then (optionally) cloudflared.
set -u

LOG_DIR=/var/log/kubeflare
mkdir -p "$LOG_DIR"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

log() { echo "[entrypoint $(date -u +%T)] $*" | tee -a "$LOG_DIR/entrypoint.log"; }

# ---------------------------------------------------------------- status server
python3 /status-server.py >>"$LOG_DIR/status.log" 2>&1 &
STATUS_PID=$!
log "status server pid=$STATUS_PID on :8080"

# ---------------------------------------------------------------- host prep
# Pod networking needs forwarding. We hold CAP_NET_ADMIN and /proc/sys is writable,
# so this is a plain sysctl write rather than anything exotic.
for s in net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1; do
  sysctl -w "$s" >>"$LOG_DIR/entrypoint.log" 2>&1 && log "sysctl $s ok" || log "sysctl $s FAILED"
done
# br_netfilter is what makes kube-proxy's iptables rules apply to bridged pod
# traffic. It may be built in, loadable, or absent; k3s copes without it on a
# single node, so this is best-effort.
modprobe br_netfilter 2>>"$LOG_DIR/entrypoint.log" && log "br_netfilter loaded" || log "br_netfilter not loadable (ok on single node)"
sysctl -w net.bridge.bridge-nf-call-iptables=1 >>"$LOG_DIR/entrypoint.log" 2>&1 || true

NODE_NAME="${NODE_NAME:-cf-$(hostname)}"
TUNNEL_HOSTNAME="${TUNNEL_HOSTNAME:-}"

# The guest's primary interface is cfeth0, observed stable at 10.0.0.1/24.
# Detect it anyway so a platform change degrades to a log line, not a broken
# cluster. Everything that must dodge ClusterIP (coredns, local-path, kubelet
# --cluster-dns) is pointed at this address.
NODE_IP=$(ip -4 -o addr show cfeth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [ -z "$NODE_IP" ]; then
  NODE_IP=10.0.0.1
  log "cfeth0 not found; assuming NODE_IP=$NODE_IP"
else
  log "node ip $NODE_IP (cfeth0)"
fi

# ---------------------------------------------------------------- durable state
# Litestream replicates kine's SQLite DB to R2 and restores it on boot, so the
# cluster survives the ephemeral disk. Enabled only when all the secrets are
# present; otherwise the cluster rebuilds from scratch on every boot as before.
#
# The DB alone is not identity. k3s encrypts its bootstrap data (CA certs, SA
# signing key, credential files) INTO the datastore, keyed by the join token —
# so K3S_TOKEN must be a fixed secret or a restored DB is undecryptable. The
# agent's node password lives OUTSIDE the DB but is validated against an
# immutable in-cluster secret named after the node, so it is seeded from
# K3S_NODE_PASSWORD and the node name is pinned (container hostnames are not
# contractual across instances).
LITESTREAM_ENABLED=""
if [ -n "${LITESTREAM_ACCESS_KEY_ID:-}" ] && [ -n "${LITESTREAM_SECRET_ACCESS_KEY:-}" ] \
   && [ -n "${R2_ENDPOINT:-}" ] && [ -n "${R2_BUCKET:-}" ]; then
  if [ -z "${K3S_TOKEN:-}" ] || [ -z "${K3S_NODE_PASSWORD:-}" ]; then
    log "litestream: R2 secrets present but K3S_TOKEN/K3S_NODE_PASSWORD missing; staying ephemeral"
  else
    LITESTREAM_ENABLED=yes
  fi
fi

K3S_DB=/var/lib/rancher/k3s/server/db/state.db
DATASTORE_ARGS=()
if [ -n "$LITESTREAM_ENABLED" ]; then
  NODE_NAME=kubeflare
  # kine's litestream mode (kine >= 0.16.1, vendored in this k3s) disables its
  # own WAL checkpointing and startup VACUUM so litestream can own the WAL.
  DATASTORE_ARGS=(--datastore-endpoint=litestream://)

  mkdir -p /etc/rancher/node "$(dirname "$K3S_DB")"
  printf '%s' "$K3S_NODE_PASSWORD" > /etc/rancher/node/password
  chmod 600 /etc/rancher/node/password

  # Restore semantics: -if-db-not-exists makes in-place k3s restarts a no-op;
  # -if-replica-exists exits 0 on a genuinely empty bucket (true first boot).
  # Any OTHER failure must abort the container: starting k3s with a fresh DB
  # while a replica exists would mint a new cluster AND poison the replica.
  restored=""
  for attempt in 1 2 3 4 5; do
    if litestream restore -config /etc/litestream.yml \
         -if-db-not-exists -if-replica-exists "$K3S_DB" \
         >>"$LOG_DIR/litestream.log" 2>&1; then
      restored=yes; break
    fi
    log "litestream restore attempt $attempt failed; retrying (see litestream.log)"
    sleep $((attempt * 2))
  done
  if [ -z "$restored" ]; then
    log "FATAL: could not restore or verify the R2 replica; refusing to start a fresh cluster over it"
    exit 1
  fi
  log "litestream: restore step complete (node=$NODE_NAME)"
fi

SAN_ARGS=(--tls-san 127.0.0.1 --tls-san localhost)
[ -n "$TUNNEL_HOSTNAME" ] && SAN_ARGS+=(--tls-san "$TUNNEL_HOSTNAME")

# Flannel's default vxlan backend is fatal here: the Firecracker kernel returns
# "operation not supported" creating the vxlan device, and k3s treats flannel
# exiting as a shutdown request. host-gw needs no vxlan device — on a single node
# it is just a route plus the cni0 bridge, so real pod networking still works.
# Set to "none" to drop CNI entirely and run hostNetwork-only pods.
FLANNEL_BACKEND="${FLANNEL_BACKEND:-host-gw}"
NET_ARGS=(--flannel-backend="$FLANNEL_BACKEND")
if [ "$FLANNEL_BACKEND" = "none" ]; then
  NET_ARGS+=(--disable-network-policy)
fi

# kube-proxy's iptables mode is fatal on this kernel. Its KUBE-FORWARD chain
# includes an nfacct-based counter rule:
#   -m conntrack --ctstate INVALID -m nfacct --nfacct-name ct_state_invalid_dropped_pkts -j DROP
# and the Cloudflare Firecracker kernel has no xt_nfacct extension, so:
#   "Extension nfacct revision 0 not supported, missing kernel module?"
#   "RULE_APPEND failed (No such file or directory): rule in chain KUBE-FORWARD"
# iptables-restore is transactional, so that one rule fails the entire sync and
# kube-proxy programs NO service rules at all — ClusterIP is dead, which kills
# coredns (it cannot reach kubernetes.default) and therefore all cluster DNS.
# The nftables proxy backend does not use xt_nfacct at all.
PROXY_MODE="${KUBE_PROXY_MODE:-nftables}"
if [ "$PROXY_MODE" != "iptables" ]; then
  NET_ARGS+=(--kube-proxy-arg="proxy-mode=$PROXY_MODE")
fi

# Cluster DNS without kube-proxy: pods get the node IP as their nameserver,
# where the vendored hostNetwork coredns (manifests/coredns.yaml) listens.
# The default (a ClusterIP, 10.43.0.10) is unroutable until svcproxy is up, and
# DNS has to work before that.
#
# k3s's own --cluster-dns is documented as needing an address inside the service
# CIDR, which the node IP is not; going through --kubelet-arg sets the kubelet
# field directly and is verified working (pods resolve cluster + internet names).
# NodeLocal DNSCache does the same thing upstream with a link-local address.
NET_ARGS+=(--kubelet-arg=cluster-dns="$NODE_IP")

# ---------------------------------------------------------------- k3s
start_k3s() {
  log "starting k3s server (node=$NODE_NAME, flannel=$FLANNEL_BACKEND, litestream=${LITESTREAM_ENABLED:-no})"
  # coredns and local-storage are disabled in favour of the vendored copies in
  # /manifests: the packaged ones talk to the apiserver via the
  # kubernetes.default ClusterIP and never become ready here. Disabling (rather
  # than live-patching) matters because k3s's addon reconciler restores the
  # packaged manifests on every start.
  #
  # None of the array values contain whitespace, so flattening with [*] into
  # litestream's -exec string is safe.
  # --disable-kube-proxy: no backend can program this kernel (FINDINGS §5.2);
  # svcproxy below implements ClusterIP in userspace instead, and a half-failed
  # kube-proxy sync would only leave stray nft tables around.
  K3S_CMD="/usr/local/bin/k3s server \
    --node-name $NODE_NAME \
    --disable traefik,servicelb,metrics-server,coredns,local-storage \
    --disable-kube-proxy \
    --write-kubeconfig-mode 644 \
    ${SAN_ARGS[*]} ${NET_ARGS[*]} ${DATASTORE_ARGS[*]:-} ${K3S_EXTRA_ARGS:-}"
  if [ -n "$LITESTREAM_ENABLED" ]; then
    # The fly.io pattern: litestream supervises k3s, exits when it exits, and
    # forwards signals — so the WAL is never left unreplicated while k3s runs
    # (kine's own checkpointing is off in litestream mode).
    litestream replicate -config /etc/litestream.yml -exec "$K3S_CMD" \
      >>"$LOG_DIR/k3s.log" 2>&1 &
    K3S_PID=$!
  else
    $K3S_CMD >>"$LOG_DIR/k3s.log" 2>&1 &
    K3S_PID=$!
  fi
  log "k3s pid=$K3S_PID"
}
start_k3s

# ---------------------------------------------------------------- kubectl proxy
# The Worker cannot pass raw TLS through to the apiserver on 6443, but it can
# forward plain HTTP. `kubectl proxy` terminates the apiserver's TLS locally and
# re-exposes the same API over HTTP, using the node's own admin credentials — so
# the Worker becomes a usable kubectl endpoint without any tunnel at all.
# Access is gated by a shared secret the Worker checks; see src/index.ts.
KPROXY_PID=""
start_kproxy() {
  for _ in $(seq 1 120); do
    if /usr/local/bin/k3s kubectl get --raw /readyz >/dev/null 2>&1; then
      # --api-prefix matches the Worker's /k8s route so the Worker can forward the
      # original Request object untouched. Rewriting the URL would mean building a
      # new Request, which loses the Upgrade semantics kubectl exec needs.
      # kubectl proxy ships a default --reject-paths that blocks pods/exec and
      # pods/attach outright (a 403 from the proxy, not from Cloudflare). Clearing
      # it is what makes `kubectl exec` work over this path.
      /usr/local/bin/k3s kubectl proxy --port=8001 --address=0.0.0.0 \
        --accept-hosts='.*' --accept-paths='.*' --reject-paths='' \
        --api-prefix=/k8s/ \
        >>"$LOG_DIR/kubectl-proxy.log" 2>&1 &
      KPROXY_PID=$!
      log "kubectl proxy pid=$KPROXY_PID on :8001"
      return
    fi
    sleep 5
  done
  log "kubectl proxy not started: apiserver never ready"
}
start_kproxy &

# ---------------------------------------------------------------- svcproxy
# Userspace ClusterIP: binds every Service's ClusterIP directly via an AnyIP
# local route on the service CIDR and proxies TCP/UDP to ready endpoints. This
# is what makes ClusterIP (and therefore most real workloads) function on a
# kernel where every kube-proxy backend is missing something. Self-supervising:
# the subshell restarts it if it exits.
(
  for _ in $(seq 1 120); do
    if /usr/local/bin/k3s kubectl get --raw /readyz >/dev/null 2>&1; then
      log "starting svcproxy"
      while true; do
        /usr/local/bin/kubeflare-svcproxy \
          --kubeconfig /etc/rancher/k3s/k3s.yaml \
          --service-cidr 10.43.0.0/16 \
          >>"$LOG_DIR/svcproxy.log" 2>&1
        log "svcproxy exited (see svcproxy.log); restarting in 5s"
        sleep 5
      done
    fi
    sleep 5
  done
  log "svcproxy not started: apiserver never ready"
) &

# ---------------------------------------------------------------- cloudflared
CFD_PID=""
start_cloudflared() {
  if [ -n "${TUNNEL_TOKEN:-}" ]; then
    log "starting cloudflared (token present)"
    # http2 rather than the default quic: outbound UDP is not guaranteed here,
    # and http2 keeps the tunnel on TCP 443.
    /usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 \
      run --token "$TUNNEL_TOKEN" >>"$LOG_DIR/cloudflared.log" 2>&1 &
    CFD_PID=$!
    log "cloudflared pid=$CFD_PID"
  else
    log "no TUNNEL_TOKEN, skipping cloudflared"
  fi
}
start_cloudflared

# ---------------------------------------------------------------- manifests
# Cluster add-ons (coredns, local-path storage) plus the demo workload, applied
# once the API server is serving. /manifests is baked into the image read-only;
# render the __NODE_IP__ placeholder first.
RENDERED=/run/kubeflare-manifests
mkdir -p "$RENDERED"
for f in /manifests/*.yaml; do
  sed "s/__NODE_IP__/$NODE_IP/g" "$f" > "$RENDERED/$(basename "$f")"
done
(
  for _ in $(seq 1 120); do
    if /usr/local/bin/k3s kubectl get --raw /readyz >/dev/null 2>&1; then
      # /readyz goes ok before the aggregated openapi endpoint is serving, and
      # client-side validation fetches openapi — hence --validate=false plus a retry.
      for attempt in $(seq 1 20); do
        if /usr/local/bin/k3s kubectl apply --validate=false -f "$RENDERED"/ \
             >>"$LOG_DIR/manifests.log" 2>&1; then
          log "manifests applied (attempt $attempt)"
          exit 0
        fi
        sleep 10
      done
      log "manifests FAILED after 20 attempts (see manifests.log)"
      exit 1
    fi
    sleep 5
  done
  log "apiserver never became ready within 600s"
) &

# ---------------------------------------------------------------- supervision
term() {
  log "SIGTERM received, shutting down"
  [ -n "${CFD_PID}" ] && kill "$CFD_PID" 2>/dev/null
  kill "$K3S_PID" 2>/dev/null
  # k3s needs a moment to tear down containerd cleanly.
  wait "$K3S_PID" 2>/dev/null
  kill "$STATUS_PID" 2>/dev/null
  exit 0
}
trap term SIGTERM SIGINT

# Restart children if they die; reap zombies via the wait below.
while true; do
  sleep 10 &
  wait -n $! 2>/dev/null
  if ! kill -0 "$K3S_PID" 2>/dev/null; then
    log "k3s exited (see k3s.log); restarting in 10s"
    sleep 10
    start_k3s
  fi
  if ! kill -0 "$STATUS_PID" 2>/dev/null; then
    log "status server exited; restarting"
    python3 /status-server.py >>"$LOG_DIR/status.log" 2>&1 &
    STATUS_PID=$!
  fi
  if [ -n "${TUNNEL_TOKEN:-}" ] && [ -n "$CFD_PID" ] && ! kill -0 "$CFD_PID" 2>/dev/null; then
    log "cloudflared exited; restarting"
    start_cloudflared
  fi
done
