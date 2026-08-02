# kubeflare-svcproxy

A userspace ClusterIP service proxy — a kube-proxy replacement for kernels
that cannot run **any** kube-proxy mode.

## Why this exists

kubeflare runs a real single-node k3s cluster inside a Cloudflare Container,
which is a Firecracker microVM with kernel `6.18.36-cloudflare-firecracker`
and no loadable module support. Every kube-proxy dataplane is dead on arrival
(all verified on the target kernel):

| Mode | Blocker |
| --- | --- |
| `iptables` | `xt_nfacct` is missing, so kube-proxy's rule sync fails hard; `xt_statistic` is also missing, so even with nfacct worked around, multi-endpoint services would poison the transactional `iptables-restore` |
| `nftables` | kernel lacks the `numgen` and `reject` nft expressions |
| `ipvs` | no IPVS support in the kernel |
| eBPF (Cilium etc.) | kernel built without BTF, so no CO-RE program loads |

What *does* work — also verified — is the kernel's AnyIP trick:

```
ip route replace local 10.43.0.0/16 dev lo
```

A route of type `local` makes every address in the service CIDR locally
bindable with a plain `bind()`. So instead of rewriting packets, this proxy
simply listens on every `ClusterIP:port` and forwards bytes in userspace.

## What it does

- Watches Services and EndpointSlices (`discovery.k8s.io/v1`) with client-go
  shared informers.
- For every service with a real ClusterIP (ClusterIP/NodePort/LoadBalancer;
  headless and ExternalName are skipped) and every TCP/UDP port, binds a
  listener on each IPv4 ClusterIP at the service port.
- **TCP**: accept → round-robin dial of a ready endpoint (up to 3 attempts,
  5s dial timeout) → bidirectional splice with half-close (`CloseWrite`)
  propagation.
- **UDP**: per-client-address sessions pinned to one backend, replies sourced
  from the ClusterIP socket, 30s idle expiry, 4096-session cap with
  least-recently-active eviction. DNS works through this.
- **`sessionAffinity: ClientIP`**: honoured for TCP and UDP, including
  `sessionAffinityConfig.clientIP.timeoutSeconds` (default 10800). See below.
- Endpoints come from EndpointSlices (`kubernetes.io/service-name` label),
  Ready condition only (nil counts as ready), slice ports matched to service
  ports by name — so the default `kubernetes` service (endpoint = host
  IP:6443) flows through the exact same path as everything else.
- Reconciles the listener set on every change. Endpoint-only changes swap the
  backend list atomically **without** restarting listeners (UDP sessions to
  removed backends are dropped immediately); IP/port/protocol changes are a
  stop+start of that one listener.
- A failed bind (route not up yet, host process squatting on the port) is
  retried every 15s. Per-listener errors never take the process down; the
  only fatal error is an unusable kubeconfig.
- Graceful shutdown on SIGTERM/SIGINT: closes all listeners, exits 0.

## Session affinity

