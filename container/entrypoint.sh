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

# Keep pods away from the unauthenticated control-plane ports on the host.
#
# This closes a real privilege escalation. `kubectl proxy` (:8001) holds the
# node's cluster-admin kubeconfig and authenticates nobody — the Worker in front
# of it is the only gate. The status server (:8080) serves /kubeconfig and
# /logs, equally ungated. Both bind 0.0.0.0, and svcproxy's AnyIP route makes
# the whole service CIDR host-local, so before these rules a pod could reach
# cluster-admin at 10.0.0.1:8001 *or at any 10.43.x.x:8001* — no token, no
# ServiceAccount, RBAC bypassed entirely. Confirmed by reading every kube-system
# Secret and minting ServiceAccount tokens from an unprivileged busybox pod.
#
# Matching on -i cni0 rather than a source CIDR so a pod cannot spoof its way
# out. The Worker's traffic arrives on the external interface, not cni0, so the
# real API path is unaffected.
#
# Nothing that worked is lost: because these ports are bound on 0.0.0.0, a
# Service on 8001 or 8080 could never be bound by svcproxy anyway. The proper
# fix is to bind both listeners to the node IP only (as coredns already does,
# which is why the kube-dns ClusterIP on :53 works) — that needs the Cloudflare
# readiness path re-verified, so it is deliberately not done here.
harden_local_ports() {
  for p in 8001 8080; do
    iptables -C INPUT -i cni0 -p tcp --dport "$p" -j DROP 2>/dev/null \
      || iptables -I INPUT -i cni0 -p tcp --dport "$p" -j DROP 2>/dev/null
  done
}
# cni0 does not exist yet — flannel creates it after k3s starts. iptables
# accepts a rule naming an absent interface and matches once it appears, and the
# supervisor re-asserts these anyway.
harden_local_ports && log "pod->host :8001/:8080 blocked (cluster-admin proxy, dashboard)" \
  || log "WARNING: could not install INPUT guards for :8001/:8080"

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

# ---------------------------------------------------------------- juicefs (R2 PVs)
# JuiceFS gives PersistentVolumes real durability: a POSIX filesystem mounted on
# the host at $JFS_MOUNT whose file data is objects in R2 and whose inode tree is
# a local SQLite DB. local-path-provisioner hands out subdirectories of it through
# the juicefs-r2 StorageClass (manifests-optional/juicefs-storage.yaml).
#
# Strictly an extension of the litestream feature, and not only by convention:
# the metadata DB is the filesystem. Losing it on the ephemeral disk would leave
# the R2 objects unreadable AND leave the bucket non-empty, which is exactly the
# state `juicefs format` refuses to touch. So no litestream, no JuiceFS.
#
# Everything below is best-effort. k3s must come up whether or not any of it
# works, so every failure path here ends in "log it and leave JUICEFS_MOUNTED
# empty", never in exit.
JFS_MOUNT=/mnt/juicefs
JFS_PV_DIR="$JFS_MOUNT/pvcs"
JFS_META_DB=/var/lib/kubeflare/jfs-meta.db
JFS_CACHE=/var/lib/kubeflare/jfs-cache
JFS_NAME=kubeflare
JFS_SUP_PID=""
JUICEFS_MOUNTED=""

JUICEFS_ENABLED=""
if [ -n "${R2_BUCKET_JFS:-}" ]; then
  if [ -n "$LITESTREAM_ENABLED" ]; then
    JUICEFS_ENABLED=yes
  else
    log "juicefs: R2_BUCKET_JFS set but durable state is off; skipping (metadata would not survive the disk)"
  fi
else
  log "juicefs: no R2_BUCKET_JFS, skipping R2-backed volumes"
fi

