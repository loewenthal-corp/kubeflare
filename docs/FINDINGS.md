# Kubernetes on Cloudflare Containers — findings

**Spike run:** 2026-07-27 · account *<your account>* (`<ACCOUNT_ID>…`) · region `dfw01`

---

## 1. Verdict

**A real, single-node Kubernetes cluster runs on Cloudflare Containers — k3s v1.36.2 with a genuine
kubelet, containerd, and CNI pod networking — driven by `kubectl` from a laptop; everything failed only
at ClusterIP Services, because the Cloudflare kernel is missing three netfilter features that
kube-proxy requires.**

This is above the mission's Phase 2 target. The mission's central premise turned out to be wrong in our
favour, and one of its "concede it" items (pod networking) actually works.

| Tier | Target | Result |
|---|---|---|
| Phase 0 | Probe matrix from a deployed container | **Achieved** — 24/24 probes, deployed |
| Phase 1 | Control plane + simulated (kwok) nodes | **Surpassed** — no simulation needed |
| Phase 2 | Rootless k3s, one real node, hostNetwork pod | **Surpassed** — *non*-rootless k3s, real node, real CNI pod IPs |
| Phase 2+ | — | 3 × nginx `Running`, `kubectl` from laptop, `kubectl logs`, pod→pod networking |
| Not achieved | — | ClusterIP Services, cluster DNS, `kubectl exec` *through the Worker* |

---

## 2. The premise was wrong: Containers are Firecracker microVMs, not rootless sandboxes

The mission supplied four "verified platform facts" that shaped the whole plan. The deployed probe run
contradicts the most important one. Quoting the brief:

> **Containers run rootless. No privileged mode. No iptables manipulation** — the platform blocks
> netfilter configuration outright.

Every clause of that is false on the deployed platform:

```
$ uname -a
Linux cloudchamber 6.18.36-cloudflare-firecracker-2026.6.17 #1 SMP PREEMPT_DYNAMIC x86_64

$ id
uid=0(root) gid=0(root) groups=0(root)

$ grep -E 'CapEff|Seccomp|NoNewPrivs' /proc/self/status
CapEff:      000001ffffffffff        # all 41 capabilities
NoNewPrivs:  0
Seccomp:     0                       # no seccomp filter at all
```

`0x1ffffffffff` decodes to the complete capability set including `cap_sys_admin`, `cap_net_admin`,
`cap_sys_module`, and `cap_sys_boot`. There is no seccomp filter, `/proc` is not masked, and
`/sys/fs/cgroup` is writable with full delegation.

The reason is architectural: each container is its own **Firecracker microVM** with its own kernel, not
a namespace-isolated process on a shared host. Cloudflare's own deploy output says so — the application
config contains `"runtime": "firecracker"`. Isolation comes from the hypervisor, so there is little
reason to also strip capabilities inside the guest.

**Consequence:** every rootless contortion the mission planned for — rootlesskit, subuid maps,
slirp4netns, fuse-overlayfs, `--rootless` — is unnecessary. Stock k3s runs as-is. Two container images
built during this spike (`container/phase1`, `container/phase2`) implement the rootless approach and are
retained as fallbacks, but they solve a problem this platform does not have.

---

## 3. Probe matrix (Phase 0)

From the **deployed** container. `report/cf-probes-raw.txt` holds the full transcript; the local Docker
column is from `--user 1000:1000 --cap-drop=ALL --security-opt seccomp=unconfined` and is included only
to show how badly local testing would have misled us.