`spec.sessionAffinity: ClientIP` pins a client to one backend for
`spec.sessionAffinityConfig.clientIP.timeoutSeconds` of idleness (the API
server's default is 10800, three hours).

- Pins are keyed on the **client IP alone**. Keying on `ip:port` would give
  every connection its own pin, which is the same as no affinity at all.
- Each listener keeps its own pin table, so affinity is per
  ClusterIP × port × protocol. One consequence differs from kube-proxy, which
  hangs affinity off the service port and shares it across paths: a client
  that reaches the same service on both its ClusterIP and its NodePort can be
  pinned to a different backend on each.
- A pin is revalidated on every use. It is honoured only while it is inside
  the timeout **and** its backend is still in the ready set; either failing
  re-pins that one client round-robin and leaves every other pin alone. An
  endpoint set change also prunes pins to departed backends eagerly, the same
  way UDP sessions are pruned.
- A failed dial drops the pin before retrying, so an affine client is not
  retried into the same unreachable backend `dialAttempts` times over.
- The table is capped at 4096 pins per listener and evicts the
  least-recently-active entry when full, plus a sweep every 60s. An
  uncapped map keyed by client IP is a memory leak with a hostile-client
  shape.
- TCP and UDP share one table per listener. UDP's own per-`ip:port` session
  table stays (replies must go back to the right source port); it just takes
  its backend from the affinity table, so all of one client's source ports
  land on that client's backend.
- With `sessionAffinity: None` the affinity table is bypassed entirely and
  selection is exactly the round-robin `endpointPool.pick` it always was.

Affinity is deliberately **not** part of the listener diff: changing it needs
no restart and does not invalidate the socket, so it is simply reapplied on
every reconcile pass and is a no-op unless it moved.

## How it's wired into kubeflare

k3s runs with `--disable-kube-proxy`. This binary runs as a plain host
process (root, host network namespace — same as k3s) from the container
entrypoint, once k3s has written its admin kubeconfig:

```
kubeflare-svcproxy \
  --kubeconfig /etc/rancher/k3s/k3s.yaml \
  --service-cidr 10.43.0.0/16
```

Those are the defaults, so a bare `kubeflare-svcproxy` is equivalent. Add
`-v` for debug logging (per-connection dials, endpoint-set changes).

Cluster facts assumed by the defaults: single node, node IP `10.0.0.1`, pod
CIDR `10.42.0.0/24`, service CIDR `10.43.0.0/16`.

Startup ordering: only the kubeconfig **file** must exist when the proxy
starts (an unreadable/unparsable kubeconfig is the one fatal error, exit 1).
The API server may still be booting — informers retry forever. The AnyIP
route is installed by the proxy itself at startup by shelling out to `ip`
(iproute2); pass `--setup-route=false` if the entrypoint owns the route. If
the route shows up late, listeners self-heal on their 15s bind retry. There
is no circular dependency on the `kubernetes` service: the k3s admin
kubeconfig points at `127.0.0.1:6443` directly.

### Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--kubeconfig` | `/etc/rancher/k3s/k3s.yaml` | kubeconfig with read access to Services and EndpointSlices |
| `--service-cidr` | `10.43.0.0/16` | CIDR installed as the AnyIP local route on `lo` |
| `--setup-route` | `true` | run `ip route replace local <cidr> dev lo` at startup |
| `--resync` | `0` | informer resync period (0: rely on watches) |
| `-v` | `false` | verbose (debug) logging |

## Build

```
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o kubeflare-svcproxy .
```

Pure Go, statically linked. The only runtime dependency is the `ip` command
for `--setup-route` (and it degrades to a logged error if missing).

## Limitations (v1)

- **No source-IP preservation.** Connections are re-originated in userspace,
  so backends see the node's address (node IP or CNI bridge IP), never the
  real client. Anything keyed on client IP — NetworkPolicy by source, DNS
  ACLs, app-level allowlists — sees the node instead.
- **No session affinity.** `sessionAffinity: ClientIP` is ignored (warned
  once per service).
- **No NodePorts.** NodePort/LoadBalancer services are served on their
  ClusterIP only; the node port itself is never opened.
- **No SCTP** (skipped with a log line). IPv4 only; IPv6 ClusterIPs are
  skipped.
- Userspace copy per connection: correctness over throughput. Fine for a
  single-node cluster; do not expect kube-proxy-grade numbers.
- No metrics yet (TODO: Prometheus).

## Manual test recipe

From inside the kubeflare container (host netns), with the proxy running:

```sh
# 1. AnyIP route present?
ip route show | grep '^local 10.43'

# 2. The default kubernetes service, through the generic proxy path
curl -ks https://10.43.0.1:443/version

# 3. DNS (UDP sessions) via the CoreDNS ClusterIP
nslookup kubernetes.default.svc.cluster.local 10.43.0.10

# 4. A real workload with two replicas — watch round-robin alternate
kubectl create deployment echo --replicas=2 \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.47 -- /agnhost serve-hostname --port 9376
kubectl expose deployment echo --port 80 --target-port 9376
kubectl rollout status deployment echo
CIP=$(kubectl get svc echo -o jsonpath='{.spec.clusterIP}')
for i in 1 2 3 4; do curl -s "http://$CIP/"; echo; done   # alternating pod names

# 5. Same thing from inside a pod
kubectl run probe -it --rm --restart=Never --image=busybox:1.36 -- \
  wget -qO- http://echo.default.svc.cluster.local

# 6. Endpoint churn must not restart listeners
kubectl scale deployment echo --replicas=1
# svcproxy (with -v) logs "endpoints changed" — no "listener stopped/started" —
# and curl against $CIP keeps working throughout.

# 7. Cleanup
kubectl delete svc/echo deployment/echo   # svcproxy logs "listener stopped"
```
