# kubeflare Kubernetes API conformance matrix

What the Kubernetes API on this cluster **actually does**, measured against the live
deployment rather than inferred from the architecture.

- Cluster: single-node k3s `v1.36.2+k3s1`, kernel `6.18.36-cloudflare-firecracker`,
  Cloudflare Container (Firecracker microVM), 2 vCPU / 8 GiB / 110-pod cap.
- Node `kubeflare`, node IP `10.0.0.1`, pod CIDR `10.42.0.0/24`, service CIDR `10.43.0.0/16`.
- kube-proxy is **disabled entirely**; ClusterIPs are served by `svcproxy/`, a userspace
  proxy on an AnyIP-routed service CIDR. coredns and local-path-provisioner are
  vendored; traefik, servicelb and metrics-server are off.
- Client `kubectl` v1.33.9 against a v1.36 server (three minor versions of skew; it warns,
  and everything below still worked).

Status vocabulary:

| Status | Meaning |
|---|---|
| **WORKS** | behaves as stock Kubernetes would |
| **WORKS-WITH-CAVEATS** | works, with a documented behavioural difference |
| **BROKEN** | accepted by the API but does not function |
| **N-A-SINGLE-NODE** | structurally impossible with one node |
| **UNTESTED** | not established — reason given, never a guess |

## Summary count

| Status | Count |
|---|---|
| WORKS | 153 |
| WORKS-WITH-CAVEATS | 9 |
| BROKEN | 16 (14 distinct; `kubectl top` and `get --raw` are listed in two sections) |
| N-A-SINGLE-NODE | 4 |
| UNTESTED | 15 |
| **Total rows** | **197** |

The headline: **the Kubernetes API surface is essentially complete and correct.** Every
controller, admission path, scheduler feature, storage primitive and kubectl subcommand
tested behaves like real Kubernetes. What breaks is confined to two root causes — things
that need inbound TCP the platform does not offer, and things that need netfilter
features this kernel does not compile in. Plus one genuine security defect (below).

## Read this first: three findings that change how you should use the cluster

**1. Any pod is cluster-admin, unauthenticated.** The container runs `kubectl proxy` so
the Worker can forward plain HTTP to it, and that proxy holds the real cluster-admin
kubeconfig with **no authentication**. `container/entrypoint.sh` launches it as:

```
k3s kubectl proxy --port=8001 --address=0.0.0.0 \
  --accept-hosts='.*' --accept-paths='.*' --reject-paths=''
```

`--address=0.0.0.0` puts it on every interface — including the `cni0` pod bridge and,
because the AnyIP route makes the whole service CIDR node-local, every address in
`10.43.0.0/16`. `--accept-hosts='.*'` accepts any Host header, and `--reject-paths=''`
removes the default guard on `pods/exec` and `pods/attach`.

Verified from an unprivileged busybox pod whose ServiceAccount may only *read
ConfigMaps*: read every Secret in `kube-system`, list nodes, create objects, and mint
ServiceAccount tokens via `TokenRequest` (HTTP 201) — all with no credentials, at both
`10.0.0.1:8001` and an arbitrary `10.43.77.77:8001`. RBAC is enforced correctly on the
normal path and bypassed entirely on this one, so in-cluster RBAC and any notion of
multi-tenancy are currently unsound.

Binding to `127.0.0.1` is *not* an available fix: the Worker reaches the container over
its network interface, not loopback. The workable mitigation is a host firewall rule
dropping pod-CIDR traffic to the two node-local admin ports, using only basic matches
this kernel does support:

```
iptables -I INPUT -s 10.42.0.0/24 -p tcp --dport 8001 -j DROP   # kubectl proxy
iptables -I INPUT -s 10.42.0.0/24 -p tcp --dport 8080 -j DROP   # status dashboard
```

(That is a `container/` change, out of scope for this document. The `container/` edits
currently pending in the working tree do not touch it.)

**2. NetworkPolicy is accepted and silently does nothing.** Not partially — nothing.
Ingress and egress, ClusterIP and direct pod IP, from a pod with no prior conntrack
state, including `deny-all` egress to the internet: all traffic flows. Root cause found
in the node log — this kernel has no `NFLOG` target, and kube-router's netpol controller
writes a `-j NFLOG` rule into every pod firewall chain, so its transactional
`iptables-restore` aborts and the whole ruleset is discarded:

```
network_policy_controller.go:334] Aborting sync. Failed to run iptables-restore:
exit status 4 (Warning: Extension NFLOG revision 0 not supported, missing kernel module?
iptables-restore v1.8.10 (nf_tables):
line 46: RULE_APPEND failed (No such file or directory): rule in chain KUBE-NWPLCY-...
```

This is the **same failure mode** as kube-proxy's `xt_nfacct` problem in
`docs/FINDINGS.md`, on a component the docs never mention. `xt_NFLOG` belongs on the
list of kernel gaps to ask Cloudflare for; it is currently absent from both README and
FINDINGS.

**3. `kubectl get --raw <path>` lies.** The kubeconfig server URL is
`https://<worker>/k8s`, and `--raw` keeps only the host, discarding the path prefix. A
bare `kubectl get --raw /readyz` therefore hits the Worker's dashboard route which —
because the kubeconfig token doubles as the dashboard token — returns **HTTP 200 with
HTML**. It looks like a pass while never touching the apiserver. Any health check built
on it is worthless. The fix needs no curl: spell the prefix,
`kubectl get --raw /k8s/readyz`.

---

## Cluster, discovery, transport

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| apiserver reachable through the Worker | WORKS | `kubectl get --raw /k8s/readyz` → `ok`; `/k8s/livez`, `/k8s/healthz` → `ok` | |
| `/k8s/readyz?verbose` poststart hooks | WORKS | all hooks `ok`, `readyz check passed` | |
| Server version | WORKS | `kubectl version` → `v1.36.2+k3s1` | |
| Node Ready, 2 cpu / 110 pods | WORKS | `kubectl get node kubeflare -o wide`; allocatable `cpu:2 pods:110` | |
| Discovery: 25 group/versions, 73 resource kinds | WORKS | `kubectl api-versions` → 25; `kubectl api-resources` → 73 | |
| `kubectl explain` (built-in and CRD) | WORKS | `explain deployment.spec.strategy`; `explain widget.spec` shows CRD enum | |
| OpenAPI v2 / v3 | WORKS | `--raw /k8s/openapi/v2` → `{"swagger":"2.0"...}`; v3 returns the path index | |
| apiserver `/metrics` | WORKS | `--raw /k8s/metrics` → `apiserver_storage_objects{...}` populated | |
| `kubectl get --raw` with a bare path | **BROKEN** | `--raw /version` returns the Worker dashboard HTML, not JSON | `--raw` drops the kubeconfig `/k8s` path prefix; the Worker catch-all serves the dashboard, and the kubeconfig token is also the dashboard token, so it 200s. Transport artifact, not a cluster limit. A Cloudflare Tunnel to `:6443` (native TLS, no prefix) would remove it |
| External auth as any identity but the guard token | **BROKEN** | `kubectl --token=<SA token> get cm` → `Forbidden: forbidden` from the Worker | the Worker compares the bearer token to `KUBE_GUARD` before forwarding; exactly one external identity exists. `--as=` impersonation is the only way to exercise other subjects from outside |
| Container status server reachable from pods | WORKS-WITH-CAVEATS | pod → `10.0.0.1:8080` and any `10.43.x.x:8080` returns the dashboard (`Server: BaseHTTP/0.6 Python/3.12.3`) | AnyIP makes the whole service CIDR node-local; see the security row |

## Workloads

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| Pod create / run / delete | WORKS | throughout the suite | |
| Deployment + rollout | WORKS | `rollout status deployment/roll` → successfully rolled out | |
| ReplicaSet (direct) | WORKS | `readyReplicas=2` | |
| DaemonSet | WORKS | `numberReady=1` on the one node | |
| StatefulSet ordinals | WORKS | pods `sts-0`, `sts-1` | |
| StatefulSet `volumeClaimTemplates` | WORKS | `data-sts-0`, `data-sts-1` both `Bound` | |
| StatefulSet stable network identity | WORKS | `sts-0.sts.<ns>.svc.cluster.local` → `10.42.0.20`; fetched `/id` → `sts-0` |  |
| StatefulSet volume reattach keeps data | WORKS | wrote marker, deleted `sts-0`, marker survived recreate | |
| StatefulSet PVC retention on scale-down | WORKS | scaled 2→1, `data-sts-1` still `Bound` (default `Retain`) | |
| `podManagementPolicy: Parallel` | WORKS | both replicas started together | |
| Job | WORKS | completes | |
| Job `completionMode: Indexed` | WORKS | `completedIndexes=0-3`, `succeeded=4`; `JOB_COMPLETION_INDEX` present per pod | |
| Job `parallelism` | WORKS | 2 at a time to 4 completions | |
| Job `backoffLimit` | WORKS | `backoffLimit:2` → `failed=3`, `Failed=True(BackoffLimitExceeded)` | |
| CronJob scheduling | WORKS | `lastScheduleTime` set; job `cj-29756333` ran | |
| CronJob `suspend` | WORKS | patched true/false, reflected in `.spec.suspend` | |
| CronJob `concurrencyPolicy: Forbid` | WORKS | accepted and honoured over several minutes | |
| ReplicationController (legacy) | UNTESTED | served in discovery; superseded by ReplicaSet, not exercised | |
| ControllerRevision history | WORKS | 3 ReplicaSets retained across rollouts | |