if [ -n "$JUICEFS_ENABLED" ]; then
  mkdir -p "$(dirname "$JFS_META_DB")" "$JFS_CACHE" "$JFS_MOUNT"

  # Ordering: restore the metadata BEFORE deciding whether to format. A
  # successful restore that produces no file is litestream's way of saying the
  # replica is genuinely empty (-if-replica-exists only swallows
  # ErrTxNotAvailable; a 403 on the bucket is a non-zero exit), so file-exists
  # afterwards is a trustworthy "this volume already exists" signal.
  #
  # Unlike the k3s DB, a failed restore here is not fatal — but it MUST NOT fall
  # through to format either: formatting on top of a replica we merely failed to
  # read would mint a second filesystem over the first one's objects.
  jfs_restored=""
  for attempt in 1 2 3; do
    if litestream restore -config /etc/litestream.yml \
         -if-db-not-exists -if-replica-exists "$JFS_META_DB" \
         >>"$LOG_DIR/litestream.log" 2>&1; then
      jfs_restored=yes; break
    fi
    log "juicefs: metadata restore attempt $attempt failed; retrying (see litestream.log)"
    sleep $((attempt * 2))
  done
  if [ -z "$jfs_restored" ]; then
    log "juicefs: metadata restore failed; NOT formatting over an unread replica — R2 volumes stay off"
    JUICEFS_ENABLED=""
  fi
fi

if [ -n "$JUICEFS_ENABLED" ]; then
  # ACCESS_KEY/SECRET_KEY are juicefs's own env var names; only `format` and
  # `config` read them, because format stores the keys inside the metadata and
  # `mount` uses those. Set per command rather than exported so they stay out of
  # k3s's environment — and as a shell assignment prefix rather than via env(1),
  # which would put them in argv where the dashboard's process list can see them.
  #
  # AWS_REGION: the s3 driver derives no region from a non-AWS endpoint and would
  # otherwise sign with us-east-1. R2 wants "auto", same as litestream's config.
  if [ ! -f "$JFS_META_DB" ]; then
    # First boot only. format checks the bucket is empty and does a
    # write/read/delete probe, so a token that does not cover this bucket fails
    # here with a logged 403 rather than hanging or silently writing nowhere.
    #
    # --trash-days 0: `juicefs gc` cannot run against R2 (its object listing is
    # not lexicographically ordered), so there must be no second class of data
    # that is invisible in the filesystem yet still billed. Deleting a PVC frees
    # the R2 objects immediately and irreversibly; the StorageClass reclaimPolicy
    # is the only safety net.
    #
    # --no-update is redundant given the file-exists guard and kept anyway: it
    # makes format a no-op on an already-formatted volume, so a wrong guess about
    # the guard cannot silently rewrite a live volume's settings.
    log "juicefs: formatting volume $JFS_NAME on $R2_BUCKET_JFS (first boot)"
    if ACCESS_KEY="$LITESTREAM_ACCESS_KEY_ID" \
       SECRET_KEY="$LITESTREAM_SECRET_ACCESS_KEY" \
       AWS_REGION=auto \
       juicefs format \
         --storage s3 \
         --bucket "${R2_ENDPOINT}/${R2_BUCKET_JFS}" \
         --trash-days 0 \
         --no-update \
         "sqlite3://${JFS_META_DB}" "$JFS_NAME" \
         >>"$LOG_DIR/juicefs.log" 2>&1; then
      log "juicefs: format ok"
    else
      log "juicefs: format FAILED (see juicefs.log); R2 volumes stay off"
      JUICEFS_ENABLED=""
    fi
  else
    # format stores the object-store credentials inside the metadata DB, so a
    # restored volume still carries whatever key it was created with. Push the
    # current ones in, or a rotated R2 token would 403 on every upload for ever
    # while litestream (which reads its keys from the environment) kept working.
    # Best-effort: if this fails the stored keys are probably still valid.
    AWS_REGION=auto juicefs config --yes \
      --access-key "$LITESTREAM_ACCESS_KEY_ID" \
      --secret-key "$LITESTREAM_SECRET_ACCESS_KEY" \
      "sqlite3://${JFS_META_DB}" >>"$LOG_DIR/juicefs.log" 2>&1 \
      || log "juicefs: could not refresh stored credentials (see juicefs.log)"
  fi
fi

