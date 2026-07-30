#!/usr/bin/env bash
#
# kubeflare Kubernetes API conformance suite.
#
#   ./conformance/run.sh              run everything, clean up afterwards
#   ./conformance/run.sh --keep       leave all resources for inspection
#   ./conformance/run.sh --group 30   run one check group (prefix match)
#   ./conformance/run.sh --verbose    echo command output for passing checks too
#
# Exits non-zero if anything UNEXPECTEDLY fails. Known limitations are encoded as
# XFAIL, so a limitation that gets fixed shows up as XPASS rather than silently
# disappearing -- see conformance/README.md.
#
# Requires: kubectl, curl, openssl, python3, and KUBECONFIG pointing at the cluster.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

GROUP_FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep)    KEEP=1 ;;
    --verbose) VERBOSE=1 ;;
    --group)   GROUP_FILTER="${2:-}"; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown flag: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

export KEEP="${KEEP:-0}"
export VERBOSE="${VERBOSE:-0}"
export KUBECONFIG="${KUBECONFIG:-$REPO/kubeconfig.yaml}"

# shellcheck source=conformance/lib.sh
. "$HERE/lib.sh"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 2; }

printf '%skubeflare conformance%s  run=%s  ns=%s\n' "$C_HEAD" "$C_OFF" "$RUN_ID" "$NS"
printf 'kubeconfig: %s\n' "$KUBECONFIG"

# The cluster is a Cloudflare Container: it may be asleep, cold-booting, or being
# bounced by another workstream. Treat that as retryable rather than as a failure.
if ! wait_cluster 40; then
  printf '\n%sapiserver did not become ready.%s\n' "$C_FAIL" "$C_OFF" >&2
  printf 'Wake it with:  curl -s -m 150 %s\n' "$WAKE_URL" >&2
  printf 'then re-check: kubectl get --raw /k8s/readyz   (the /k8s prefix matters)\n' >&2
  exit 2
fi

NODE="$(k get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
export NODE
printf 'node: %s   server: %s\n' \
  "$NODE" "$(k version -o json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo '?')"

trap cleanup EXIT INT TERM

# Idempotent: start from a clean namespace every time.
k delete ns "$NS" "$QNS" --wait=true --ignore-not-found >/dev/null 2>&1
k create ns "$NS" >/dev/null 2>&1

# ---------------------------------------------------------------- shared fixtures
# One agnhost Service (an echo backend that reports its hostname and the client IP
# it sees) and one busybox client pod. Almost every networking check reuses these,
# which keeps the pod count low and the runtime down.
group "fixtures"
check "shared fixtures (agnhost echo Service x2 + busybox client) become ready" '
  kn apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: echo, labels: {app: echo}}
spec:
  replicas: 2
  selector: {matchLabels: {app: echo}}
  template:
    metadata: {labels: {app: echo}}
    spec:
      containers:
      - name: agnhost
        image: $IMG_AGNHOST
        args: ["netexec", "--http-port=8080", "--udp-port=8081"]
        ports:
        - {name: http, containerPort: 8080}
        - {name: udp, containerPort: 8081, protocol: UDP}
        resources: {requests: {cpu: 10m, memory: 24Mi}}
        readinessProbe: {httpGet: {path: /healthz, port: 8080}, initialDelaySeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: echo}
spec:
  selector: {app: echo}
  ports:
  - {name: http, port: 80, targetPort: http}
  - {name: udp,  port: 90, targetPort: udp, protocol: UDP}
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {app: client}}
spec:
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sleep","7200"]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
Y
  wait_rollout deployment/echo 300s && wait_ready pod/client 300s'

if [ "$FAIL_N" -gt 0 ]; then
  printf '\n%sfixtures failed to come up; aborting.%s\n' "$C_FAIL" "$C_OFF" >&2
  summary; exit 1
fi

# ---------------------------------------------------------------- run the groups
for f in "$HERE"/checks/*.sh; do
  base="$(basename "$f")"
  if [ -n "$GROUP_FILTER" ] && [[ "$base" != "$GROUP_FILTER"* ]]; then continue; fi
  # shellcheck disable=SC1090
  . "$f"
done

summary