## Services and networking

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| ClusterIP by IP | WORKS | pod → `10.43.87.133:80` → backend hostname | |
| ClusterIP by short name and FQDN | WORKS | `http://echo/`, `http://echo.<ns>.svc.cluster.local/` | |
| Round-robin across endpoints | WORKS | 6 requests → 3/3 across two backends | |
| Named `targetPort` | WORKS | `port: 80 → targetPort: http` resolves | |
| UDP Services | WORKS | `nc -u echo 90` → agnhost UDP reply | |
| Multi-port Services | WORKS-WITH-CAVEATS | ports 9090 + 9091 both reach the backend | a Service port that collides with a **host** listener is hijacked — see next row |
| Service port colliding with a node listener | **BROKEN** | `Service` on `10250` returned the kubelet's `HTTP/1.0 400`, not the backend; a Service on `8080` returned the status dashboard | AnyIP `local 10.43.0.0/16` makes every service IP node-local. If svcproxy cannot bind `ClusterIP:port` (a host process already owns `0.0.0.0:port`), the connection silently falls through to that host process. Occupied: 53, 6443, 8001, 8080, 10250 |
| Unallocated ClusterIP reaches host ports | **BROKEN** | `10.43.99.99:8080` from a pod → status dashboard | same AnyIP fall-through; the whole /16 is a wildcard alias for node-local ports |
| Headless Service (`clusterIP: None`) | WORKS | DNS returns every ready pod IP | |
| ExternalName Service | WORKS | resolves `CNAME → example.com` | |
| EndpointSlices | WORKS | populated with pod IPs and ports for every Service | |
| `kubernetes.default` from a pod | WORKS | agnhost `inclusterclient` repeatedly called `/healthz` with its own SA token | |
| `KUBERNETES_SERVICE_HOST` | WORKS | `10.43.0.1` — the real ClusterIP. The historical `10.0.0.1` workaround is no longer needed | |
| Pod-to-pod direct | WORKS | `10.42.0.17 → 10.42.0.15:8080` | |
| Pod egress to the internet (HTTP + HTTPS) | WORKS | fetched `example.com` over both | |
| NodePort object allocation | WORKS | `nodePort: 32514` assigned | |
| NodePort data path | **BROKEN** | `nc -z 10.0.0.1 32514` from a pod → refused; same on 127.0.0.1 | svcproxy binds the ClusterIP only and never opens a NodePort listener. Independently, no inbound TCP reaches the container except through the Worker |
| `type: LoadBalancer` object | WORKS-WITH-CAVEATS | accepted, allocated `nodePort: 31683` | `EXTERNAL-IP` stays `<pending>` forever |
| `type: LoadBalancer` provisioning | **BROKEN** | `status.loadBalancer` `{}` | k3s runs `--disable servicelb`; no cloud LB controller. Would need a controller minting Cloudflare Tunnel hostnames per Service |
| Source IP preservation | **BROKEN** | backend saw `10.42.0.1` via the Service vs the true `10.42.0.17` direct | svcproxy re-originates each connection from the node, so backends see the `cni0` bridge address. Breaks IP allowlists and source-based policy |
| `sessionAffinity: ClientIP` | **BROKEN** | 8 requests split 4/4 across backends | not implemented by svcproxy; silently ignored |
| NetworkPolicy object acceptance | WORKS | objects accepted and stored | |
| NetworkPolicy **enforcement** | **BROKEN** | default-deny ingress, direct-pod-IP, and deny-all-egress all still passed, from a fresh pod | kernel has no `NFLOG` target; kube-router emits `-j NFLOG` per pod chain and its transactional `iptables-restore` aborts (`Aborting sync … Extension NFLOG revision 0 not supported`), discarding the entire ruleset. Same class as kube-proxy's missing `xt_nfacct` |
| Ingress object acceptance | WORKS | object stored with rules and host | |
| Ingress controller / data path | **BROKEN** | 0 IngressClasses, 0 controller pods, `status.loadBalancer` empty | k3s runs `--disable traefik` and nothing is vendored back. See the recommendation below — this is now fixable |
| kube-dns ClusterIP `10.43.0.10` | WORKS | resolves through svcproxy | |
| Multi-node overlay / cross-node LB | N-A-SINGLE-NODE | one node | flannel vxlan unsupported on this kernel, no inbound UDP |
| SCTP Services | UNTESTED | svcproxy skips SCTP by design; kernel support not probed | |
| IPv6 / dual-stack | UNTESTED | cluster is single-stack IPv4 and svcproxy is IPv4-only | |
| `topologyKeys` / topology-aware routing | N-A-SINGLE-NODE | one topology domain | |