| # | Probe | Cloudflare (deployed) | Local Docker (rootless+userns) | Note |
|---|---|---|---|---|
| 1 | `userns_unshare` | **PASS** | PASS | rootless runtimes possible (unused — we are root) |
| 2 | `userns_full` | **PASS** | PASS | full unshare works |
| 3 | `netns_userns` | **PASS** | PASS | network namespaces usable |
| 4 | `newuidmap_present` | **PASS** | PASS | setuid helpers present |
| 5 | `subuid_configured` | **PASS** | PASS | `/etc/subuid` ranges present |
| 6 | `cgroup2_mounted` | **PASS** | PASS | controllers: `cpuset cpu io memory hugetlb pids` |
| 7 | `cgroup_subtree_writable` | **PASS** | FAIL | **full cgroup delegation** — kubelet needs this |
| 8 | `cgroup_mkdir` | **PASS** | FAIL | can create sub-cgroups |
| 9 | `dev_net_tun` | **PASS** | FAIL | present (slirp4netns viable; unused) |
| 10 | `dev_net_tun_open` | **PASS** | FAIL | openable |
| 11 | `dev_kmsg` | **PASS** | FAIL | present |
| 12 | `dev_kmsg_read` | FAIL | FAIL | exists; partial reads give `EINVAL`. kubelet unaffected |
| 13 | `dev_fuse` | **PASS** | FAIL | present — fuse-overlayfs viable |
| 14 | `overlay_userns_tmpfs` | **PASS** | PASS | native overlayfs in a userns works |
| 15 | `fuse_overlayfs_userns` | FAIL | FAIL | local failure is missing `/dev/fuse`; CF has the device |
| 16 | `pivot_root_userns` | **PASS** | PASS | container runtimes can `pivot_root` |
| 17 | `pidns_userns` | **PASS** | FAIL | PID namespaces work |
| 18 | `proc_submounts_masked` | FAIL | PASS | **/proc is NOT masked on CF** — Docker masks it |
| 19 | `mount_fresh_proc_userns` | FAIL | FAIL | cannot remount `/proc` inside a userns |
| 20 | `iptables_userns` | **PASS** | PASS | **netfilter works** — the mission assumed it would not |
| 21 | `nft_userns` | **PASS** | PASS | nftables works |
| 22 | `outbound_dns` | **PASS** | PASS | DNS resolves |
| 23 | `outbound_https` | **PASS** | PASS | outbound HTTPS works — real image pulls |
| 24 | `outbound_tcp_7844` | **PASS** | PASS | outbound TCP to the Cloudflare edge (cloudflared) |

Environment: Ubuntu 24.04.4 guest, kernel 6.18.36, ext4 root, cgroup v2 unified, `pid_max` 4194304,
`open files` 1048576, no `/lib/modules` and no `/proc/modules` (so **nothing can be modprobed** — every
kernel feature is built in or absent, which is the root of §5).

### Local testing would have lied in both directions

Docker's *default* seccomp profile denies `unshare(CLONE_NEWUSER)` outright, so the single most important
capability could not be tested locally at all without `seccomp=unconfined`. Meanwhile Docker masks `/proc`
and omits `/dev/kmsg`, `/dev/fuse`, and `/dev/net/tun`, all of which Cloudflare provides. The mission's
"local dev lies" rule was correct, and in this case local testing was *pessimistic* — it would have sent
us down the rootless path that the platform never required.

---

## 4. What works

Verified from a laptop `kubectl`, against the deployed cluster (`report/evidence/kubectl-session.txt`):

```
$ kubectl get nodes -o wide
NAME              STATUS  ROLES          VERSION       INTERNAL-IP  OS-IMAGE             KERNEL-VERSION                            CONTAINER-RUNTIME
cf-cloudchamber   Ready   control-plane  v1.36.2+k3s1  10.0.0.1     Ubuntu 24.04.4 LTS   6.18.36-cloudflare-firecracker-2026.6.17  containerd://2.3.2-k3s2

$ kubectl get pods -o wide
NAME                      READY  STATUS   IP           NODE
nginx-64c5bb4997-24tz5    1/1    Running  10.42.0.2    cf-cloudchamber
nginx-64c5bb4997-j2tjw    1/1    Running  10.42.0.5    cf-cloudchamber
nginx-64c5bb4997-r9qf5    1/1    Running  10.42.0.3    cf-cloudchamber

$ kubectl create deployment demo --image=nginx:1.27-alpine --replicas=3
deployment.apps/demo created          #  → 3/3 READY in 31 seconds
```

Confirmed working:

- **Real control plane** — apiserver, scheduler, controller-manager, kine/SQLite. `/readyz` → `ok` in ~13 s.
- **Real kubelet + containerd 2.3.2**, cgroup v2, node reports `cpu: 2`, `memory: 8386004Ki`, `pods: 110`.
- **Real image pulls** from Docker Hub over container egress (~13 s for the coredns image).
- **Real CNI pod networking.** flannel `host-gw` with a `cni0` bridge and veth pairs; pods get 10.42.0.0/24
  addresses. Pod→pod across the bridge returns **HTTP 200** (`report/evidence/`, job `netdiag`).
  The mission expected to concede this entirely and run `hostNetwork: true` — not needed.
- **`kubectl` from a laptop**, including `get`, `create`, `scale`, `apply`, `delete`, `logs`, and `describe`.
- **`kubectl exec` works server-side** — run from inside the container it returns `SERVER_SIDE_EXEC_OK`.
  Only the Worker transport cannot carry it (§5.4).
- **Graceful restart** — killing k3s is caught by the supervisor and the cluster rebuilds unattended.

---

## 5. What does not work, and exactly why

### 5.1 flannel VXLAN — no vxlan device in the kernel

The first failure. k3s came up completely, then exited:

```
level=error msg="Shutdown request received: \"flannel exited: failed to register flannel
network: failed to create vxlan device: operation not supported\""
```

k3s treats flannel exiting as a shutdown request, so this killed the whole server ~40 s after boot.

**Fix (load-bearing):** `--flannel-backend=host-gw`. host-gw needs no vxlan device — on a single node it
is just a route plus the `cni0` bridge — so real pod networking survives. This is the single most
important flag in the build.

**Implication for multi-node:** VXLAN is how flannel spans nodes. With no vxlan device *and* no inbound
UDP, a cross-node pod overlay is not reachable on this platform. The mission predicted this; the reason
is different (no kernel support, not just UDP).

### 5.2 ClusterIP Services — three missing netfilter features

**Both** kube-proxy backends fail, for different reasons. This is the hard wall.

**iptables mode** — kube-proxy's `KUBE-FORWARD` chain includes an `nfacct` counter rule
(`-m conntrack --ctstate INVALID -m nfacct --nfacct-name ct_state_invalid_dropped_pkts -j DROP`), and the
kernel has no `xt_nfacct`:

```
exit status 4: Warning: Extension nfacct revision 0 not supported, missing kernel module?
iptables-restore v1.8.10 (nf_tables):
line 9: RULE_APPEND failed (No such file or directory): rule in chain KUBE-FORWARD
```

`iptables-restore` is transactional, so that one rule fails the **entire** sync and kube-proxy programs
*no* service rules at all. `KUBE-SERVICES` stays empty; every ClusterIP is a blackhole.

**nftables mode** (`--kube-proxy-arg=proxy-mode=nftables`) — fails on two missing nft expressions:

```
add rule ip kube-proxy reject-chain reject
                                    ^^^^^^   Could not process rule: No such file or directory

add rule ip kube-proxy service-…/kubernetes/tcp/https meta l4proto tcp \
    dnat ip addr . port to numgen random mod 1 map { 0 : 10.0.0.1 . 6443 }
                                          ^^^^^^^^^^^^^^^^^^^^^^  Could not process rule
```

`nft` itself works (v1.0.9, `inet` family verified good) — the kernel lacks the **`reject`** and
**`numgen`** expressions. `numgen` is precisely how kube-proxy implements DNAT load-balancing across
endpoints, so this is not a rule that can simply be dropped.

Because nothing is modprobe-able (`/lib/modules` and `/proc/modules` do not exist), there is no
workaround from inside the container. **ClusterIP Services require a Cloudflare kernel change.**

Measured directly from inside a pod (`kubectl logs job/netdiag`):

```
pod → pod direct (10.42.0.5)     : http 200      ✅
pod → ClusterIP nginx            : timed out     ❌
pod → ClusterIP kubernetes:443   : timed out     ❌
```

### 5.3 Cluster DNS — a downstream casualty

coredns stays `0/1 Running` forever, logging `plugin/ready: Plugins not ready: "kubernetes"`. It cannot
reach `kubernetes.default` because that is a ClusterIP (10.43.0.1), which §5.2 broke. Pods therefore have
no DNS and cannot resolve any name, internal or external.

