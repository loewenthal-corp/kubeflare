# Reaching the apiserver over a Cloudflare Tunnel

The default setup routes `kubectl` through the Worker (`/k8s/*` → `kubectl proxy`). That works for almost
everything, but Cloudflare's edge will not perform an `Upgrade: SPDY/3.1` protocol switch, so
`kubectl exec`, `attach`, and `port-forward` fail with:

```
error: unable to upgrade connection: 400 Bad Request
```

A named Cloudflare Tunnel carries **raw TCP** to the apiserver on 6443, so TLS is end-to-end and the edge
is never asked to switch protocols. That should restore all three. It requires a domain on your
Cloudflare account and a DNS record, which is why it is not the default.

> This path is set up but **not verified end to end** — the account used for the original spike had no DNS
> permission on its API token. If you get it working, a PR confirming or correcting this page is welcome.

## 1. Create the tunnel

```bash
cloudflared tunnel create kubeflare
```

Or via the API, which is what you want if you are scripting it:

```bash
curl -X POST -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel" \
  --data "{\"name\":\"kubeflare\",\"tunnel_secret\":\"$(openssl rand -base64 32)\",\"config_src\":\"cloudflare\"}"
```

Note the returned tunnel `id`.

## 2. Point its ingress at the apiserver

Token-run tunnels use remotely-managed configuration, so set the ingress through the API rather than a
local `config.yml`:

```bash
curl -X PUT -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  --data '{"config":{"ingress":[
     {"hostname":"kubeflare.example.com","service":"tcp://localhost:6443"},
     {"service":"http_status:404"}]}}'
```

The `tcp://` scheme is the important part — this is a raw TCP tunnel, not an HTTP one.

## 3. Add the DNS record

```
kubeflare.example.com  CNAME  <TUNNEL_ID>.cfargotunnel.com   (proxied)
```

Your API token needs DNS edit permission on the zone. The `wrangler` OAuth token does **not** have it —
it returns `Authentication error` for DNS reads as well as writes — so create a scoped token or add the
record in the dashboard.

## 4. Give the Worker the tunnel token

```bash
curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" \
  | jq -r '.result' | npx wrangler secret put TUNNEL_TOKEN
```

Set the hostname in `wrangler.jsonc` so it lands in the apiserver certificate's SANs:

```jsonc
"vars": { "TUNNEL_HOSTNAME": "kubeflare.example.com" }
```

Then redeploy. The container's entrypoint starts `cloudflared` automatically whenever `TUNNEL_TOKEN` is
present, using `--protocol http2` (outbound UDP for QUIC is not guaranteed).

## 5. Connect

```bash
cloudflared access tcp --hostname kubeflare.example.com --url 127.0.0.1:6443
```

Leave that running, and point a kubeconfig at `https://127.0.0.1:6443`. The apiserver certificate already
covers `127.0.0.1`, `localhost`, and your tunnel hostname because the entrypoint passes all three to
`--tls-san`.

Pull the cluster-internal kubeconfig (which has the real client certificates) from the container:

```bash
curl -H "Authorization: Bearer $KUBE_GUARD" \
  "https://kubeflare.<your-subdomain>.workers.dev/kubeconfig" > tunnel-kubeconfig.yaml
```

## Security

Anyone who can resolve the hostname can reach your apiserver's TLS port. Put a Cloudflare Access policy in
front of it, or rely on the fact that the apiserver still requires client certificates — but do not assume
the tunnel alone is authentication.