## DNS

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| Pod `resolv.conf` points at the node IP | WORKS | `nameserver 10.0.0.1`, correct search list, `ndots:5` | |
| Service A record (short, FQDN) | WORKS | `echo` → `10.43.87.133` | |
| Headless per-pod A records | WORKS | multiple `10.42.x.x` answers | |
| StatefulSet per-pod A records | WORKS | `sts-0.sts.<ns>.svc.cluster.local` | |
| SRV records | WORKS | `_http._tcp.echo.<ns>.svc.cluster.local` → `0 100 80 echo...` | |
| PTR / reverse for ClusterIP | WORKS | `133.87.43.10.in-addr.arpa` → `echo.<ns>.svc.cluster.local` | |
| PTR / reverse for pod IP | WORKS | → `10-42-0-15.echo.<ns>.svc.cluster.local` | |
| CNAME via ExternalName | WORKS | → `example.com` | |
| External name resolution | WORKS | `example.com` resolves and fetches | |
| DNS via the `kube-dns` ClusterIP | WORKS | explicit `nslookup … 10.43.0.10` | |
| `dnsPolicy` / `dnsConfig` overrides | UNTESTED | defaults exercised throughout; custom policies not probed | |

## Config and identity

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| ConfigMap as env (`configMapKeyRef`) | WORKS | `FROM_CM=val1` | |
| Secret as env (`secretKeyRef`) | WORKS | `FROM_SEC=s3cr3t` | |
| `envFrom` ConfigMap and Secret | WORKS | `KEY2=val2`, `USER=admin` | |
| ConfigMap as volume | WORKS | keys present as files | |
| Secret as volume + `defaultMode` | WORKS | mounted, symlinked through `..data` | |
| `subPath` single-key mount | WORKS | `/etc/sub/only.conf` = two-line file | |
| Projected volume (4 sources at once) | WORKS | configMap + secret + downwardAPI + `serviceAccountToken` in one mount | |
| Downward API: metadata / status / spec | WORKS | pod name, pod IP, node name, annotation key | |
| Downward API: `resourceFieldRef` | WORKS | `MEM_REQ=33554432` | |
| ServiceAccount token projection (audience, expiry) | WORKS | 1125-byte token at the requested path | |
| Default SA token, `ca.crt`, `namespace` | WORKS | present under `/var/run/secrets/kubernetes.io/serviceaccount/` | |
| Pod calls the API with its own token | WORKS | agnhost `inclusterclient` succeeded via `kubernetes.default` | must use a real TLS client; busybox cannot (see below) |
| busybox HTTPS to the apiserver | WORKS-WITH-CAVEATS | peer TLS alert 47, identically against `10.0.0.1:6443` and the ClusterIP | busybox's built-in TLS offers no cipher suite the apiserver accepts. **A client limitation, not a cluster one** — testing this with busybox produces a false BROKEN |
| RBAC Role + RoleBinding allow | WORKS | `auth can-i get configmaps --as=…` → `yes` | |
| RBAC deny (verb and resource) | WORKS | `delete configmaps` → `no`; `list secrets` → `no` | |
| RBAC deny on a real request | WORKS | impersonated `get secrets` → `Forbidden: cannot list resource "secrets"` | |
| ClusterRole + ClusterRoleBinding | WORKS | granted `get nodes` cluster-wide, confirmed with `can-i` | |
| SelfSubjectRulesReview | WORKS | `auth can-i --list` enumerates granted rules | |
| TokenRequest API | WORKS | `kubectl create token` returns a usable token (usable in-cluster, not through the Worker) | |
| **RBAC as a security boundary** | **BROKEN** | unprivileged pod read all `kube-system` Secrets and minted SA tokens via `10.0.0.1:8001` | node-local `kubectl proxy` holds cluster-admin and requires no auth; AnyIP makes it reachable from every pod. RBAC itself is correct — the bypass is the transport |
| Pod Security Admission | UNTESTED | no `pod-security.kubernetes.io/*` namespace labels applied in this run | |
| CertificateSigningRequest flow | UNTESTED | API served; signer behaviour not exercised | |

