# kubeflare-lbcontroller

`type: LoadBalancer` for a cluster with no cloud provider — every LoadBalancer
Service gets a public hostname on the cluster's own Cloudflare Tunnel.

## Why this exists

kubeflare runs a real single-node k3s cluster inside a Cloudflare Container.
There is no cloud load balancer to ask for an address, k3s runs with
`--disable servicelb`, and so `EXTERNAL-IP` on a LoadBalancer Service stays
`<pending>` forever. The allocated `nodePort` works, but nothing outside the
Worker can reach it.

What the cluster does have is a Cloudflare Tunnel, and `cloudflared` running as
a **host process in the same network namespace as svcproxy**. svcproxy binds
every Service's ClusterIP on that host (via the AnyIP local route on `lo` — see
`svcproxy/README.md`), which means cloudflared can open a connection straight to
`http://<clusterIP>:<port>` and get userspace load balancing across ready
endpoints for free. No NodePort hop, no dependency on the pod network, and no
need for this controller to watch EndpointSlices at all.

So: one ingress rule and one proxied CNAME per Service, and the hostname written
back into `.status.loadBalancer.ingress`.

## What it does

- Watches Services with client-go shared informers (Services only; nothing else
  is needed).
- For every `type: LoadBalancer` Service with an IPv4 ClusterIP and a TCP port:
  - derives a hostname (below),
  - adds an ingress rule `hostname -> http://<clusterIP>:<port>` to the tunnel,
  - ensures a proxied `CNAME` from that hostname to
    `<tunnel-id>.cfargotunnel.com`,
  - writes `.status.loadBalancer.ingress[0].hostname` so `kubectl get svc` shows
    an address.
- Guards deletion with the finalizer `kubeflare.io/lb-controller`: on delete (or
  on a downgrade away from `type: LoadBalancer`) the rule and the record are
  withdrawn first, then the finalizer is released.
- Rebuilds and writes the ingress document **once per pass**, no matter how many
  Services changed, and skips the write entirely when the document would not
  change.
- Re-reconciles every 10 minutes even when nothing changed, so a tunnel config or
  DNS record edited by hand in the dashboard heals.
- Retries everything. The only fatal conditions are a missing/invalid flag or
  token and an unusable kubeconfig, both at startup.

## The shared-ingress-document hazard

**This is the part to understand before changing anything here.**

A remotely-managed tunnel has exactly one ingress list, and
`PUT /accounts/{a}/cfd_tunnel/{t}/configurations` **replaces the whole
document**. On kubeflare that document also holds the rule that carries every
`kubectl` request:

```json
{"hostname": "k8s.kubeflare.dev", "service": "tcp://localhost:6443"}
```

Losing it cuts the cluster off from its own operator. So `rebuildIngress`
(`plan.go`) reconstructs the entire list on every write, in three parts:

1. **Every pre-existing rule the controller does not manage, first, verbatim.**
   Rules are round-tripped as decoded JSON objects rather than structs, so fields
   this controller knows nothing about (`originRequest`, `path`, `access`, …)
   survive untouched. Foreign rules keep their original relative order and come
   *before* the managed ones, so — first match wins in cloudflared — no Service
   can ever take precedence over the apiserver rule.
2. **The managed rules, sorted by hostname.** Deterministic ordering is what
   makes a no-op pass a genuine no-op: the rebuilt document is compared to the
   one that was read, and equal means no PUT.
3. **The catch-all, last.** An ingress list whose final entry still matches on
   hostname or path is rejected by the API. An existing catch-all is preserved
   verbatim (a hand-configured `http_status:503` is not downgraded); if there was
   none, `{"service":"http_status:404"}` is appended.

Anything else in the config document — `warp-routing`, top-level
`originRequest` — is passed through untouched, because only the `ingress` key is
ever replaced.

A rule is **managed** if its hostname is under `--hostname-suffix`, or if this
process published it (tracked in memory, and seeded from
`.status.loadBalancer.ingress` so it survives a restart). Everything else is
foreign and preserved.

If a Service asks for a hostname a foreign rule already serves, **the Service
loses**: the rule is not published, the DNS record is not touched, the status
stays `<pending>`, and an error is logged. Refusing one Service is much better
than evicting the rule kubectl depends on. The one exception is a foreign rule
that is byte-identical to what would be written for that hostname anyway —
adopting it changes nothing, so it is adopted rather than reported.

