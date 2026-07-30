#!/usr/bin/env bash
# kubeflare — create (or adopt) the Cloudflare Tunnel that carries raw TLS to
# the apiserver on 6443, end to end:
#
#   CLOUDFLARE_API_TOKEN=... ./scripts/tunnel-setup.sh k8s.example.com
#
# The token needs TWO permissions (dash.cloudflare.com → My Profile → API
# Tokens → Create Token → Custom):
#   Account | Cloudflare Tunnel | Edit
#   Zone    | DNS               | Edit      (on the hostname's zone)
#
# The wrangler OAuth login cannot do either — this is why the script takes a
# separate token. It performs: tunnel create/adopt → ingress config
# (tcp://localhost:6443) → DNS CNAME → stores TUNNEL_TOKEN as a Worker secret.
# Afterwards set "TUNNEL_HOSTNAME" in wrangler.jsonc and redeploy so the
# apiserver certificate picks up the SAN and cloudflared starts.
#
# Connect (kubectl exec/attach/port-forward all work over this path):
#   cloudflared access tcp --hostname k8s.example.com --url 127.0.0.1:6443
#   curl -H "Authorization: Bearer $(cat .kubeflare-token)" \
#     "https://<worker-url>/kubeconfig" > tunnel-kubeconfig.yaml   # real client certs
set -euo pipefail

cd "$(dirname "$0")/.."

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

HOSTNAME_ARG="${1:-}"
[ -n "$HOSTNAME_ARG" ] || die "usage: CLOUDFLARE_API_TOKEN=... $0 <hostname>  (e.g. k8s.example.com)"
[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "CLOUDFLARE_API_TOKEN is not set (needs Account:Cloudflare Tunnel:Edit + Zone:DNS:Edit)"
command -v jq >/dev/null || die "jq not found"

API=https://api.cloudflare.com/client/v4
auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

cf() { # method path [json-body]
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "${auth[@]}" "$API$path" --data "$body"
  else
    curl -fsS -X "$method" "${auth[@]}" "$API$path"
  fi
}

TUNNEL_NAME=kubeflare

# ---------------------------------------------------------------- 1. account
bold "1/5  Resolving account"
ACCOUNT_ID=$(cf GET /accounts | jq -r '.result[0].id // empty')
[ -n "$ACCOUNT_ID" ] || die "token cannot list accounts — is it an Account-scoped token?"
info "account $ACCOUNT_ID"

# ---------------------------------------------------------------- 2. zone
bold "2/5  Resolving zone for $HOSTNAME_ARG"
# Walk up the labels until a zone matches (handles k8s.sub.example.com).
ZONE_ID="" ; ZONE_NAME="$HOSTNAME_ARG"
while [ -z "$ZONE_ID" ] && [[ "$ZONE_NAME" == *.* ]]; do
  ZONE_ID=$(cf GET "/zones?name=$ZONE_NAME" | jq -r '.result[0].id // empty')
  [ -n "$ZONE_ID" ] || ZONE_NAME="${ZONE_NAME#*.}"
done
[ -n "$ZONE_ID" ] || die "no zone on this account matches $HOSTNAME_ARG (token needs Zone:DNS:Edit on it)"
info "zone $ZONE_NAME ($ZONE_ID)"

# ---------------------------------------------------------------- 3. tunnel
bold "3/5  Creating (or adopting) tunnel '$TUNNEL_NAME'"
TUNNEL_ID=$(cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel?name=$TUNNEL_NAME&is_deleted=false" \
  | jq -r '.result[0].id // empty')
if [ -n "$TUNNEL_ID" ]; then
  info "adopting existing tunnel $TUNNEL_ID"
else
  TUNNEL_ID=$(cf POST "/accounts/$ACCOUNT_ID/cfd_tunnel" \
    "{\"name\":\"$TUNNEL_NAME\",\"tunnel_secret\":\"$(openssl rand -base64 32)\",\"config_src\":\"cloudflare\"}" \
    | jq -r '.result.id // empty')
  [ -n "$TUNNEL_ID" ] || die "tunnel creation failed"
  info "created tunnel $TUNNEL_ID"
fi

info "pointing ingress at tcp://localhost:6443 (warp-routing on for future private-net use)"
cf PUT "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  "{\"config\":{\"ingress\":[
     {\"hostname\":\"$HOSTNAME_ARG\",\"service\":\"tcp://localhost:6443\"},
     {\"service\":\"http_status:404\"}],
     \"warp-routing\":{\"enabled\":true}}}" >/dev/null

# ---------------------------------------------------------------- 4. dns
bold "4/5  DNS record $HOSTNAME_ARG → $TUNNEL_ID.cfargotunnel.com"
EXISTING=$(cf GET "/zones/$ZONE_ID/dns_records?type=CNAME&name=$HOSTNAME_ARG" | jq -r '.result[0].id // empty')
RECORD="{\"type\":\"CNAME\",\"name\":\"$HOSTNAME_ARG\",\"content\":\"$TUNNEL_ID.cfargotunnel.com\",\"proxied\":true}"
if [ -n "$EXISTING" ]; then
  cf PUT "/zones/$ZONE_ID/dns_records/$EXISTING" "$RECORD" >/dev/null
  info "updated existing CNAME"
else
  cf POST "/zones/$ZONE_ID/dns_records" "$RECORD" >/dev/null
  info "created CNAME (proxied)"
fi

# ---------------------------------------------------------------- 5. secret
bold "5/5  Storing TUNNEL_TOKEN as a Worker secret"
cf GET "/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r '.result' \
  | npx wrangler secret put TUNNEL_TOKEN >/dev/null 2>&1 \
  || die "could not set the TUNNEL_TOKEN secret"
info "done"

echo
bold "Tunnel is configured. Two steps remain:"
echo
echo '    1. In wrangler.jsonc set:  "TUNNEL_HOSTNAME": "'"$HOSTNAME_ARG"'"'
echo "       then re-run ./scripts/deploy.sh (the apiserver cert needs the SAN)."
echo
echo "    2. Connect with native TLS (exec/attach/port-forward work here):"
echo "         cloudflared access tcp --hostname $HOSTNAME_ARG --url 127.0.0.1:6443"
echo "       and point a kubeconfig at https://127.0.0.1:6443."
echo
info "Anyone who can resolve $HOSTNAME_ARG reaches the apiserver's TLS port;"
info "the apiserver still requires client certs, but consider a Cloudflare"
info "Access policy in front of it (docs/TUNNEL.md#security)."