## Storage

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| PVC → PV provisioning (`local-path`) | WORKS | `standalone-pvc` `Bound` to a `pvc-…` PV | |
| RWO access mode | WORKS | `ReadWriteOnce` honoured | |
| `WaitForFirstConsumer` binding | WORKS | PVC stays `Pending` until a pod consumes it | |
| Read/write through a PVC | WORKS | wrote and read back inside the pod | |
| `emptyDir` | WORKS | writable scratch | |
| `hostPath` | WORKS | mounted the node's `/etc` read-only | |
| Generic ephemeral inline volume | WORKS | `kitchen-eph` PVC auto-created, then reclaimed with the pod | |
| `reclaimPolicy: Delete` | WORKS | PV removed after the PVC was deleted | |
| Default StorageClass | WORKS | `local-path (default)` | |
| PV data durability across instance replacement | UNTESTED | not exercised — restarting the container is out of scope for this suite (another workstream owns deploys) | by design PV data lives on the ephemeral node disk and only the kine datastore is replicated to R2, so it is *expected* not to survive; that expectation was not measured here |
| RWX / ROX volumes | N-A-SINGLE-NODE | `local-path` provisions RWO only | |
| CSI drivers / VolumeSnapshots | UNTESTED | `kubectl get csidrivers` is empty; no CSI driver installed | |
| Volume expansion | UNTESTED | `local-path` sets `allowVolumeExpansion=false` | |
| `juicefs-r2` StorageClass | UNTESTED | not present in the running cluster (roadmap only) | |

## Scheduling

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| Resource requests / limits | WORKS | applied and reflected in the pod spec | |
| QoS `Guaranteed` | WORKS | requests == limits → `Guaranteed` | |
| QoS `Burstable` | WORKS | requests < limits → `Burstable` | |
| QoS `BestEffort` | WORKS | neither set → `BestEffort` | |
| `nodeSelector` (match) | WORKS | `kubernetes.io/hostname: kubeflare` scheduled | |
| `nodeSelector` (no match) | WORKS | stays `Pending`, `FailedScheduling: didn't match Pod's node affinity/selector` | |
| `nodeAffinity` required | WORKS | `kubernetes.io/os In [linux]` scheduled | |
| `podAffinity` required | WORKS | co-located with the target pod | |
| `podAntiAffinity` required | WORKS-WITH-CAVEATS | correctly `Pending`: `didn't match pod anti-affinity rules` | the mechanism is correct, but with one node hostname anti-affinity can never place a second pod — it buys you nothing here |
| `topologySpreadConstraints` | WORKS-WITH-CAVEATS | both replicas admitted (`maxSkew:1`, `DoNotSchedule`) | one topology domain, so skew is always 0 and the constraint is vacuous |
| Taints and tolerations | WORKS | untolerating pod `Pending` with `had untolerated taint(s)`; tolerating pod `Running`; taint removed cleanly | |
| PriorityClass | WORKS | custom classes created and applied | |
| **Preemption** | WORKS | high-priority pod evicted the low-priority one: `Preempted by pod … on node kubeflare` | |
| ResourceQuota hard limits | WORKS | `exceeded quota: rq, requested: requests.cpu=500m … limited: 200m` | |
| ResourceQuota forces requests | WORKS | `must specify requests.cpu` for a pod with none | |
| ResourceQuota object counts | WORKS | `pods`, `configmaps` counted in `.status.used` | |
| LimitRange default injection | WORKS | pod with no resources got `cpu:30m/60m`, `memory:24Mi/48Mi` | |
| LimitRange `max` / `min` enforcement | WORKS | `maximum cpu usage per Container is 100m`; `minimum … is 5m` | |
| `PodDisruptionBudget` status | WORKS | `disruptionsAllowed` tracks replicas correctly | |
| Eviction subresource | WORKS | `201` when within budget | |
| PDB blocks over-budget eviction | WORKS | `429 TooManyRequests: Cannot evict pod as it would violate the pod's disruption budget` | |
| Multi-node spreading / drain | N-A-SINGLE-NODE | one node | |
| DRA (`resource.k8s.io`) | UNTESTED | API group served; no devices or drivers to claim | |
| RuntimeClass (`crun`, `wasmtime`, …) | UNTESTED | 10 RuntimeClasses registered by k3s; no matching runtime handlers verified | |