## Hostnames

Default: `<service>-<namespace>.<--hostname-suffix>`, e.g. `web-default.lb.kubeflare.dev`.

The `<service>-<namespace>` part is sanitised into one legal DNS label —
lowercased, everything outside `[a-z0-9-]` replaced with `-`, trimmed of leading
and trailing hyphens, and capped at 63 characters. Names longer than that keep 54
readable characters plus 8 hex digits of a SHA-256 of the full input, so
truncation does not silently merge two Services.

`kubeflare.io/hostname: shop.kubeflare.dev` overrides it with a fully-qualified
name. That value is taken literally (only lowercased and stripped of a trailing
dot) rather than sanitised — silently rewriting an explicit FQDN would publish a
Service at an address nobody asked for. A value that is not a valid DNS name, or
is a wildcard, is refused with a log line.

### Collisions

Two Services can want the same hostname: `a-b` in namespace `c` and `a` in
namespace `b-c` both sanitise to `a-b-c`, and two Services can carry the same
`kubeflare.io/hostname` annotation outright.

**The older Service wins** (by `.metadata.creationTimestamp`, ties broken by
`namespace/name`). The loser is skipped entirely — no rule, no record, no status
— and logs `hostname X is already claimed by the older Service Y`. Choosing by
age rather than by name means an existing, working Service cannot have its
hostname taken away by something created later.

Changing the hostname of a live Service (editing the annotation) withdraws the
old hostname: its rule is dropped from the ingress list and its DNS record
deleted.

## The finalizer, and why it cannot wedge a Service

A finalizer that can strand an object is a real hazard: a Service stuck in
`Terminating` also blocks deletion of its namespace. Cleanup is therefore
bounded. If withdrawing a Service's Cloudflare state fails **10 consecutive
passes** — several minutes, given the reconcile backoff — the finalizer is
released anyway, with an `ERROR` line naming the hostname, and the hostname moves
to an in-memory orphan list that keeps trying to delete the DNS record in the
background (also bounded, then a final "delete it by hand" line).

Leaking a DNS record is recoverable with one dashboard click. A Service nobody
can delete is not. The ingress rule is not leaked either way: it is recognised as
managed on the next pass and reaped.

## How it's wired into kubeflare

A plain host process (root, host network namespace — same as k3s, svcproxy and
cloudflared), started from the container entrypoint once k3s has written its
admin kubeconfig. The API token comes from the environment, never a flag: a token
on a command line is visible in every `ps` inside the container.

```sh
CLOUDFLARE_TUNNEL_API_TOKEN=... \
kubeflare-lbcontroller \
  --account-id efa2c77d00fdfef6fa9c3678716d3160 \
  --zone-id     2b46f0e6cf1112ffeaa84cf9179ed28c \
  --tunnel-id   6b0094c3-200b-4f19-b5e1-bc438f31c811
```

Add `--dry-run -v` to see the exact ingress document that would be PUT, the DNS
calls that would be made, and the status/finalizer writes that would happen —
without changing anything, in Cloudflare or in the cluster.

The token needs **Account > Cloudflare Tunnel > Edit** (read and write the
tunnel configuration) and **Zone > DNS > Edit** on the zone. A token refused for
a DNS call produces one actionable error line per pass, not a crash.

Startup ordering: only the kubeconfig **file** must exist; the API server may
still be booting, since informers retry forever. The tunnel need not be up
either — the ingress configuration is an API object, not something cloudflared
has to be connected for.

### Flags

| Flag | Default | Meaning |
| --- | --- | --- |
| `--kubeconfig` | `/etc/rancher/k3s/k3s.yaml` | kubeconfig with read/write on Services and Service status |
| `--account-id` | — | Cloudflare account ID that owns the tunnel (**required**) |
| `--zone-id` | — | Cloudflare zone ID the hostnames live in (**required**) |
| `--tunnel-id` | — | Cloudflare Tunnel to publish ingress rules on (**required**) |
| `--hostname-suffix` | `lb.kubeflare.dev` | suffix for derived hostnames |
| `--dry-run` | `false` | compute and log everything, change nothing |
| `-v` | `false` | verbose (debug) logging |

| Environment | Meaning |
| --- | --- |
| `CLOUDFLARE_TUNNEL_API_TOKEN` | API token (**required**) |

