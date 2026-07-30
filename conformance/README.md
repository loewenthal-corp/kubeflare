# kubeflare conformance suite

An empirical check of what this cluster's Kubernetes API actually does. Every verdict
in [`docs/CONFORMANCE.md`](../docs/CONFORMANCE.md) comes from a check in here.

```sh
export KUBECONFIG=$PWD/kubeconfig.yaml
./conformance/run.sh
```

Needs `kubectl`, `curl`, `openssl`, `python3`. If the cluster is asleep, `run.sh` wakes it
and waits for `/readyz` before starting.

**Runtime:** the last full run was 175 checks in roughly two hours on this 2-vCPU node —
much longer than the few minutes originally aimed for. The cost is conservative wait
loops and strictly sequential pod creation, not apiserver latency (the node stayed near
10% CPU). Use `--group` while iterating; a single group is minutes, not hours.

| Flag | Effect |
|---|---|
| `--keep` | leave every resource in place for inspection |
| `--group 30` | run one check group by filename prefix (`00`, `10`, `20`, `30`, `40`, `50`, `60`) |
| `--verbose` | keep output from passing checks too |

## How results are reported

The suite does **not** go green by skipping the hard cases. Known limitations are
asserted as expected failures, so the tally distinguishes five outcomes:

| Result | Meaning |
|---|---|
| `PASS` | expected to work, and does |
| `XFAIL` | known limitation, failed exactly as documented — this is a healthy result |
| `SKIP` | structurally not applicable (single node, no CSI driver, …) |
| `DEFECT` | a known defect (e.g. the unauthenticated admin proxy) was confirmed still present |
| `FIXED` | a known defect is **no longer reproducible** — update `docs/CONFORMANCE.md` |
| `XPASS` | **a documented limitation now WORKS** — the platform improved and `docs/CONFORMANCE.md` is stale |
| `FAIL` | something that is supposed to work broke — a regression, **or** a `DEFECT` probe that could not run |

`DEFECT`/`FIXED` come from `defect()` rather than `xcheck()`, and exist because of a trap
worth calling out: a negated probe (`! curl …`) reports success when its *fixture* is
missing. Written that way, a security check announces "the hole is closed" on no evidence
at all. `defect()` asserts the bad behaviour positively and has a distinct third outcome —
if the probe cannot run, it is reported as `FAIL` (inconclusive), never as fixed.

`run.sh` exits non-zero **only** on `FAIL`. `XPASS` is printed loudly at the end with
the reason each thing was previously expected to fail, because that is the signal
that the matrix needs re-writing. If you fix NodePort, enable metrics-server, or get
NetworkPolicy enforcing, the suite tells you which lines to update.

## Layout

```
conformance/
  run.sh                          entrypoint: readiness gate, fixtures, groups, tally
  lib.sh                          check/xcheck/skip, waits, retries, cleanup
  checks/00-cluster.sh            discovery, versions, node, raw-path transport limits
  checks/10-apimachinery.sh       CRDs, SSA, patches, selectors, watch, paging,
                                  admission (CEL + webhooks), aggregation, PDB/eviction,
                                  the metrics-server gap
  checks/20-workloads.sh          Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob
  checks/30-networking.sh         ClusterIP, multi-port, UDP, headless, ExternalName,
                                  DNS record types, egress, NodePort/LB, source IP,
                                  sessionAffinity, NetworkPolicy, Ingress
  checks/40-config-identity.sh    ConfigMap/Secret/projected/downward API, SA tokens, RBAC
  checks/50-storage-scheduling.sh PVC/PV lifecycle, QoS, affinity, taints, preemption,
                                  ResourceQuota, LimitRange
  checks/60-lifecycle-kubectl.sh  init containers, native sidecars, probes, termination,
                                  ephemeral containers, logs/exec/cp/port-forward/rollout,
                                  and the unauthenticated-admin-proxy findings
  showcase.yaml                   a realistic multi-feature app to apply by hand
```