## Pod lifecycle

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| Init containers, ordered | WORKS | shared file read `init-1 init-2 sidecar main` in order | |
| **Native sidecar** (`initContainer` + `restartPolicy: Always`) | WORKS | `sidecar` shows a running state alongside the main container and keeps ticking | |
| `postStart` lifecycle hook | WORKS | hook file written | |
| `preStop` lifecycle hook | WORKS | ran before SIGTERM; observable in the delete timing | |
| Startup probe | WORKS | gated readiness until the server answered | |
| Readiness probe | WORKS | `Ready=True` only once serving | |
| Liveness probe failure restarts the container | WORKS | `restartCount=1`, events `Unhealthy` → `Killing` | |
| `terminationGracePeriodSeconds` honoured | WORKS | SIGTERM-ignoring container with `grace:8` took ~10s then SIGKILL | |
| SIGTERM delivery | WORKS | trapping container exited in 1s with `grace:30` | |
| `restartPolicy: Never` | WORKS | `Failed`, 0 restarts | |
| `restartPolicy: OnFailure` | WORKS | restarted repeatedly | |
| `restartPolicy: Always` | WORKS | default throughout | |
| Ephemeral containers (`kubectl debug`) | WORKS | `dbg` container running and `exec`-able, with `--target` | |
| Image pulls from Docker Hub | WORKS | all three images pulled over container egress | |
| `hostNetwork`, `hostPID`, `privileged` pods | WORKS | used a privileged hostNetwork pod to read node sysctls | |
| Pod `readinessGates` | UNTESTED | not exercised | |

## API machinery

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| CRD create + `Established` | WORKS | condition met | |
| Custom resource instances | WORKS | created and listed | |
| CRD structural schema validation | WORKS | `spec.size: 99` → `should be less than or equal to 10`; bad enum → `Unsupported value` | |
| CRD `additionalPrinterColumns` | WORKS | `SIZE` column rendered | |
| CRD short names | WORKS | `kubectl get wid` | |
| CRD `status` subresource | WORKS | declared and accepted | |
| `kubectl explain` on a CRD | WORKS | shows the enum from the schema | |
| Server-side apply + field ownership | WORKS | `managedFields` records `mgr-a` | |
| SSA conflict detection | WORKS | `conflict with "mgr-a": .data.owner` | |
| SSA `--force-conflicts` | WORKS | ownership transferred | |
| Strategic merge patch | WORKS | env added to a Deployment pod template | |
| JSON merge patch | WORKS | key added | |
| JSON patch (`add`, `remove`) | WORKS | both ops applied | |
| `--dry-run=server` | WORKS | validated, assigned a UID, not persisted | |
| Label selectors (equality, set, negation) | WORKS | all three forms | |
| Field selectors | WORKS | `status.phase=Running`, `type=Normal` on events | |
| Pagination / `continue` tokens | WORKS | `limit=2` returned a `continue` token | |
| `kubectl --chunk-size` | WORKS | listed across pages | |
| `resourceVersion` optimistic concurrency | WORKS | stale RV replace → `Conflict … object has been modified` | |
| `watch` | WORKS | ADDED event for a new ConfigMap | |
| Events (core + `events.k8s.io`) | WORKS | both APIs populated | |
| **ValidatingAdmissionPolicy (CEL)** | WORKS | denied a ConfigMap without the required label, admitted one with it; enforced even on the unauthenticated proxy path | |
| MutatingAdmissionPolicy | UNTESTED | `admissionregistration.k8s.io/v1` serves it; not exercised | |
| **Admission webhook delivery** | WORKS-WITH-CAVEATS | apiserver reached the Service: `Post "https://echo.<ns>.svc:80/webhook": http: server gave HTTP response to HTTPS client`; missing-Service contrast → `service … not found` | delivery and Service resolution are proven. A full admit/deny was **not** run: that needs a TLS-serving webhook backend with a matching `caBundle`, which the suite does not build |
| **API aggregation** | WORKS | APIService dialed the backend pod: `failing or missing response from https://10.42.0.16:8080/apis/…: http: server gave HTTP response to HTTPS client` — resolution and TCP both succeeded | aggregation dials pod endpoints directly, so it does not even depend on svcproxy |
| `metrics.k8s.io` API | **BROKEN** | `--raw /k8s/apis/metrics.k8s.io/v1beta1` → `NotFound`; no APIService registered | k3s runs `--disable metrics-server` and nothing is vendored back |
| `kubectl top` | **BROKEN** | `error: Metrics API not available` (nodes and pods) | same |
| HPA object creation | WORKS | accepted, `AbleToScale=True` | |
| HPA actual scaling | **BROKEN** | `ScalingActive=False`, `reason=FailedGetResourceMetric` | no Metrics API to read from |
| FlowSchema / PriorityLevelConfiguration | WORKS-WITH-CAVEATS | APF headers present on responses (`X-Kubernetes-Pf-Flowschema-Uid`) | objects served; custom flow behaviour not exercised |
| Leases (`coordination.k8s.io`) | WORKS | in use by the control plane | |
| `helm.cattle.io` / `k3s.cattle.io` CRDs | UNTESTED | k3s-specific groups served; HelmChart install not exercised | |

