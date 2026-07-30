# kubeflare

Stock k3s running inside a Cloudflare Container, with `kubectl` on your laptop pointed at it.

```console
$ kubectl get nodes -o wide
NAME              STATUS   ROLES           VERSION        INTERNAL-IP   OS-IMAGE             KERNEL-VERSION                             CONTAINER-RUNTIME
cf-cloudchamber   Ready    control-plane   v1.36.2+k3s1   10.0.0.1      Ubuntu 24.04.4 LTS   6.18.36-cloudflare-firecracker-2026.6.17   containerd://2.3.2-k3s2

$ kubectl create deployment demo --image=nginx:1.27-alpine --replicas=3
deployment.apps/demo created

$ kubectl get pods -o wide
NAME                    READY   STATUS    IP           NODE
demo-6f8d4c9b7d-4d956   1/1     Running   10.42.0.5    cf-cloudchamber
demo-6f8d4c9b7d-876zz   1/1     Running   10.42.0.6    cf-cloudchamber
demo-6f8d4c9b7d-rc66l   1/1     Running   10.42.0.4    cf-cloudchamber
```

One node, three nginx pods with addresses on a flannel bridge, images pulled from Docker Hub. The same k3s you'd install on a cheap VPS, except there is no VPS. The whole thing lives in a Cloudflare Container that spins up on demand.

## Why this works at all

Cloudflare Containers have a reputation as locked-down sandboxes: rootless, unprivileged, no netfilter, no cgroup control. Kubernetes is about the worst tenant you could pick for a place like that. The kubelet wants to carve up cgroups, containerd wants to mount overlayfs, kube-proxy wants to rewrite the firewall. If the reputation were accurate, this project would be dead on arrival.

It isn't accurate. Each container is a Firecracker microVM with its own kernel, and inside that VM you are root, full stop:

```
$ uname -a
Linux cloudchamber 6.18.36-cloudflare-firecracker-2026.6.17 #1 SMP PREEMPT_DYNAMIC x86_64

$ id
uid=0(root) gid=0(root) groups=0(root)

$ grep -E 'CapEff|Seccomp|NoNewPrivs' /proc/self/status
CapEff:      000001ffffffffff     # every capability: sys_admin, net_admin, sys_module…
NoNewPrivs:  0
Seccomp:     0                    # no filter at all
```

Every capability, all 41 of them. No seccomp filter, an unmasked `/proc`, a writable cgroup v2 tree. Isolation comes from the hypervisor, so there's little reason to also shackle the guest, and Cloudflare doesn't. `wrangler` even says so at deploy time: `"runtime": "firecracker"`.

Which means none of the rootless machinery is needed. No rootlesskit, no subuid maps, no fuse-overlayfs. k3s runs the way it runs on any small VM.

The evidence for all of this, a 24-probe kernel matrix captured from a deployed container, is in [docs/FINDINGS.md](docs/FINDINGS.md), with raw output in [docs/probe-output-cloudflare.txt](docs/probe-output-cloudflare.txt).

## Try it

You need Node.js 20+, Docker to build the image, and a Cloudflare account on the Workers Paid plan. Containers are gated behind it; it's $5/month.

```bash
git clone https://github.com/loewenthal-corp/kubeflare && cd kubeflare
npm install
npx wrangler login
./scripts/deploy.sh
```

`deploy.sh` checks your entitlement, generates an access token, builds and pushes the image, waits for the cluster to come up, and writes `kubeconfig.yaml`. Then:

```bash
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes -o wide
```

Cold start takes about 90 seconds. `./scripts/teardown.sh --yes` removes everything.

## What works

- The whole control plane: apiserver, scheduler, controller-manager, and kine writing to SQLite instead of etcd. `/readyz` in about 13 seconds.
- The kubelet on containerd 2.3.2 with cgroup v2, reporting 2 CPUs, 8Gi of memory, and room for 110 pods.
- Image pulls from Docker Hub over the container's normal egress.
- Pod networking through flannel in host-gw mode: a `cni0` bridge, veth pairs, pod IPs in 10.42.0.0/24, pod-to-pod traffic. No `hostNetwork` shortcuts.
- **ClusterIP Services**, via `svcproxy/` — a userspace kube-proxy replacement. Pod → ClusterIP, pod → `kubernetes:443`, and Service DNS names all work, with even round-robin across endpoints.
- **Cluster DNS.** A vendored coredns runs on the host network and kubelet hands pods the node IP as their nameserver, so DNS works before (and independently of) svcproxy. The `kube-dns` ClusterIP works too, for charts that hardcode it.
- **PersistentVolumeClaims.** A vendored local-path-provisioner (apiserver reached via the node IP) provisions RWO volumes on the node disk. Ephemeral until you enable durable state (below).
- **`kubectl exec`, `attach`, `port-forward`, `cp`** — over the WebSocket transport that has been kubectl's default since 1.31, straight through the Worker. No tunnel required.
- `kubectl` from anywhere: get, create, apply, scale, delete, logs, describe, rollout.
- Self-healing. A supervisor restarts k3s if it dies, and after a disk wipe the cluster rebuilds itself unattended — or restores itself from R2 if durable state is on.

