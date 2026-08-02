# AGENTS.md

Instructions for an AI agent working on this repository. Read this before touching
anything — most of what follows is invisible from the code and was learned the
expensive way.

## What this is

A real single-node k3s cluster running inside a Cloudflare Container (a Firecracker
microVM), with `kubectl` on a laptop pointed at it through a Worker. There is no VM to
manage and no cloud provider underneath. 153 Kubernetes API features work; the ones
that don't have documented root causes in [docs/CONFORMANCE.md](docs/CONFORMANCE.md).

The interesting engineering is in the workarounds: the guest kernel loads no modules, so
several things Kubernetes assumes are simply absent, and the platform accepts no inbound
TCP. Read [docs/FINDINGS.md](docs/FINDINGS.md) §5.x before concluding anything is
impossible — and note that its §1 table is the original spike and is superseded.

## What you almost certainly need first: credentials

Nothing here works without Cloudflare credentials, and **no single token covers
everything**. Three separate ones, obtained three different ways. Getting this wrong is
the most common way to waste an hour.

| # | Credential | How to get it | Without it |
|---|---|---|---|
| 1 | **wrangler OAuth** | `npx wrangler login` | Nothing deploys at all |
| 2 | **R2 API token** | Dashboard → R2 → *Manage API tokens* → Create Account API token, **Object Read & Write**, scoped to the `kubeflare-*` buckets | No durable state, no R2 volumes, no image cache. Cluster is fully ephemeral |
| 3 | **Cloudflare API token** | Dashboard → My Profile → API Tokens → Create Custom Token (permissions below) | No Tunnel, no `type: LoadBalancer`, no Ingress |

### The wrangler OAuth token cannot do everything

This surprises people. It handles Workers, Containers, R2 *buckets*, D1 and KV — but it
**cannot create DNS records** and **cannot mint R2 S3 credentials**. That is precisely
why tokens 2 and 3 exist. Do not spend time trying to make `wrangler` do either.

### Token 3 needs exactly these permissions

```
Account  →  Cloudflare Tunnel  →  Edit      (create tunnels, set ingress, read token)
Zone     →  DNS                →  Edit      (the CNAME each hostname needs)
Zone     →  Zone               →  Read      (resolve a zone name to its id)
```

**`Account → DNS Settings → Edit` is NOT the right permission.** It looks plausible and
is a different thing entirely — account-level DNS defaults, not records in a zone. If
DNS calls return `Authentication error` (code 10000) while tunnel calls succeed, this is
why. Verify before building on it:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?per_page=1" | jq .success
```

`/user/tokens/verify` returning `success:false` is **expected** for an account-scoped
token and does not mean the token is bad. Test the operations you actually need.

### Where credentials live

Local, all gitignored, and these are **the only copies** — Worker secrets are write-only
and cannot be read back:

```
.env                        R2 + Cloudflare API tokens (you create this)
.kubeflare-token            cluster-admin bearer token      (deploy.sh generates)
.kubeflare-k3s-token        k3s join token                  (deploy.sh generates)
.kubeflare-node-password    node password                   (deploy.sh generates)
.kubeflare-registry-creds   image-cache registry creds
.kubeflare-tunnel-id        tunnel id
```

> Losing `.kubeflare-k3s-token` or `.kubeflare-node-password` is unrecoverable. k3s
> encrypts its CA and service-account key *into* the datastore keyed by the join token,
> so without it a restored R2 replica is undecryptable — you lose the cluster's identity
> and every Secret in it. Back them up somewhere real.

### Feature gating is all-or-nothing

Each optional feature turns on only when **every** input is present, and stays silently
off otherwise. Check the boot log rather than guessing:

| Feature | Requires |
|---|---|
| Durable state (Litestream→R2) | `LITESTREAM_ACCESS_KEY_ID`, `LITESTREAM_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET`, `K3S_TOKEN`, `K3S_NODE_PASSWORD` |
| R2-backed volumes (JuiceFS) | durable state, **plus** `R2_BUCKET_JFS` |
| Image cache | `REGISTRY_MIRROR_URL` (+ `REGISTRY_MIRROR_USERNAME`/`PASSWORD`) |
| Tunnel (`cloudflared`) | `TUNNEL_TOKEN` |
| `type: LoadBalancer` | `CLOUDFLARE_TUNNEL_API_TOKEN`, `CF_ACCOUNT_ID`, `CF_ZONE_ID`, `CF_TUNNEL_ID` |
| Ingress (Traefik) | same as LoadBalancer; `INGRESS_ENABLED=0`/`1` overrides |

```bash
curl -s -H "Authorization: Bearer $(cat .kubeflare-token)" "$URL/logs/entrypoint" \
  | grep -iE "litestream|juicefs|image mirror|ingress|lbcontroller"