## kubectl surface (all through the Worker's WebSocket transport)

| Feature / API | Status | Evidence | Root cause if not working |
|---|---|---|---|
| `get` / `create` / `apply` / `delete` / `describe` | WORKS | throughout | |
| `logs` | WORKS | streamed container output | |
| `logs --previous` | WORKS | returned the prior incarnation, distinct from current | |
| `logs --follow` | WORKS | streamed live | |
| `exec` | WORKS | used for most in-cluster assertions | |
| `attach` | WORKS | connected over WebSocket | |
| `cp` (in and out) | WORKS | round-tripped a file both directions | |
| `port-forward` | WORKS | `curl 127.0.0.1:18080` reached the pod | |
| `rollout status` / `history` / `undo` / `restart` | WORKS | all four; `undo` restored the previous image | |
| `scale` | WORKS | 2 → 3 replicas | |
| `wait` (`--for=condition`, `--for=jsonpath`, `--for=delete`) | WORKS | all three forms | |
| `diff` | WORKS | showed the pending replica change | |
| `apply --prune` | WORKS | pruned the object dropped from the manifest set | |
| `debug` (ephemeral container) | WORKS | see pod lifecycle | |
| `auth can-i` (incl. `--as`, `--list`) | WORKS | see RBAC | |
| `top` | **BROKEN** | no Metrics API | |
| `get --raw` (bare path) | **BROKEN** | see transport | |
| Client/server version skew | WORKS-WITH-CAVEATS | kubectl 1.33.9 vs server 1.36.2 | warns about exceeding ±1 minor skew; nothing observed to misbehave, but a matching client is safer |

---

## Can metrics-server and HPA be enabled now?

**Yes — the evidence says metrics-server should work, and this is the single
highest-value change available.** Recommended, with one caveat.

metrics-server needs three things, and all three are now demonstrably present:

1. **To reach the kubelet's authenticated API on `10250`.** The port is open and
   reachable — confirmed by TCP connect from a pod, and by a Service on port 10250
   getting the kubelet's own `HTTP/1.0 400` (a plaintext request to a TLS port). It
   runs with `hostNetwork` or ordinary pod networking either way.
2. **To be reachable by the aggregation layer as `v1beta1.metrics.k8s.io`.** This was
   the historical blocker and it is now proven working: an APIService pointing at an
   in-cluster Service was dialed successfully at the pod endpoint
   (`https://10.42.0.16:8080/apis/…`), failing only because the backend spoke HTTP.
   Aggregation resolves endpoints directly, so it does not even depend on svcproxy.
3. **To reach the apiserver itself.** Works via `kubernetes.default` — proven by
   agnhost `inclusterclient`, with `KUBERNETES_SERVICE_HOST=10.43.0.1`.

Caveat: metrics-server normally needs `--kubelet-insecure-tls` (or the node CA) in a
k3s setup like this, and it must not be scheduled onto a Service port that collides
with a node listener. Once the Metrics API exists, `kubectl top` and HPA follow
directly — the HPA controller is already running and reports exactly one problem,
`FailedGetResourceMetric`. Nothing else about HPA is broken.

Note: `--disable metrics-server` was originally set partly because ClusterIP was
broken. That reason no longer holds.

## Can an Ingress controller be enabled now?

**Partly — and it is worth doing, but it cannot serve public traffic on its own.**

What works: an Ingress controller is an ordinary Deployment plus a Service, and it
needs to watch Ingress objects and reach backend pods. Ingress objects are accepted
and stored, pod-to-pod routing works, ClusterIP works, and the controller can reach
the apiserver. Traefik or ingress-nginx would come up, program its routing table, and
correctly proxy to backends **for traffic that reaches it**.