Every missing required input is reported in a single line, then exit 1.

### Annotations

| Annotation | Meaning |
| --- | --- |
| `kubeflare.io/hostname` | fully-qualified hostname to publish instead of the derived one |
| `kubeflare.io/port` | which `spec.ports` entry to publish, by name or number (default: the first) |

## Build

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o kubeflare-lbcontroller .
```

Pure Go, statically linked, no runtime dependencies. Same client-go pin as
svcproxy (v0.36.3, `go 1.26.0`) so both build in the same image.

## Limitations (v1)

- **HTTP origins only.** Ingress rules are always `http://<clusterIP>:<port>`.
  Cloudflare terminates TLS at the edge, so the public hostname is HTTPS, but the
  hop from cloudflared to the Service is plaintext inside the container. A
  Service that only speaks TLS, gRPC-over-TLS, or a raw TCP protocol needs a
  different ingress scheme (`tcp://`, `https://`) that this controller does not
  generate. Non-TCP ports are skipped with a log line.
- **One tunnel for everything.** Every Service shares the cluster's single
  tunnel and its single ingress document, with the apiserver rule. There is no
  per-Service tunnel and no isolation between Services.
- **No per-Service TLS or origin configuration.** No `originRequest` block is
  written, so no `noTLSVerify`, `httpHostHeader`, `connectTimeout`, or
  per-Service Access policy. (Rules that already carry one are preserved, just
  not generated.)
- **The backend sees Cloudflare, not the client.** Records are proxied, and
  cloudflared re-originates the connection from inside the container, so the pod
  sees the ClusterIP hop as its peer. Real client addresses are only available
  from `CF-Connecting-IP` / `X-Forwarded-For`.
- **The suffix subdomain belongs to the controller.** Any tunnel rule under
  `--hostname-suffix` that does not correspond to a Service is reaped. Do not
  hand-write rules there.
- **No `spec.loadBalancerClass` support**, no `externalTrafficPolicy`, no
  `loadBalancerSourceRanges` (use Cloudflare WAF rules instead), no per-Service
  ports in `.status.loadBalancer.ingress`.
- **IPv4 only**, matching svcproxy: an IPv6 ClusterIP has no listener to reach.
- Cloudflare API calls per pass scale with the number of LoadBalancer Services
  (one DNS lookup each) plus one tunnel-config read. Fine for a handful of
  Services; this is not built for hundreds.

## Manual test recipe

From inside the kubeflare container, with the tunnel up and DNS:Edit granted:

```sh
# 1. See what it would do, without doing it.
CLOUDFLARE_TUNNEL_API_TOKEN=$TOKEN kubeflare-lbcontroller \
  --account-id "$ACC" --zone-id "$ZONE" --tunnel-id "$TUNNEL" --dry-run -v
# Expect: one "dry-run: skipping Cloudflare write" line whose body still
# contains the k8s.kubeflare.dev rule and ends with the catch-all.

# 2. For real, in the background.
CLOUDFLARE_TUNNEL_API_TOKEN=$TOKEN kubeflare-lbcontroller \
  --account-id "$ACC" --zone-id "$ZONE" --tunnel-id "$TUNNEL" -v &

# 3. A workload with two replicas behind a LoadBalancer.
kubectl create deployment echo --replicas=2 \
  --image=registry.k8s.io/e2e-test-images/agnhost:2.47 -- /agnhost netexec --http-port 8080
kubectl expose deployment echo --port 80 --target-port 8080 --type=LoadBalancer
kubectl get svc echo -w        # EXTERNAL-IP becomes echo-default.lb.kubeflare.dev

# 4. From the public internet (give DNS and the tunnel a few seconds).
curl -s https://echo-default.lb.kubeflare.dev/hostname   # alternating pod names

# 5. kubectl must still work: that is the rule the rebuild has to preserve.
kubectl get nodes

# 6. A custom hostname.
kubectl annotate svc echo kubeflare.io/hostname=shop.kubeflare.dev --overwrite
# The old hostname's rule and record are withdrawn; the new pair appears.

# 7. Cleanup exercises the finalizer.
kubectl delete svc echo deployment/echo
# Logs: "dns record deleted", "tunnel ingress updated", "finalizer released".
# The tunnel config is back to the apiserver rule plus the catch-all.
```
