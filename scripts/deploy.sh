#!/usr/bin/env bash
# kubeflare — deploy a Kubernetes cluster to a Cloudflare Container and write a
# kubeconfig you can point kubectl at.
#
#   ./scripts/deploy.sh
#
# Idempotent: re-run it after editing anything. It reuses the existing guard
# token if ./kubeconfig.yaml is already present.
set -euo pipefail

cd "$(dirname "$0")/.."

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v npx >/dev/null || die "npx not found — install Node.js 20+"
[ -d node_modules ] || { bold "Installing dependencies"; npm install --silent; }

# ---------------------------------------------------------------- 1. preflight
bold "1/5  Checking Cloudflare Containers entitlement"
if ! ./scripts/preflight.sh; then
  die "account cannot deploy Containers (see above)"
fi

# ---------------------------------------------------------------- 2. guard token
bold "2/5  Configuring access token"
# Persisted to .kubeflare-token (gitignored) rather than only to kubeconfig.yaml,
# so a run that fails midway still leaves a reusable token. Rotating the token
# causes a few seconds of 403s while Worker isolates pick up the new secret.
if [ -s .kubeflare-token ]; then
  GUARD=$(cat .kubeflare-token)
  info "reusing existing token"
elif [ -f kubeconfig.yaml ] && grep -q 'token:' kubeconfig.yaml 2>/dev/null; then
  GUARD=$(awk '/token:/{print $2; exit}' kubeconfig.yaml)
  info "reusing token from kubeconfig.yaml"
else
  GUARD=$(openssl rand -hex 32)
  info "generated a new 256-bit token"
fi
printf '%s' "$GUARD" > .kubeflare-token && chmod 600 .kubeflare-token
printf '%s' "$GUARD" | npx wrangler secret put KUBE_GUARD >/dev/null 2>&1 \
  || die "could not set the KUBE_GUARD secret"
info "stored as the KUBE_GUARD Worker secret"

# Cluster identity secrets. K3S_TOKEN encrypts the bootstrap data (CA certs,
# service-account signing key) INSIDE the datastore; K3S_NODE_PASSWORD is how
# the node re-authenticates to its restored identity. Both must stay stable
# across deploys, or a litestream-restored state DB is undecryptable — so they
# are persisted locally (gitignored) and reused.
ensure_secret() {
  local name=$1 file=$2 val
  if [ -s "$file" ]; then
    val=$(cat "$file")
    info "reusing $name"
  else
    val=$(openssl rand -hex 32)
    printf '%s' "$val" > "$file" && chmod 600 "$file"
    info "generated a new $name"
  fi
  printf '%s' "$val" | npx wrangler secret put "$name" >/dev/null 2>&1 \
    || die "could not set the $name secret"
}
ensure_secret K3S_TOKEN .kubeflare-k3s-token
ensure_secret K3S_NODE_PASSWORD .kubeflare-node-password

# Durable state is opt-in: it needs R2 S3 credentials, which only you can mint.
have_secret() { npx wrangler secret list 2>/dev/null | grep -q "\"$1\""; }
if have_secret LITESTREAM_ACCESS_KEY_ID && have_secret LITESTREAM_SECRET_ACCESS_KEY && have_secret R2_ENDPOINT; then
  info "durable state: R2 secrets present — litestream replication is ON"
else
  info "durable state: OFF (cluster state is wiped on sleep/rollout)."
  info "  To enable: dash.cloudflare.com → R2 → Manage API tokens → Create API token"
  info "  (Object Read & Write, scoped to the kubeflare-state / kubeflare-jfs /"
  info "  kubeflare-registry buckets — one token covers state, volumes, and images), then:"
  info "    npx wrangler secret put LITESTREAM_ACCESS_KEY_ID      # token's Access Key ID"
  info "    npx wrangler secret put LITESTREAM_SECRET_ACCESS_KEY  # token's Secret Access Key"
  info "    npx wrangler secret put R2_ENDPOINT                   # https://<ACCOUNT_ID>.r2.cloudflarestorage.com"
  info "  and re-run ./scripts/deploy.sh"
fi

# ---------------------------------------------------------------- 3. deploy
bold "3/5  Building the image and deploying (first build takes a few minutes)"
# --containers-rollout=immediate is REQUIRED for a single-instance app: the
# default rollout is [10,100], and 10% of one instance rounds to zero, so
# deploys silently keep serving the previous image.
DEPLOY_OUT=$(npx wrangler deploy --containers-rollout=immediate 2>&1) || {
  echo "$DEPLOY_OUT" | tail -30
  die "wrangler deploy failed"
}
URL=$(echo "$DEPLOY_OUT" | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -1)
[ -n "$URL" ] || { echo "$DEPLOY_OUT" | tail -20; die "could not determine the Worker URL"; }
info "deployed to $URL"

# ---------------------------------------------------------------- 4. wait
bold "4/5  Waiting for the cluster (cold start is ~90s)"
# A freshly created workers.dev route 404s for a few seconds before it propagates,
# so retry rather than trusting the first response.
booted=""
for _ in $(seq 1 12); do
  if curl -fsS -m 120 -o /dev/null "$URL/healthz" 2>/dev/null; then booted=yes; break; fi
  sleep 10
done
[ -n "$booted" ] || die "container did not start — check: npx wrangler containers list"
info "container is up; waiting for the Kubernetes API"

ready=""
for _ in $(seq 1 40); do
  if curl -fsS -m 20 -H "Authorization: Bearer $GUARD" "$URL/k8s/version" 2>/dev/null | grep -q gitVersion; then
    ready=yes; break
  fi
  sleep 10
done
[ -n "$ready" ] || die "the Kubernetes API never came up — check: curl -H \"Authorization: Bearer \$TOKEN\" $URL/logs/k3s"

# ---------------------------------------------------------------- 5. kubeconfig
bold "5/5  Writing kubeconfig.yaml"
cat > kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: kubeflare
    cluster:
      server: ${URL}/k8s
users:
  - name: kubeflare
    user:
      token: ${GUARD}
contexts:
  - name: kubeflare
    context:
      cluster: kubeflare
      user: kubeflare
current-context: kubeflare
EOF
chmod 600 kubeconfig.yaml

echo
bold "Your cluster is live."
echo
echo "    export KUBECONFIG=\$PWD/kubeconfig.yaml"
echo "    kubectl get nodes -o wide"
echo
info "Dashboard: $URL/?token=<the token in kubeconfig.yaml>"
info "Tear down: ./scripts/teardown.sh --yes"
echo
printf '\033[33m%s\033[0m\n' "kubeconfig.yaml holds a cluster-admin token. It's gitignored by default."