```

## Zero to a working cluster

```bash
npm install
npx wrangler login
./scripts/deploy.sh          # ~5 min: builds the image, deploys, writes kubeconfig.yaml
export KUBECONFIG=$PWD/kubeconfig.yaml
kubectl get nodes
```

That gets an ephemeral cluster. For durable state, add the R2 secrets and redeploy:

```bash
npx wrangler secret put LITESTREAM_ACCESS_KEY_ID
npx wrangler secret put LITESTREAM_SECRET_ACCESS_KEY
npx wrangler secret put R2_ENDPOINT     # https://<ACCOUNT_ID>.r2.cloudflarestorage.com
```

For Tunnel/LoadBalancer/Ingress: `CLOUDFLARE_TUNNEL_API_TOKEN=... ./scripts/tunnel-setup.sh k8s.<your-domain>`,
then set `CF_*` and `LB_HOSTNAME_SUFFIX` in `wrangler.jsonc`.

**`LB_HOSTNAME_SUFFIX` must be exactly one label under the zone apex** (`example.com`,
not `lb.example.com`). Universal SSL covers `*.example.com` but not
`*.lb.example.com`, and the deeper form yields HTTP 200 with a failed TLS handshake.

## The deploy loop, and the traps in it

These have each cost real time. Read them.

1. **A change to a var or secret alone does not reach a running container.** `envVars`
   are read once, at container start, and a config-only change produces an identical
   image digest so Cloudflare performs no rollout. Use `POST /admin/restart`, or bump
   `KUBEFLARE_REBUILD` in the Dockerfile to force a genuinely new image.
2. **A deploy does not swap the instance instantly.** `npx wrangler containers info <id>`
   shows the rollout. Watching `kubectl` alone will show you the *old* cluster and
   mislead you completely. Wait for a signal that only the new image produces.
3. **Always `--containers-rollout=immediate`** for this single-instance app — the default
   `[10,100]` rounds 10% of one instance down to zero, so deploys silently keep serving
   the old image. `deploy.sh` always passes it.
4. **Local Docker testing will lie to you.** Docker's default seccomp denies
   `unshare(CLONE_NEWUSER)`, masks `/proc`, and omits `/dev/fuse` and `/dev/net/tun` —
   all of which Cloudflare provides. Trust deployed instances only.
5. **Docker must be running** to build (`orb start` for OrbStack).
6. **k3s's addon reconciler reverts live patches** to packaged components on every start.
   Vendor the manifest into `container/manifests/` and `--disable` the packaged copy
   instead of `kubectl patch`ing it.
7. **`kubectl get --raw <path>` does not work.** It keeps only the host from the
   kubeconfig server URL and drops the `/k8s` prefix, so it hits the Worker dashboard and
   returns **HTTP 200 with HTML**. Anything built on it silently lies. Use
   `curl -H "Authorization: Bearer $(cat .kubeflare-token)" "$URL/k8s/<path>"`.
8. **Commits are SSH-signed via 1Password.** A failure with
   `1Password: failed to fill whole buffer` means an approval prompt is waiting on
   screen — retry after approving. Do **not** pass `--no-gpg-sign`.
9. **`go build ./...` drops a ~38 MB binary** into `svcproxy/` and `lbcontroller/`. Both
   are gitignored; never `git add -A` one into a commit.

## Architecture, briefly

```
kubectl ──HTTPS──▶ Worker (src/index.ts) ──▶ Durable Object ──▶ Container
                   /k8s/*   → kubectl proxy :8001   ├── k3s (apiserver, kubelet, containerd)
                   /np/<port>/* → NodePort          ├── svcproxy      ClusterIP + NodePort, userspace
                   /admin/restart                   ├── lbcontroller  type: LoadBalancer → Tunnel
                   /healthz, /logs/*, /diag         ├── litestream    kine SQLite → R2
                                                    ├── juicefs       R2-backed PVs
                                                    └── cloudflared   Tunnel
```

- `container/entrypoint.sh` is PID 1 and the heart of the system — a supervisor that
  starts and restarts everything. Most changes land here.
- `svcproxy/` and `lbcontroller/` are Go binaries built by the Dockerfile. They are
  separate on purpose: `lbcontroller` needs a Cloudflare API token, the dataplane must not.
- The build context is the **repo root** (`image_build_context` in `wrangler.jsonc`), so
  `COPY` paths in the Dockerfile are repo-relative.

## Do not chase these — they are known and understood

- **NetworkPolicy is accepted and silently unenforced.** Not a bug you can fix by trying
  harder; see the README. Never rely on it for isolation here.
- **No source-IP preservation at L4**, and it is *not* a missing kernel feature — it
  fails on bridge topology. The control experiment is documented in `svcproxy/README.md`.
  HTTP workloads should read `CF-Connecting-IP`.
- **kube-proxy cannot run in any mode** here. That is why `svcproxy/` exists.
- **Multi-node is impossible** — no vxlan, no inbound UDP.
- **Never run `juicefs status` by hand** against the metadata DB. Its SQLite driver
  *creates* the file, and an empty one makes the next boot skip both restore and format
  and come up with no filesystem. Recovery is `rm /var/lib/kubeflare/jfs-meta.db*`.

## Verify your change, don't assume it

The single most valuable habit in this repo: **test against the deployed cluster**. This
codebase has repeatedly disproved confident reasoning — `xt_statistic` missing,
`xt_NFLOG` missing, Docker Hub rate-limiting a Worker's shared egress, the client IP
surviving at L7 but not L4.

```bash
./conformance/run.sh                      # 175 checks, expected-fails asserted as such
curl -s -H "Authorization: Bearer $(cat .kubeflare-token)" "$URL/diag"
curl -s -H "Authorization: Bearer $(cat .kubeflare-token)" "$URL/logs/<component>"
```

Two traps when writing your own probes, both of which produced false results here:

- **Never write a negated shell probe as `wget … | head && echo LEAKED`.** A pipeline's
  exit status is the *last* command's, so `head` succeeding makes it always fire. Capture
  the body and grep it.
- **In zsh, `$VAR` does not word-split**, so `U="-u a:b"; curl $U` passes one argument and
  silently fails auth. And never name a shell variable `path` — zsh ties it to `$PATH`.

## Style

Comments explain **why**, especially platform quirks — the *what* is usually obvious and
the *why* is usually surprising. Match the surrounding voice. When you discover something
non-obvious about the platform, write it down where the next person will hit it: a
comment at the site, plus `docs/FINDINGS.md` or `docs/CONFORMANCE.md` if it changes what
works.