# Supervised like svcproxy: the subshell restarts the client if it dies.
start_juicefs() {
  (
    while true; do
      # A client that died leaves its FUSE mount attached with every operation
      # returning ENOTCONN, and mounting over that fails. Detach lazily first —
      # lazily because pods may still hold open fds on the dead mount.
      umount -l "$JFS_MOUNT" 2>/dev/null
      # --backup-meta 0 is mandatory on R2: the automatic metadata dump rotates
      # old copies via ListObjects, and R2 returns keys in no particular order,
      # so the rotation misbehaves. litestream (litestream.yml) is the metadata
      # backup instead. The same listing quirk is why juicefs gc/fsck/sync/
      # destroy do not work against this volume at all.
      #
      # No --writeback. It acknowledges writes as soon as they hit the local
      # cache dir, which is on the disk that gets wiped on every sleep, rollout
      # and eviction — precisely the data we are trying not to lose. Without it a
      # successful fsync means the blocks are in R2, at the cost of R2 PUT
      # latency per fsync.
      #
      # --cache-size is in MiB and defaults to 100 GiB, which is nonsense on a
      # 16 GB disk already shared with containerd images and kine. 3 GiB plus a
      # 20% free-space floor leaves room for both. Cache loss is harmless: it is
      # a read cache only, refilled from R2.
      #
      # allow_other is not passed: juicefs sets it automatically when it runs as
      # root, and it is what lets non-root containers read their own volumes.
      AWS_REGION=auto juicefs mount "sqlite3://${JFS_META_DB}" "$JFS_MOUNT" \
        --backup-meta 0 \
        --cache-dir "$JFS_CACHE" \
        --cache-size 3072 \
        --free-space-ratio 0.2 \
        --no-usage-report \
        >>"$LOG_DIR/juicefs.log" 2>&1
      log "juicefs mount exited (see juicefs.log); restarting in 10s"
      sleep 10
    done
  ) &
  JFS_SUP_PID=$!
  log "juicefs supervisor pid=$JFS_SUP_PID"
}

if [ -n "$JUICEFS_ENABLED" ]; then
  start_juicefs
  # Wait for the mount before k3s starts. kubelet resolves hostPath directories
  # at pod-start time, so a mount that arrives late would not be an error — but
  # the PV parent directory below has to be created ON the filesystem, not on the
  # ephemeral disk underneath it, and that is only safe once it is mounted.
  # Read /proc/self/mounts rather than shelling out: this is PID 1, so it is the
  # host mount table.
  for _ in $(seq 1 60); do
    # The line looks like: JuiceFS:kubeflare /mnt/juicefs fuse.juicefs rw,...
    if grep -qF " $JFS_MOUNT fuse" /proc/self/mounts; then
      JUICEFS_MOUNTED=yes; break
    fi
    sleep 1
  done
  if [ -n "$JUICEFS_MOUNTED" ]; then
    mkdir -p "$JFS_PV_DIR"
    log "juicefs: mounted at $JFS_MOUNT, PV root $JFS_PV_DIR"
  else
    log "juicefs: mount did not appear within 60s (see juicefs.log); R2 volumes stay off"
  fi
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