## What doesn't (yet)

Every entry below is a kernel gap, and the kernel takes no modules: there is no `/lib/modules` and no `/proc/modules`, so whatever isn't compiled in doesn't exist.

| Broken | Root cause |
|---|---|
| kube-proxy, all four backends | this kernel is missing something for each one (below) — worked around in userspace, see `svcproxy/` |
| NodePort / `type: LoadBalancer` | no inbound TCP reaches the container except through the Worker; svcproxy serves the ClusterIP only |
| Source IP preservation | svcproxy re-originates connections, so backends see the node address |
| `sessionAffinity: ClientIP` | not implemented by svcproxy (ignored with a warning) |
| flannel vxlan | `failed to create vxlan device: operation not supported`, hence host-gw |
| Multi-node | no vxlan device and no inbound UDP, so no cross-node overlay |

kube-proxy is the crux, and every one of its backends loses to this kernel:

- **iptables mode** — the famous failure is the `nfacct` counter rule (`xt_nfacct` missing), and that one actually has an off-switch (`--conntrack-tcp-be-liberal=true` skips the rule). But probing the deployed kernel shows **`xt_statistic` is missing too**, and that is how kube-proxy spreads traffic across a service's endpoints. `iptables-restore` is transactional: one multi-endpoint service and the entire sync fails. Dead.
- **nftables mode** — the kernel lacks the `reject` and `numgen` nft expressions. `reject` sits in the base ruleset kube-proxy installs unconditionally, `numgen` is its DNAT load-balancer. Dead.
- **IPVS** — `/proc/net/ip_vs` doesn't exist, and the mode is deprecated upstream anyway. Dead.
- **eBPF (Cilium et al.)** — `/sys/kernel/btf/vmlinux` doesn't exist, and modern Cilium is CO-RE/BTF-only. Dead.

What *does* work is Linux AnyIP: `ip route replace local 10.43.0.0/16 dev lo` makes the whole
service CIDR locally bindable with a plain `bind()`. So instead of rewriting packets,
[`svcproxy/`](svcproxy/) listens on every `ClusterIP:port` and forwards bytes in userspace — a
~800-line Go daemon watching Services and EndpointSlices, TCP and UDP, round-robin over ready
endpoints. k3s runs with `--disable-kube-proxy` and this takes its place.

Measured from inside a pod, before and after:

```
                                   before          after
pod → pod direct (10.42.0.5)       http 200        http 200
pod → ClusterIP nginx              timed out       http 200
pod → ClusterIP kubernetes:443     timed out       /version OK
DNS via kube-dns ClusterIP         timed out       resolves
http://nginx.default.svc...        n/a             http 200
6 requests across 3 endpoints      n/a             2 / 2 / 2
```

Kernel wishlist for Cloudflare, which would let a stock kube-proxy run and delete `svcproxy/`
entirely: `xt_nfacct`, `xt_statistic`, nft `reject`, nft `numgen`, plus `vxlan` and BTF for the
rest of the gaps.

## How it works

```
   kubectl ──HTTPS──▶ Worker ──▶ Durable Object ──▶ Container (Firecracker microVM)
                    /k8s/*                          ├── k3s server + agent
              bearer-token gated                    │   ├── apiserver, scheduler, controller-manager
                                                    │   ├── kine → SQLite
                                                    │   ├── kubelet → containerd → runc
                                                    │   └── flannel host-gw → cni0 → pods
                                                    ├── kubectl proxy  :8001
                                                    └── status server  :8080
```

Cloudflare Containers accept no raw TCP from outside; everything arrives through a Worker as HTTP or WebSocket. The apiserver speaks TLS on 6443, and a Worker can't pass raw TLS through.

