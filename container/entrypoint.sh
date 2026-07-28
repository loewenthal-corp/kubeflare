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

# ---------------------------------------------------------------- k3s
start_k3s() {
  log "starting k3s server (node=$NODE_NAME, flannel=$FLANNEL_BACKEND, sans=${TUNNEL_HOSTNAME:-none})"
  /usr/local/bin/k3s server \
    --node-name "$NODE_NAME" \
    --disable traefik,servicelb,metrics-server \
    --write-kubeconfig-mode 644 \
    "${SAN_ARGS[@]}" \
    "${NET_ARGS[@]}" \
    ${K3S_EXTRA_ARGS:-} \
    >>"$LOG_DIR/k3s.log" 2>&1 &
  K3S_PID=$!
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

# ---------------------------------------------------------------- demo workload
# Applied once the API server is serving, so the dashboard has something to show.
(
  for _ in $(seq 1 120); do
    if /usr/local/bin/k3s kubectl get --raw /readyz >/dev/null 2>&1; then
      # /readyz goes ok before the aggregated openapi endpoint is serving, and
      # client-side validation fetches openapi — hence --validate=false plus a retry.
      for attempt in $(seq 1 20); do
        if /usr/local/bin/k3s kubectl apply --validate=false -f /manifests/ \
             >>"$LOG_DIR/manifests.log" 2>&1; then
          log "demo manifests applied (attempt $attempt)"
          exit 0
        fi
        sleep 10
      done
      log "demo manifests FAILED after 20 attempts (see manifests.log)"
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
