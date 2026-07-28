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
- `kubectl` from anywhere: get, create, apply, scale, delete, logs, describe, rollout.
- Self-healing. A supervisor restarts k3s if it dies, and after a disk wipe the cluster rebuilds itself unattended.

## What doesn't

Every entry below is a kernel gap, and the kernel takes no modules: there is no `/lib/modules` and no `/proc/modules`, so whatever isn't compiled in doesn't exist.

| Broken | Root cause |
|---|---|
| ClusterIP Services | kube-proxy can't program rules in either backend (below) |
| Cluster DNS | downstream of the above: coredns needs to reach `kubernetes.default`, which is a ClusterIP |
| flannel vxlan | `failed to create vxlan device: operation not supported`, hence host-gw |
| `kubectl exec` / `port-forward` | Cloudflare's edge won't switch protocols to `Upgrade: SPDY/3.1` |
| Multi-node | no vxlan device and no inbound UDP, so no cross-node overlay |

kube-proxy is the crux, and it fails in both of its backends.

In iptables mode, the `KUBE-FORWARD` chain includes an `nfacct` counter rule, and the kernel has no `xt_nfacct`:

```
Warning: Extension nfacct revision 0 not supported, missing kernel module?
line 9: RULE_APPEND failed (No such file or directory): rule in chain KUBE-FORWARD
```

`iptables-restore` is transactional. One rule fails, the whole sync fails, and kube-proxy ends up programming no service rules at all.

In nftables mode, the kernel is missing the `reject` and `numgen` nft expressions:

```
add rule ip kube-proxy reject-chain reject
                                    ^^^^^^  Could not process rule
add rule ip kube-proxy service-… dnat ip addr . port to numgen random mod 1 map { … }
                                                        ^^^^^^^^^^^^^^^^^^  Could not process rule
```

`numgen` is how kube-proxy spreads DNAT across a service's endpoints, so there is no easy way around it.

Measured from inside a pod:

```
pod → pod  direct (10.42.0.5)  : http 200
pod → ClusterIP nginx           : timed out
pod → ClusterIP kubernetes:443  : timed out
```

Three kernel config flags separate this from a fully working single-node cluster: `xt_nfacct`, nft `reject`, nft `numgen`. If you work on Cloudflare's guest kernel, that's the wishlist.

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

Two flags make this viable:

- `--api-prefix=/k8s/`, so the Worker can forward the original `Request` object untouched. Rewriting the URL means building a new `Request`, which drops the upgrade semantics `exec` needs.
- `--reject-paths=''`, because the default reject list blocks `pods/exec` and `pods/attach` outright.

There's also a [Cloudflare Tunnel path](docs/TUNNEL.md) that carries native TLS to 6443 and should bring back `exec` and `port-forward`. It needs a DNS record, so it isn't the default.

### On running this in production

It's a free country. I'm not going to pretend to know what you're building; if you want to run this in prod, be my guest, and if something bad happens, not my fault. What I will do is tell you exactly what you're getting:

- The `/k8s` passthrough collapses cluster-admin into a single bearer token. Whoever holds it owns the cluster. No users, no RBAC mapping, no audit trail beyond the apiserver's own.
- Everything except `/healthz` requires that token, and the dashboard redacts known secrets from command output. That is the entire security model.
- The disk is ephemeral, so anything you don't replicate off-box is gone on the next restart.
- ClusterIP Services and cluster DNS don't work at all, which rules out most real workloads before security even comes up.

MIT licensed, no warranty, see [LICENSE](LICENSE).

## Cost

Cloudflare bills containers per 10ms of active runtime. For the 2 vCPU / 8 GiB / 16 GB instance this project uses:

| | Per hour |
|---|---|
| Provisioned floor (memory + disk, 0% CPU) | $0.076 |
| Idle k3s in practice (~10% of one core) | ≈ $0.083 |
| Both vCPUs pinned | $0.220 |

Call it $2 a day if you leave it running. The Workers Paid plan includes 25 GiB-hours of memory, 375 vCPU-minutes, and 200 GB-hours of disk per month, which covers roughly the first 3 hours of uptime at no cost beyond the $5 base. A demo costs nothing; an always-on cluster is about $65/month.

After `sleepAfter` (2 hours here) the container sleeps and active-runtime billing stops. Sleeping also wipes the disk; the cluster rebuilds itself from the baked-in manifests on the next request.

## Gotchas

- Pass `--containers-rollout=immediate` on every deploy of a single-instance app. The default rollout is `[10, 100]`, and 10% of one instance rounds down to zero, so deploys silently keep serving the old image. This cost hours to notice; `scripts/deploy.sh` always passes it.
- The disk is ephemeral. Every rollout, sleep, or eviction wipes cluster state, including the k3s CA.
- Local Docker testing will mislead you. Docker's default seccomp profile denies `unshare(CLONE_NEWUSER)`, masks `/proc`, and omits `/dev/kmsg`, `/dev/fuse`, and `/dev/net/tun`, all of which Cloudflare provides. A local run sends you down a rootless path the platform never required. Trust deployed instances only.
- The k3s version is pinned to `v1.36.2+k3s1`. The `update.k3s.io` channel endpoint answers with a 302 to an HTML page rather than JSON, and the `+` in the tag has to be percent-encoded as `%2B`.
- `wrangler`'s OAuth token has no DNS permission, which is why the tunnel setup isn't automated.

## Roadmap

Roughly in order of value:

- [ ] Cluster DNS without kube-proxy: run coredns with `hostNetwork: true` and point kubelets at it with `--cluster-dns=<node IP>`. Would make the cluster genuinely useful for hostNetwork workloads. Untested, but the theory is sound.
- [ ] A userspace Service implementation to route around the missing netfilter features.
- [ ] Make the tunnel path the default, restoring `exec`, `attach`, and `port-forward`.
- [ ] Litestream replication of the kine SQLite database to R2, so a cluster survives the disk.
- [ ] Persist the cluster CA across restarts so exported kubeconfigs keep working.

Contributions welcome. The point of the exercise is to find out how much of the Kubernetes API surface can be made to work here.

## Layout

| Path | What |
|---|---|
| `container/` | The image: k3s, cloudflared, supervisor entrypoint, status server |
| `probe/probe.sh` | The 24-check kernel probe harness behind the findings |
| `src/index.ts` | Worker: API passthrough, gated dashboard, `/healthz` |
| `scripts/deploy.sh` | One command from zero to a working `kubeconfig.yaml` |
| `docs/FINDINGS.md` | The full write-up: probe matrix, every error, exact causes |

## License

MIT, see [LICENSE](LICENSE).

Built as a feasibility spike. It escalated.