Everything namespaced runs in `kubeflare-conformance` (quota and LimitRange get their
own `kubeflare-conformance-quota`, because a CPU quota forces every pod in the
namespace to declare requests and would break unrelated checks). Cluster-scoped
objects — CRD, ValidatingAdmissionPolicy, webhook configs, APIService, PriorityClasses,
ClusterRole/Binding — are suffixed with a per-run `RUN_ID` and deleted on exit, along
with a defensive `kubectl taint node <node> taint-$RUN_ID-` so a failed taint check
can never leave the single node unschedulable.

Only three images are used, all of which the cluster already caches: `busybox:1.36`,
`nginx:1.27-alpine`, `registry.k8s.io/e2e-test-images/agnhost:2.47`.

## Two traps worth knowing about

**`kubectl get --raw` needs the `/k8s` prefix spelled out.** The kubeconfig server URL
is `https://<worker>/k8s`, and `--raw` keeps only the host, discarding the path prefix.
A bare `kubectl get --raw /readyz` therefore hits the Worker's dashboard route, which —
because the kubeconfig token doubles as the dashboard token — answers **HTTP 200 with
HTML**. It looks like a pass while never touching the apiserver. Use
`kubectl get --raw /k8s/readyz`; `lib.sh` wraps this as `kraw`.

**Do not use busybox for HTTPS to the apiserver.** busybox's built-in TLS offers no
cipher suite the apiserver accepts, and fails with peer alert 47 even against the node
IP directly. That is a client limitation, not a cluster one — testing it with busybox
records a false `BROKEN`. The suite uses agnhost's `inclusterclient` (a Go client) for
in-pod API calls instead.

## What to look at in the showcase

```sh
kubectl apply -f conformance/showcase.yaml
kubectl -n kubeflare-showcase rollout status deploy/showcase
kubectl -n kubeflare-showcase get all,pvc
```

A single Deployment exercising most of what works, with nothing that doesn't:

- **Init container ordering** — `kubectl -n kubeflare-showcase logs deploy/showcase -c seed-content`
  ran to completion before the app started; its output is on the PVC:
  `kubectl -n kubeflare-showcase exec deploy/showcase -c web -- cat /data/seeded.txt`
- **Native sidecar** — `sidecar-apiwatch` is an `initContainer` with
  `restartPolicy: Always`, so it starts first and then keeps running. It calls the
  apiserver through `kubernetes.default` with the pod's own projected ServiceAccount
  token: `kubectl -n kubeflare-showcase logs deploy/showcase -c sidecar-apiwatch`
- **ConfigMap subPath** — the nginx index page is one ConfigMap key mounted as a
  single file, not a directory.
- **Projected volume** — `exec … -- ls /etc/showcase` shows ConfigMap, Secret,
  downward-API labels and a bound SA token under one mount.
- **Env from ConfigMap, Secret, envFrom and the downward API** —
  `exec … -- printenv GREETING TIER API_TOKEN MY_POD_IP MY_NODE`
- **PVC** — `kubectl -n kubeflare-showcase get pvc showcase-data` is `Bound` on the
  `local-path` StorageClass. It binds on first consumer, not at create time.
- **Probes and QoS** — startup, readiness and liveness probes all gate traffic;
  `kubectl -n kubeflare-showcase get pod -o jsonpath='{.items[0].status.qosClass}'`
  reports `Burstable`.
- **ClusterIP without kube-proxy** — from inside the cluster:
  `kubectl -n kubeflare-showcase exec deploy/showcase -c web -- wget -qO- http://showcase/`
  Repeat it and the CronJob logs show requests spreading across both replicas.
- **Headless DNS** — `showcase-headless` resolves to every pod IP rather than a VIP.
- **PodDisruptionBudget** — `minAvailable: 1`; the eviction subresource honours it.
- **CronJob** — `kubectl -n kubeflare-showcase logs job/<latest> ` proves DNS and
  ClusterIP routing still work a minute later.

Deliberately absent, because they do not work here: `HorizontalPodAutoscaler` (no
metrics-server), `NodePort`/`type: LoadBalancer` (no inbound TCP outside the Worker),
`Ingress` (no controller), and `NetworkPolicy` (accepted, silently unenforced).

Clean up with `kubectl delete -f conformance/showcase.yaml`.