What does not: the controller's own entry point. It normally publishes via NodePort or
`type: LoadBalancer`, and **both are broken here** — no NodePort listener is ever
opened, and no inbound TCP reaches the container except through the Worker. So an
Ingress controller would be reachable only from inside the cluster.

The honest recommendation: enabling an Ingress controller is worthwhile as a
correctness/compatibility win — it makes Helm charts that ship Ingress objects behave,
and gives in-cluster host/path routing. To make it externally reachable, the Worker
would have to forward HTTP to the controller's ClusterIP (the same trick already used
for `kubectl proxy`), or a Cloudflare Tunnel would have to terminate at it. That is a
`container/` and Worker change, so it is out of scope here, but nothing in the kernel
blocks it — unlike NetworkPolicy, this is an architecture choice rather than a wall.

## Claims in the existing docs that this run contradicts

- **`README.md` says node name `cf-cloudchamber`; the live node is `kubeflare`.** Cosmetic,
  expected with durable state on, but the documented `kubectl get nodes` output no
  longer matches.
- **`docs/FINDINGS.md` §1 still lists "ClusterIP Services, cluster DNS, `kubectl exec`
  through the Worker" as `Not achieved`.** All three now work. The file flags §5.x as a
  later correction, but the stale table is the first thing a reader meets.
- **Neither document mentions that NetworkPolicy does not work.** `networkpolicies` is
  served, k3s ships the controller, and objects are accepted — so the natural assumption
  is that it enforces. It does not, at all. This is the most dangerous gap in the docs.
- **`xt_NFLOG` is missing from the kernel-gap list** in both README (6 requested flags)
  and FINDINGS (3). It is the direct cause of NetworkPolicy failing and belongs on the
  list to ask Cloudflare for.
- **The unauthenticated cluster-admin proxy reachable from every pod is not described as a
  risk.** `README.md` frames the security model as "whoever holds the token owns the
  cluster", which understates it: any *pod* owns the cluster, no token required.
- **`README.md`'s "Source IP preservation" and `sessionAffinity` rows are accurate**, and
  the multi-port Service caveat (host-port collision) is a further consequence not yet
  documented.

## How to run the suite

```sh
export KUBECONFIG=$PWD/kubeconfig.yaml
./conformance/run.sh              # everything, then clean up
./conformance/run.sh --keep       # leave resources for inspection
./conformance/run.sh --group 30   # one group (00,10,20,30,40,50,60)
```

Last full run against the live cluster:

```
PASS  145  behaviour present and correct
XFAIL  19  known limitation, failed as expected (3 of these are confirmed DEFECTs)
SKIP   11  not applicable here
XPASS   0  known limitation that now WORKS
FAIL    0  unexpected regression
----- 175 checks
```

Exit code 0. Be aware of the wall-clock cost: 175 checks took roughly two hours on this
2-vCPU node, not the few minutes the design aimed at. The time is almost entirely
conservative wait loops plus strictly sequential pod creation, not apiserver latency —
the node sat near 10% CPU throughout. Use `--group` when iterating.

Known limitations are asserted as expected failures, so the suite cannot go green by
omitting hard cases. It exits non-zero only on an unexpected `FAIL`; a limitation that
starts working is reported as `XPASS` (or `FIXED`, for the security defects) with the
reason it was previously expected to fail, which is the cue to update this document. A
security probe that cannot run is reported as an inconclusive `FAIL`, never as fixed. See
[`conformance/README.md`](../conformance/README.md) for the layout and for two traps
(`--raw` needing the `/k8s` prefix, busybox being unable to TLS to the apiserver).

`conformance/showcase.yaml` is a hand-applied multi-feature app for demos; the same
README has a guided tour of what to look at.

## What is untested, and why

Being blunt, per the list above: **MutatingAdmissionPolicy**, **Pod Security Admission**,
**CSR signing**, **DRA**, **RuntimeClasses** (10 are registered by k3s; no handlers
verified), **CSI drivers / VolumeSnapshots** (none installed), **volume expansion**
(disabled by the StorageClass), **SCTP**, **IPv6/dual-stack**, **`dnsPolicy`/`dnsConfig`
overrides**, **ReplicationController**, **`readinessGates`**, **HelmChart CRDs**, and
**custom APF flow behaviour**. A **full admission-webhook admit/deny** was not run —
only delivery, which is proven. **PV durability across instance replacement** was not
re-verified in this run. Nothing in this document is inferred: where a mechanism was not
exercised it says UNTESTED rather than guessing.