# ---------------------------------------------------------------- image mirror
# Point containerd at the R2-backed pull-through registry (the separate
# kubeflare-registry Worker) instead of Docker Hub. This has to be written
# BEFORE k3s starts: k3s renders containerd's config from registries.yaml once,
# at startup.
#
# Why it matters here specifically: every cold wake starts with an empty
# containerd store, so the images are pulled again from scratch. Serving them
# from R2 is faster, free (no R2 egress fee), and immune to Docker Hub's
# anonymous per-IP rate limit — which a shared-egress puller hits constantly.
#
# containerd always appends the default upstream endpoint after the mirrors, so
# an unreachable or misconfigured mirror degrades to a slow pull, not a broken
# cluster. That is why this is best-effort and never fatal.
if [ -n "${REGISTRY_MIRROR_URL:-}" ]; then
  mirror_host="${REGISTRY_MIRROR_URL#https://}"; mirror_host="${mirror_host#http://}"
  mkdir -p /etc/rancher/k3s
  {
    echo "mirrors:"
    echo "  docker.io:"
    echo "    endpoint:"
    echo "      - \"$REGISTRY_MIRROR_URL\""
    if [ -n "${REGISTRY_MIRROR_USERNAME:-}" ] && [ -n "${REGISTRY_MIRROR_PASSWORD:-}" ]; then
      echo "configs:"
      echo "  \"$mirror_host\":"
      echo "    auth:"
      echo "      username: \"$REGISTRY_MIRROR_USERNAME\""
      echo "      password: \"$REGISTRY_MIRROR_PASSWORD\""
    fi
  } > /etc/rancher/k3s/registries.yaml
  chmod 600 /etc/rancher/k3s/registries.yaml
  log "image mirror: docker.io -> $mirror_host (auth: $([ -n "${REGISTRY_MIRROR_USERNAME:-}" ] && echo yes || echo no))"
else
  log "no REGISTRY_MIRROR_URL, pulling images straight from Docker Hub"
fi

# ---------------------------------------------------------------- k3s
start_k3s() {
  log "starting k3s server (node=$NODE_NAME, flannel=$FLANNEL_BACKEND, litestream=${LITESTREAM_ENABLED:-no}, juicefs=${JUICEFS_MOUNTED:-no})"
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
# /manifests-optional is only applied when its precondition holds. The juicefs-r2
# StorageClass must not exist without the mount behind it: local-path's helper pod
# hostPaths its volume's parent with DirectoryOrCreate, so provisioning against a
# missing mount would quietly land PVs on the ephemeral disk under a name that
# promises R2.
if [ -n "$JUICEFS_MOUNTED" ]; then
  sed "s/__NODE_IP__/$NODE_IP/g" /manifests-optional/juicefs-storage.yaml \
    > "$RENDERED/juicefs-storage.yaml"
fi
(
  for _ in $(seq 1 120); do
    if /usr/local/bin/k3s kubectl get --raw /readyz >/dev/null 2>&1; then
      # /readyz goes ok before the aggregated openapi endpoint is serving, and
      # client-side validation fetches openapi — hence --validate=false plus a retry.
      for attempt in $(seq 1 20); do
        if /usr/local/bin/k3s kubectl apply --validate=false -f "$RENDERED"/ \
             >>"$LOG_DIR/manifests.log" 2>&1; then
          log "manifests applied (attempt $attempt)"
          # Not applying juicefs-storage.yaml is not enough to keep the class
          # away: a datastore restored from R2 still carries whatever
          # StorageClasses a previous boot created. So the invariant is enforced
          # from both ends — the class exists if and only if the mount does.
          if [ -z "$JUICEFS_MOUNTED" ]; then
            /usr/local/bin/k3s kubectl delete storageclass juicefs-r2 \
              --ignore-not-found >>"$LOG_DIR/manifests.log" 2>&1
          fi
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
  # JuiceFS goes last, and only after k3s: unmounting while pods still hold the
  # filesystem open would fail, and the supervisor has to be shot first or it
  # would remount whatever we just unmounted. Anything fsynced is already in R2;
  # this is about flushing what wasn't.
  if [ -n "$JFS_SUP_PID" ]; then
    kill "$JFS_SUP_PID" 2>/dev/null
    umount "$JFS_MOUNT" 2>/dev/null || umount -l "$JFS_MOUNT" 2>/dev/null
  fi
  kill "$STATUS_PID" 2>/dev/null
  exit 0
}
trap term SIGTERM SIGINT

# Restart children if they die; reap zombies via the wait below.
while true; do
  sleep 10 &
  wait -n $! 2>/dev/null
  # Re-assert the pod->host port guards. They are installed before cni0 exists,
  # and a k3s restart or any CNI teardown can take the chain with it; an
  # idempotent -C/-I costs nothing and losing them means losing cluster-admin.
  harden_local_ports
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