The workaround is to run `kubectl proxy` inside the container. It terminates the apiserver's TLS locally using the node's own admin credentials and re-exposes the same API as plain HTTP. The Worker forwards `/k8s/*` to it, gated by a bearer token, and `kubectl` on your machine treats the Worker's URL as the API server.

Three details make this viable:

- `--api-prefix=/k8s/`, so the Worker forwards the request without rewriting the URL.
- `--reject-paths=''`, because the default reject list blocks `pods/exec` and `pods/attach` outright.
- The Worker forwards `/k8s/*` through the Durable Object's **fetch** boundary (`container.fetch(switchPort(...))`), never `containerFetch()`. `containerFetch` is a JSRPC method, and a Response carrying a WebSocket cannot cross an RPC boundary (`DataCloneError`) — that, not the edge, is what used to kill `kubectl exec`: kubectl has defaulted to WebSockets since 1.31, the WS dial died in the Worker, and kubectl silently fell back to SPDY, which the edge refuses. With the fetch boundary, `exec`, `attach`, `port-forward`, and `cp` all work through the Worker.

There's also a [Cloudflare Tunnel path](docs/TUNNEL.md) that carries native TLS all the way to 6443 — `scripts/tunnel-setup.sh` automates it end to end given an API token with `Cloudflare Tunnel: Edit` + `DNS: Edit`. It's the transport-independent fallback and the basis for WARP private networking; it needs a domain, so it isn't the default.

### On running this in production

It's a free country. I'm not going to pretend to know what you're building; if you want to run this in prod, be my guest, and if something bad happens, not my fault. What I will do is tell you exactly what you're getting:

- The `/k8s` passthrough collapses cluster-admin into a single bearer token. Whoever holds it owns the cluster. No users, no RBAC mapping, no audit trail beyond the apiserver's own.
- Everything except `/healthz` requires that token, and the dashboard redacts known secrets from command output. That is the entire security model.
- Cluster state survives restarts only if you enable the R2 replication above. Everything on a PersistentVolume does not — those live on the ephemeral disk.
- Services work through a userspace proxy, not the kernel. Backends never see real client IPs, which breaks NetworkPolicy-by-source and any app-level IP allowlist. Throughput is a userspace copy per connection.
- One node, and it can go away at any time. There is no HA story here at all.

MIT licensed, no warranty, see [LICENSE](LICENSE).

## Cost

Cloudflare bills containers per 10ms of active runtime. For the 2 vCPU / 8 GiB / 16 GB instance this project uses:

| | Per hour |
|---|---|
| Provisioned floor (memory + disk, 0% CPU) | $0.076 |
| Idle k3s in practice (~10% of one core) | ≈ $0.083 |
| Both vCPUs pinned | $0.220 |

Call it $2 a day if you leave it running. The Workers Paid plan includes 25 GiB-hours of memory, 375 vCPU-minutes, and 200 GB-hours of disk per month, which covers roughly the first 3 hours of uptime at no cost beyond the $5 base. A demo costs nothing; an always-on cluster is about $65/month.

After `sleepAfter` (2 hours here) the container sleeps and active-runtime billing stops. Sleeping also wipes the disk; the cluster rebuilds itself from the baked-in manifests on the next request, or restores from R2 if durable state is on. R2 adds a few cents a month at the default 10s sync interval.

## Gotchas

- Pass `--containers-rollout=immediate` on every deploy of a single-instance app. The default rollout is `[10, 100]`, and 10% of one instance rounds down to zero, so deploys silently keep serving the old image. This cost hours to notice; `scripts/deploy.sh` always passes it.
- The disk is ephemeral. Every rollout, sleep, or eviction wipes cluster state, including the k3s CA — unless R2 replication is on, in which case the CA rides inside the replicated datastore.
- A deploy does not swap the running instance instantly. `wrangler containers info <id>` shows the rollout state; a fresh instance takes ~40s to appear and the cluster another ~60s. Watching `kubectl` alone will show you the *old* cluster and mislead you.
- Local Docker testing will mislead you. Docker's default seccomp profile denies `unshare(CLONE_NEWUSER)`, masks `/proc`, and omits `/dev/kmsg`, `/dev/fuse`, and `/dev/net/tun`, all of which Cloudflare provides. A local run sends you down a rootless path the platform never required. Trust deployed instances only.
- The k3s version is pinned to `v1.36.2+k3s1`. The `update.k3s.io` channel endpoint answers with a 302 to an HTML page rather than JSON, and the `+` in the tag has to be percent-encoded as `%2B`.
- `wrangler`'s OAuth token has no DNS permission and cannot mint R2 S3 credentials. The tunnel (`scripts/tunnel-setup.sh`) needs a custom API token (Account: `Cloudflare Tunnel: Edit` + Zone: `DNS: Edit`); durable state needs an R2 API token from the dashboard.
- k3s's addon reconciler restores its packaged manifests on every start — live `kubectl patch`es of packaged components (coredns, local-path) do not stick. That's why both are vendored in `container/manifests/` with `--disable coredns,local-storage`.

