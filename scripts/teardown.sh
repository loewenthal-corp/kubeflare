#!/usr/bin/env bash
# Delete everything kubeflare created.
#
#   ./scripts/teardown.sh         # dry run — shows what would go
#   ./scripts/teardown.sh --yes   # actually delete
set -uo pipefail

cd "$(dirname "$0")/.."
APPLY=0
[ "${1:-}" = "--yes" ] && APPLY=1

if [ "$APPLY" = "1" ]; then
  echo "Deleting the kubeflare Worker and its container application..."
  npx wrangler delete --force
  rm -f kubeconfig.yaml
  echo "Done. Local kubeconfig.yaml removed."
  echo
  echo "If you created a Cloudflare Tunnel for this (docs/TUNNEL.md), remove it too:"
  echo "  npx wrangler containers list        # confirm nothing named kubeflare remains"
else
  echo "Dry run. This would:"
  echo "  - delete the 'kubeflare' Worker, its Durable Object, and the container application"
  echo "  - remove ./kubeconfig.yaml"
  echo
  npx wrangler containers list 2>/dev/null | grep -i kubeflare || echo "  (no kubeflare container application found)"
  echo
  echo "Re-run with --yes to proceed."
fi