This is a *consequence*, not an independent failure. **Untested but principled fix:** run coredns with
`hostNetwork: true` (so it talks to the apiserver on the node IP directly) and point kubelet at it with
`--cluster-dns=10.0.0.1`. That would restore DNS without needing kube-proxy. Recommended as the next
experiment; not attempted here.

### 5.4 `kubectl exec` through the Worker — the edge will not switch protocols

`kubectl exec` needs an HTTP connection upgrade. Through the Worker it fails:

```
error: unable to upgrade connection: 400 Bad Request   (served by Cloudflare's edge, not the Worker)
```

Two red herrings were eliminated along the way:

1. `kubectl proxy` ships a **default `--reject-paths` that blocks `pods/exec` and `pods/attach`** — that
   produced a 403 from the container, nothing to do with Cloudflare. Cleared with `--reject-paths=''`.
2. Rewriting the URL in the Worker built a *new* `Request`, which drops upgrade semantics. Fixed by
   running `kubectl proxy --api-prefix=/k8s/` so the Worker forwards the original request untouched.

After both fixes the remaining 400 comes from the Cloudflare edge rejecting `Upgrade: SPDY/3.1`. A
hand-crafted HTTP/1.1 **WebSocket** upgrade *does* traverse the edge and reach the container, so the edge
is not blocking upgrades in general — it will not switch to SPDY, and this `kubectl` did not negotiate the
WebSocket variant even with `KUBECTL_REMOTE_COMMAND_WEBSOCKETS=true`.

`exec` works fine inside the cluster. **The clean fix is the tunnel path (§7), which carries raw TLS to
6443 and never asks the edge to switch protocols.** Timeboxed and stopped per the spike's own rule.

### 5.5 Ephemeral disk is brutal during iteration

Every rollout replaces the instance and wipes the disk — cluster state, the k3s CA, and all logs. In
practice each config change cost a full ~90 s cluster rebuild, and any kubeconfig holding the old CA
would break (we sidestep this because the Worker path does not pin the cluster CA).

Also: **`--containers-rollout=immediate` is mandatory** for a single-instance app. The default rollout is
`[10, 100]`, and 10% of one instance rounds to zero, so deploys silently keep serving the old image. This
cost real time before it was spotted.

---

## 6. Platform limitations: policy vs architecture

