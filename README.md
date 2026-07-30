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

Cold start takes about 90 seconds; a *restore* from R2 is closer to 30. `./scripts/teardown.sh --yes` removes everything.

The node is named `cf-<hostname>` on an ephemeral cluster and `kubeflare` once durable
state is on, because a restored cluster has to re-adopt its own Node object and
container hostnames are not stable across instances.

## What works

- The whole control plane: apiserver, scheduler, controller-manager, and kine writing to SQLite instead of etcd. `/readyz` in about 13 seconds.
- The kubelet on containerd 2.3.2 with cgroup v2, reporting 2 CPUs, 8Gi of memory, and room for 110 pods.
- Image pulls from Docker Hub over the container's normal egress.
- Pod networking through flannel in host-gw mode: a `cni0` bridge, veth pairs, pod IPs in 10.42.0.0/24, pod-to-pod traffic. No `hostNetwork` shortcuts.
- **ClusterIP Services**, via `svcproxy/` — a userspace kube-proxy replacement. Pod → ClusterIP, pod → `kubernetes:443`, and Service DNS names all work, with even round-robin across endpoints.
- **Cluster DNS.** A vendored coredns runs on the host network and kubelet hands pods the node IP as their nameserver, so DNS works before (and independently of) svcproxy. The `kube-dns` ClusterIP works too, for charts that hardcode it.
- **PersistentVolumeClaims**, two flavours. A vendored local-path-provisioner (apiserver reached via the node IP) serves RWO volumes on the ephemeral node disk, and — when you turn it on — RWX volumes on a JuiceFS filesystem whose data lives in R2 and survives the disk. See [R2-backed volumes](#r2-backed-volumes-juicefs).
- **`kubectl exec`, `attach`, `port-forward`, `cp`** — over the WebSocket transport that has been kubectl's default since 1.31, straight through the Worker. No tunnel required.
- **`kubectl top` and HorizontalPodAutoscalers**, via a vendored metrics-server. It was only ever disabled because the aggregation layer needs a working ClusterIP.
- **Admission webhooks**, including your own — the apiserver reaches a webhook's ClusterIP through svcproxy. This is what makes operators and Crossplane installable.
- Most of the API surface, measured rather than assumed: 153 features work across 175 checks. See [docs/CONFORMANCE.md](docs/CONFORMANCE.md).
- `kubectl` from anywhere: get, create, apply, scale, delete, logs, describe, rollout.
- Self-healing. A supervisor restarts k3s if it dies, and after a disk wipe the cluster rebuilds itself unattended — or restores itself from R2 if durable state is on.

## What doesn't (yet)

Every entry below is a kernel gap, and the kernel takes no modules: there is no `/lib/modules` and no `/proc/modules`, so whatever isn't compiled in doesn't exist.

| Broken | Root cause |
|---|---|
| kube-proxy, all four backends | this kernel is missing something for each one (below) — worked around in userspace, see `svcproxy/` |
| **NetworkPolicy — silently does nothing** | kube-router emits `-j NFLOG` per pod chain and the kernel has no `xt_NFLOG`, so its transactional `iptables-restore` discards the *entire* ruleset. Policies are accepted and never enforced, ingress **and** egress |
| NodePort / `type: LoadBalancer` | no inbound TCP reaches the container except through the Worker; svcproxy serves the ClusterIP only |
| Source IP preservation | svcproxy re-originates connections, so backends see the node address |
| `sessionAffinity: ClientIP` | not implemented by svcproxy (ignored with a warning) |
| Service ports 8001 / 8080 | the host binds these on `0.0.0.0` (kubectl proxy, status server), so svcproxy cannot bind a ClusterIP on them. Pick another port |
| `kubectl get --raw <path>` | `--raw` keeps only the *host* from the kubeconfig server URL and drops the `/k8s` prefix, so it hits the Worker dashboard and returns HTTP 200 HTML. Use `--raw /k8s/<path>` |
| flannel vxlan | `failed to create vxlan device: operation not supported`, hence host-gw |
| Multi-node | no vxlan device and no inbound UDP, so no cross-node overlay |

**NetworkPolicy deserves emphasis, because it fails in the most dangerous way
available: silently.** The objects are accepted, `kubectl get networkpolicy`
shows them, k3s ships a controller — and nothing is enforced, including
`deny-all` egress to the internet. Do not rely on it for isolation here. That
makes `xt_NFLOG` a seventh missing kernel feature, in the same family as
kube-proxy's `xt_nfacct`.

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
- That token is not the only way in, and this is worth understanding before you run anything untrusted here. `kubectl proxy` holds the node's admin kubeconfig and authenticates nobody; the Worker is the only gate in front of it. Because svcproxy routes the whole service CIDR host-local, a pod could reach it at the node IP *or at any `10.43.x.x`* and get cluster-admin with no token and no ServiceAccount — RBAC bypassed completely. The entrypoint now drops pod traffic to `:8001` and `:8080`, which closes it, but the underlying listeners are still unauthenticated: treat every pod on this cluster as a trust boundary you have not really established.
- Everything except `/healthz` requires that token, and the dashboard redacts known secrets from command output. That is the entire security model.
- Cluster state survives restarts only if you enable the R2 replication above, and PersistentVolume data only if you also use the `juicefs-r2` class. A `local-path` volume dies with the disk.
- Services work through a userspace proxy, not the kernel. Backends never see real client IPs, which breaks NetworkPolicy-by-source and any app-level IP allowlist. Throughput is a userspace copy per connection.
- NetworkPolicy will not save you: it is accepted and silently unenforced (above). There is no working in-cluster network isolation.
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
- The local-path provisioner now uses per-class configuration (`storageClassConfigs`) to serve both StorageClasses from one deployment. Its `pickConfig` rejects any class name that isn't a key in that map — so if you add your own StorageClass with `provisioner: rancher.io/local-path`, give it an entry in `container/manifests/local-path-storage.yaml` or provisioning fails with `BUG: Got request for unexpected storage class`.

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

## R2-backed volumes (JuiceFS)

Durable state saves the cluster; it does nothing for the data *inside* your pods,
because a PersistentVolume is just a directory on the disk that gets wiped. The fix
is a second StorageClass whose directories live in R2.

[JuiceFS](https://juicefs.com) is a POSIX filesystem that stores file contents as
objects and the inode tree in a database. Here the objects go to an R2 bucket and
the database is SQLite on the same litestream pipeline as kine's. It is mounted once
on the host at `/mnt/juicefs`, and the same vendored local-path-provisioner hands out
subdirectories of it — so there is no CSI driver, no sidecar, and nothing new in the
data path of a pod beyond a bind mount.

Two classes, and the default is unchanged:

| Class | Backed by | Access modes | Survives a disk wipe | Write latency |
|---|---|---|---|---|
| `local-path` (default) | node disk, `/var/lib/rancher/k3s/storage` | RWO, RWOP | no | local ext4 |
| `juicefs-r2` | R2 via JuiceFS, `/mnt/juicefs/pvcs` | RWO, ROX, **RWX** | yes | R2 PUT per `fsync` |

Use `local-path` for scratch, caches, and anything write-heavy. Use `juicefs-r2` for
the data you would be annoyed to lose, and for the RWX volumes that a single-node
`local-path` cannot legally provide.

### Turning it on

It rides on the durable-state secrets above — there is nothing new to set. Create the
data bucket, make sure your existing R2 token covers it, and redeploy:

```bash
npx wrangler r2 bucket create kubeflare-jfs
```

The bucket name is a plain var (`R2_BUCKET_JFS` in `wrangler.jsonc`, default
`kubeflare-jfs`); set it to `""` to leave the feature off. It is off regardless
unless durable state is enabled, because without litestream the metadata DB dies
with the disk and takes the whole filesystem with it. On the first boot the
entrypoint runs `juicefs format`, which write-probes the bucket — a token that does
not cover it fails there with a logged 403 rather than hanging. Nothing about this
can stop k3s from starting: if any of it fails, the `juicefs-r2` StorageClass is
simply never created and the cluster behaves exactly as it did before.

```console
$ kubectl get storageclass
NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer
juicefs-r2             rancher.io/local-path   Delete          Immediate
```

### Example

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: notes
spec:
  storageClassName: juicefs-r2
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: notes-writer
spec:
  containers:
    - name: sh
      image: busybox:1.37
      command: [sh, -c, "date >> /data/log.txt; tail -f /data/log.txt"]
      volumeMounts:
        - name: notes
          mountPath: /data
  volumes:
    - name: notes
      persistentVolumeClaim:
        claimName: notes
```

```bash
kubectl apply -f notes.yaml
kubectl exec notes-writer -- cat /data/log.txt
```

Delete the pod, restart the whole container, come back an hour later — the file is
still there, because it is an object in R2 and the inode that names it was replicated
along with the rest of the cluster.

### What you are actually getting

- **`fsync` costs an R2 round trip.** Tens of milliseconds, every time. That is the
  price of the durability guarantee: a successful `fsync` means the blocks are in R2,
  not in a local buffer. Nothing here uses JuiceFS `--writeback`, which would
  acknowledge writes into a cache directory on the disk that gets wiped — the exact
  data loss this feature exists to prevent. Do not put a database's WAL on this.
- **`juicefs gc`, `fsck`, `sync` and `destroy` do not work against R2.** They depend
  on `ListObjectsV2` returning keys in lexicographic order, and R2 does not. This is
  also why the mount runs with `--backup-meta 0`: JuiceFS's own metadata-backup
  rotation prunes through the same listing. Litestream is the *only* metadata backup.
- **The metadata DB is the filesystem.** Lose `/var/lib/kubeflare/jfs-meta.db` and its
  replica and the objects in R2 become unreadable — and the bucket being non-empty is
  precisely the state `juicefs format` refuses to touch, so you get a loud
  `Storage ... is not empty` on the next boot rather than a silent second filesystem
  over the first one's data. Recovery from that point is: empty `kubeflare-jfs` and
  start over.
- **One writer, one node.** Exactly one `juicefs mount` process may own that SQLite
  file, which is fine for a single-instance container and is another reason
  `max_instances` is 1.
- **Cluster state and volume data are two different R2 objects with two different
  clocks.** Both replicate on a 10s interval, independently. A crash can leave a PVC
  that the datastore has not heard of yet, or vice versa.
- **Deleting a PVC deletes the data immediately.** The volume is formatted with
  `--trash-days 0`, deliberately: with `gc` unavailable there must not be a class of
  data that is invisible in the filesystem and still billed. Set the PV's reclaim
  policy to `Retain` for anything you want a second chance at.
- **No quota.** A PVC's requested size is recorded and then ignored; the real limit
  is R2, billed per GB-month.
- **It roughly doubles the R2 class-A write count.** The metadata DB replicates on
  the same 10s interval as the datastore and is written just as continuously, so
  expect ≈ 720k class-A operations a month against R2's 1M free tier instead of
  ≈ 360k. Data blocks are extra, but only when something actually writes.
- **If the mount dies, pods holding it get I/O errors until they restart.** The
  entrypoint remounts within ~10s, but a bind mount into a running container still
  points at the dead one. There is no CSI-style mount recovery here.
- **The StorageClass disappears when the mount does.** The entrypoint creates
  `juicefs-r2` only once the mount is live and *deletes* it on any boot where it
  isn't — including a boot that restored a datastore from a healthier one. Without
  that, a PVC would provision onto the ephemeral disk under a name that promises
  R2. Bound PVCs are unaffected; new ones fail loudly, which is the point.

## Image cache on R2

Every cold wake starts with an empty containerd store, so image pulls dominate the
restore path. `kubeflare-registry` is a separate Worker
([cloudflare/serverless-registry](https://github.com/cloudflare/serverless-registry))
backed by R2 that acts as a pull-through mirror: containerd asks it for `docker.io`
images, it fetches on a miss, caches into R2, and serves from R2 thereafter.

It runs as its own Worker rather than inside the container deliberately — it stays up
while the cluster is asleep, which is exactly when a cold wake needs it, and it costs
the cluster no CPU or memory.

One non-obvious thing, learned the hard way: **the upstream is `mirror.gcr.io`, not
Docker Hub.** Pointing it at `registry-1.docker.io` anonymously fails, because a
Worker's egress is shared Cloudflare infrastructure and Docker Hub's per-IP anonymous
limit is permanently exhausted there — the token exchange succeeds and then the
manifest request comes back `429`. `mirror.gcr.io` is Google's public Docker Hub
pull-through and has no such per-IP cliff. Docker Hub stays configured as a second
choice; add your own Docker Hub credentials to it if you want the authenticated
100/hour account limit instead.

Set `REGISTRY_MIRROR_URL` to `""` in `wrangler.jsonc` to pull straight from Docker Hub.
containerd always appends the real upstream after any mirror, so a broken cache makes
pulls slow rather than impossible.

## Roadmap

Roughly in order of value:

- [x] Cluster DNS without kube-proxy — vendored hostNetwork coredns + `--kubelet-arg=cluster-dns=<node IP>`.
- [x] `exec` / `attach` / `port-forward` through the Worker — WebSocket transport via the DO fetch boundary.
- [x] Litestream replication of the kine SQLite database to R2 (opt-in, needs an R2 token).
- [x] Persist the cluster CA across restarts — the CA rides inside the replicated datastore; token + node password pinned by deploy.sh.
- [x] ClusterIP without kube-proxy — `svcproxy/`, a userspace Service proxy on AnyIP-bound ClusterIPs.
- [x] R2-backed PersistentVolumes — JuiceFS host mount + a `juicefs-r2` StorageClass, RWX, verified surviving a disk wipe.
- [x] R2-backed image cache — a separate `kubeflare-registry` Worker (cloudflare/serverless-registry) mirroring docker.io.
- [x] metrics-server, and therefore `kubectl top` and HPA — it only ever needed working ClusterIPs.
- [x] An empirical API conformance matrix and suite — [docs/CONFORMANCE.md](docs/CONFORMANCE.md), `conformance/run.sh`.
- [ ] Bind `kubectl proxy` and the status server to the node IP instead of `0.0.0.0`, so the pod→host firewall guards become belt-and-braces rather than the only defence — and so Services can use ports 8001/8080.
- [ ] Source-IP preservation and `sessionAffinity: ClientIP` in svcproxy; NodePort via the Worker.
- [x] R2-backed PersistentVolumes: JuiceFS (host mount, SQLite metadata on the same litestream pipeline) + a `juicefs-r2` StorageClass.
- [ ] R2-backed image cache: `registry:3` pull-through proxy on the s3 driver, `registries.yaml` mirror — cold boots stop re-pulling from Docker Hub.
- [ ] WARP private networking: route `10.42.0.0/15` through the tunnel so an enrolled laptop reaches pod/service IPs directly.
- [ ] `type: LoadBalancer` via a controller that provisions Cloudflare Tunnel public hostnames per Service.
- [ ] Multi-node: needs a TCP-capable overlay (tunnel mesh or tailscale); blocked on no vxlan + no inbound UDP.

Contributions welcome. The point of the exercise is to find out how much of the Kubernetes API surface can be made to work here.

## Layout

| Path | What |
|---|---|
| `container/` | The image: k3s, litestream, juicefs, cloudflared, supervisor entrypoint, status server |
| `container/manifests/` | Vendored coredns and local-path-provisioner, both pointed at the node IP |
| `container/manifests-optional/` | Applied only when its precondition holds — currently the `juicefs-r2` StorageClass |
| `svcproxy/` | Userspace ClusterIP Service proxy — the kube-proxy replacement |
| `probe/probe.sh` | The 24-check kernel probe harness behind the findings |
| `src/index.ts` | Worker: API passthrough, gated dashboard, `/healthz` |
| `scripts/deploy.sh` | One command from zero to a working `kubeconfig.yaml` |
| `scripts/tunnel-setup.sh` | Automates the Cloudflare Tunnel path end to end (needs an API token) |
| `docs/FINDINGS.md` | The full write-up: probe matrix, every error, exact causes |
| `docs/CONFORMANCE.md` | Empirical API matrix: 153 work, 14 broken, measured not inferred |
| `conformance/` | The suite behind that matrix — `conformance/run.sh` |

## License

MIT, see [LICENSE](LICENSE).

Built as a feasibility spike. It escalated.