## Durable state (Litestream → R2)

The disk is ephemeral, but the cluster doesn't have to be. When the R2 secrets are
present, the entrypoint restores kine's SQLite database from R2 before k3s starts and
replicates it continuously afterwards (`litestream replicate -exec`). k3s runs with
`--datastore-endpoint=litestream://`, kine's purpose-built mode that hands WAL
checkpointing over to litestream.

Identity survives too: k3s stores its CA certs and service-account signing key
*inside* the datastore, encrypted with the join token — so `deploy.sh` pins
`K3S_TOKEN` and `K3S_NODE_PASSWORD` as stable Worker secrets (persisted locally,
gitignored), and the node name is pinned while replication is on. A brand-new
container decrypts the restored DB and comes back as the *same* cluster: same CA,
same kubeconfigs, same Secrets.

To turn it on: create an R2 API token (dashboard → R2 → Manage API tokens, Object
Read & Write on the `kubeflare-state` bucket) and set three secrets:

```bash
npx wrangler secret put LITESTREAM_ACCESS_KEY_ID
npx wrangler secret put LITESTREAM_SECRET_ACCESS_KEY
npx wrangler secret put R2_ENDPOINT   # https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

then redeploy. Without them the cluster stays ephemeral, exactly as before. The
sync interval (10s default, `container/litestream.yml`) is the durability/cost
dial: 10s stays inside R2's free tier; 1s costs ≈ $8/month.

## Roadmap

Roughly in order of value:

- [x] Cluster DNS without kube-proxy — vendored hostNetwork coredns + `--kubelet-arg=cluster-dns=<node IP>`.
- [x] `exec` / `attach` / `port-forward` through the Worker — WebSocket transport via the DO fetch boundary.
- [x] Litestream replication of the kine SQLite database to R2 (opt-in, needs an R2 token).
- [x] Persist the cluster CA across restarts — the CA rides inside the replicated datastore; token + node password pinned by deploy.sh.
- [x] ClusterIP without kube-proxy — `svcproxy/`, a userspace Service proxy on AnyIP-bound ClusterIPs.
- [ ] Source-IP preservation and `sessionAffinity: ClientIP` in svcproxy; NodePort via the Worker.
- [ ] R2-backed PersistentVolumes: JuiceFS (host mount, SQLite metadata on the same litestream pipeline) + a `juicefs-r2` StorageClass.
- [ ] R2-backed image cache: `registry:3` pull-through proxy on the s3 driver, `registries.yaml` mirror — cold boots stop re-pulling from Docker Hub.
- [ ] WARP private networking: route `10.42.0.0/15` through the tunnel so an enrolled laptop reaches pod/service IPs directly.
- [ ] `type: LoadBalancer` via a controller that provisions Cloudflare Tunnel public hostnames per Service.
- [ ] Multi-node: needs a TCP-capable overlay (tunnel mesh or tailscale); blocked on no vxlan + no inbound UDP.

Contributions welcome. The point of the exercise is to find out how much of the Kubernetes API surface can be made to work here.

## Layout

| Path | What |
|---|---|
| `container/` | The image: k3s, litestream, cloudflared, supervisor entrypoint, status server |
| `container/manifests/` | Vendored coredns and local-path-provisioner, both pointed at the node IP |
| `svcproxy/` | Userspace ClusterIP Service proxy — the kube-proxy replacement |
| `probe/probe.sh` | The 24-check kernel probe harness behind the findings |
| `src/index.ts` | Worker: API passthrough, gated dashboard, `/healthz` |
| `scripts/deploy.sh` | One command from zero to a working `kubeconfig.yaml` |
| `scripts/tunnel-setup.sh` | Automates the Cloudflare Tunnel path end to end (needs an API token) |
| `docs/FINDINGS.md` | The full write-up: probe matrix, every error, exact causes |

## License

MIT, see [LICENSE](LICENSE).

Built as a feasibility spike. It escalated.