**Policy limits (Cloudflare's choices — could change):**

- Containers require the **Workers Paid** plan. `containers/me` returns 401 on Free with
  *"Deploying containers requires the Workers Paid plan."* `wrangler deploy` surfaces this terribly: it
  builds the whole image, uploads the Worker (HTTP 200), then fails with a bare `Unauthorized`.
- Kernel feature set: no `xt_nfacct`, no nft `reject`/`numgen`, no vxlan, no loadable modules. These are
  build-time kernel config choices, not architecture.
- Edge will not perform a SPDY protocol switch.
- Ceiling of 4 vCPU / 12 GiB / 20 GB per instance; ≥3 GiB memory per vCPU; ≤2 GB disk per GiB memory.

**Architecture limits (inherent — will not change):**

- **No raw TCP inbound.** Everything enters through the Worker as HTTP/WebSocket, or via an
  outbound-initiated tunnel. This is why the apiserver cannot simply be exposed on 6443.
- **Ephemeral disk.** Sleep, eviction, or host restart returns a blank disk. Any durable cluster state
  needs external replication (Litestream → R2 was scoped but not attempted).
- **No inbound UDP**, which independently rules out a VXLAN overlay between instances.
- Single-tenant microVM per container, so no shared-kernel escape concerns — the reason the capability
  set is so generous.

**Notably *not* limitations, contrary to the brief:** rootless execution, dropped capabilities, seccomp
confinement, blocked netfilter, missing cgroup delegation, missing `/dev/net/tun`, `/dev/kmsg`, `/dev/fuse`.

---

## 7. kubectl access: two paths

### 7.1 Worker passthrough — built and working

`kubectl proxy` inside the container terminates the apiserver's TLS and re-exposes the API over plain
HTTP; the Worker forwards `/k8s/*` to it, gated by a shared secret. No tunnel, no DNS, no Access.

```
laptop kubectl ──HTTPS──▶ Worker (/k8s/*, bearer-token gated) ──▶ container :8001 kubectl proxy ──▶ apiserver :6443
```

Carries everything except connection upgrades (§5.4). Worth knowing: this converts cluster-admin credentials into a single bearer token. Whoever holds the
token owns the cluster. That is the whole security model — decide accordingly.

### 7.2 Named tunnel — configured, blocked on one DNS record

Tunnel `kubeflare` (`<TUNNEL_ID>`) exists with ingress
`tcp://localhost:6443`, its token is stored as a Worker secret, and `cloudflared` runs in the container.
The apiserver cert already carries the right SAN (`--tls-san kubeflare.example.com`).

**One step is missing and I could not do it:** the wrangler OAuth token has **no DNS permission at all**
(reads *and* writes return `Authentication error`), so the CNAME cannot be created. Someone with DNS
access must add:

```
kubeflare.example.com  CNAME  <TUNNEL_ID>.cfargotunnel.com  (proxied)
```

Then, locally:

```bash
cloudflared access tcp --hostname kubeflare.example.com --url 127.0.0.1:6443
```

with a kubeconfig pointing at `https://127.0.0.1:6443`. That path carries native TLS and **should restore
`kubectl exec`, `port-forward`, and `attach`** — untested, since it was never reachable.

> **Security note.** An earlier tunnel token was briefly readable on the public dashboard via the process
> list. That tunnel was **deleted and replaced**, the dashboard now redacts secrets, and every endpoint
> except `/healthz` requires the bearer token. The exposed token is dead.

---

## 8. Cost

Cloudflare bills containers per 10 ms of active runtime: **$0.0000025 per GiB-s memory, $0.000020 per
vCPU-s, $0.00000007 per GB-s disk**, on top of the $5/month Workers Paid minimum. Included monthly:
25 GiB-hours memory, 375 vCPU-minutes, 200 GB-hours disk.

For our instance (2 vCPU / 8 GiB / 16 GB):

| Component | Rate | Per hour |
|---|---|---|
| Memory 8 GiB | $0.009 / GiB-hr | $0.0720 |
| Disk 16 GB | $0.000252 / GB-hr | $0.0040 |
| **Provisioned floor (0% CPU)** | | **$0.0760** |
| CPU at ~10% of one core (idle k3s) | $0.072 / vCPU-hr | +$0.0072 |
| **Realistic running cost** | | **≈ $0.083 / hr ≈ $2.00 / day** |
| Absolute ceiling (both vCPUs pinned) | | $0.220 / hr = $5.28 / day |

The included allotments cover **the first ~3 h 07 m of instance uptime per month at $0** above the $5
base. A 3-hour demo is free; 24 h continuous is ~$1.55.

Cost control: the container sleeps after `sleepAfter` (set to `2h` here deliberately — a shorter timeout
wipes the cluster mid-test). A sleeping instance is not billed for active runtime.

---

## 9. The load-bearing configuration

Full sources in the repo; these are the parts that actually decide success or failure.

**k3s invocation** (`container/full/entrypoint.sh`):

```bash
k3s server \
  --node-name "cf-$(hostname)" \
  --disable traefik,servicelb,metrics-server \
  --write-kubeconfig-mode 644 \
  --tls-san 127.0.0.1 --tls-san localhost --tls-san "$TUNNEL_HOSTNAME" \
  --flannel-backend=host-gw \
  --kube-proxy-arg=proxy-mode=nftables
```

- `--flannel-backend=host-gw` — **mandatory.** vxlan is fatal (§5.1).
- `--kube-proxy-arg=proxy-mode=nftables` — does not fix Services, but fails cleanly rather than
  spamming `iptables-restore` errors. Either mode leaves ClusterIP broken.
- `--tls-san` must include the tunnel hostname *and* `127.0.0.1` for the tunnel path to validate.

**Ordering in the entrypoint is load-bearing.** The status server binds `:8080` *before* k3s starts,
because Cloudflare considers the container ready only when `defaultPort` accepts connections and k3s
takes 30–60 s. PID 1 traps `SIGTERM`, restarts dead children, and reaps zombies.

**Other decisions that mattered:**

- `nftables` and `ipset` packages must be installed — kube-proxy's nftables mode shells out to `nft`,
  which Ubuntu's base image does not ship, and k3s's bundled bin directory contains only `ipset`.
- k3s version is **pinned** (`v1.36.2+k3s1`); `update.k3s.io` answers the channel query with a 302 to
  a GitHub HTML page rather than JSON, and the `+` in the tag must be percent-encoded as `%2B`.
- `k3s kubectl` is used throughout, so no separate kubectl in the image.
- `sysctl net.ipv4.ip_forward=1` succeeds (we hold `CAP_NET_ADMIN`); `modprobe br_netfilter` fails
  harmlessly — the bridge-netfilter sysctls are built in and already present.

**Repo layout:**

| Path | Role |
|---|---|
| `container/full/` | **The working build** — full k3s, real node |
| `container/` | Phase 0 probe image (`probe.sh`, 24 verdicts) |
| `container/phase1/`, `container/phase2/` | Rootless/kwok fallbacks — validated locally, unnecessary here |
| `src/index.ts` | Worker: `/k8s/*` API passthrough, gated dashboard, `/healthz`, `/_keepalive` |
| `wrangler.full.jsonc` | Deploy config for the working build |
| `scripts/preflight.sh` | Entitlement check — run before any build |
| `scripts/teardown.sh` | Deletes everything prefixed `kubeflare`; dry-run by default |
| `kubeconfig.yaml` | Laptop kubeconfig (contains the guard token) |
| `report/evidence/` | Raw captures backing every claim here |

---

## 10. Demo script (3 minutes)

```bash
cd /Users/matanya/k8sflare && export KUBECONFIG=$PWD/kubeconfig.yaml
```

```bash
curl -s https://kubeflare.<your-subdomain>.workers.dev/healthz
```

Wake the container (cold start ≈ 90 s to a working cluster), then:

```bash
kubectl get nodes -o wide
```

Point at `KERNEL-VERSION: 6.18.36-cloudflare-firecracker` and `CONTAINER-RUNTIME: containerd://2.3.2-k3s2`
— a real node, on Cloudflare's edge, in `dfw01`.

```bash
kubectl get pods -o wide
```

Three nginx pods `Running` with 10.42.0.x pod IPs — real CNI, not hostNetwork.

```bash
kubectl create deployment demo --image=nginx:1.27-alpine --replicas=3 && sleep 30 && kubectl get deploy
```

`3/3` in about 30 seconds, image pulled from Docker Hub through the container's egress.

```bash
kubectl scale deployment demo --replicas=8 && kubectl get pods -l app=demo
```

```bash
kubectl logs -l app=nginx --tail=5
```

Closing line: *the control plane, the kubelet, and containerd are all real; the only thing missing is
ClusterIP Services, because Cloudflare's kernel omits three netfilter features.*

---

## 11. Recommended next steps

1. **Cluster DNS without kube-proxy** — coredns as `hostNetwork: true` plus `--cluster-dns=10.0.0.1`.
   Highest value per effort; would make the cluster genuinely usable for hostNetwork workloads.
2. **Add the tunnel DNS record** (§7.2) and confirm `kubectl exec`/`port-forward` over native TLS.
3. **Ask Cloudflare for `xt_nfacct`, nft `reject` + `numgen`, and `vxlan`.** Three small kernel config
   flags stand between this and a fully working single-node Kubernetes.
4. **Litestream → R2** for the kine SQLite DB, to survive the ephemeral disk (Phase 3, unattempted).
5. Multi-node is a dead end without an overlay: no inbound UDP and no vxlan device.

---

## 12. Teardown

```bash
./scripts/teardown.sh
```

Dry-run by default. Re-run with `--yes` to delete the Worker, container application, tunnel, and any
matching DNS/R2/D1 resources. **The cluster was left running deliberately** so the demo above works —
it costs roughly $0.08/hour until torn down or until it sleeps.
