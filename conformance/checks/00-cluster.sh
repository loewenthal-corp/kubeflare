# shellcheck shell=bash
# Cluster identity and the raw API surface. Everything downstream assumes these.

group "cluster / discovery"

check "apiserver /readyz reports ok (via the /k8s prefix)" \
  '[ "$(kraw /readyz)" = "ok" ]'

check "server is k3s v1.36.x" \
  'k version -o json 2>/dev/null | grep -q "\"gitVersion\": \"v1.36"'

check "single node is Ready" \
  '[ "$(k get node "$NODE" -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}")" = "True" ]'

check "node has no leftover taints" \
  '[ -z "$(k get node "$NODE" -o jsonpath="{.spec.taints}")" ]'

check "node advertises 2 cpu / 110 pods" \
  'k get node "$NODE" -o jsonpath="{.status.allocatable.cpu} {.status.allocatable.pods}" | grep -qx "2 110"'

check "core API groups are served (apps, batch, networking, policy, rbac, storage)" \
  'v=$(k api-versions); for g in apps/v1 batch/v1 networking.k8s.io/v1 policy/v1 \
     rbac.authorization.k8s.io/v1 storage.k8s.io/v1 admissionregistration.k8s.io/v1 \
     apiextensions.k8s.io/v1 autoscaling/v2 discovery.k8s.io/v1 scheduling.k8s.io/v1; do
     printf "%s\n" "$v" | grep -qx "$g" || exit 1; done'

check "api-resources enumerates >70 kinds" \
  '[ "$(k api-resources --no-headers 2>/dev/null | wc -l | tr -d " ")" -gt 70 ]'

check "local-path is the default StorageClass" \
  'k get sc local-path -o jsonpath="{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}" | grep -qx true'

check "openapi v2 is served" \
  'kraw /openapi/v2 > "$LOGDIR/openapi.json" 2>/dev/null;
   grep -q "\"swagger\"" "$LOGDIR/openapi.json"'

check "apiserver /metrics is served" \
  'kraw /metrics > "$LOGDIR/metrics.txt" 2>/dev/null;
   grep -q "^apiserver_storage_objects" "$LOGDIR/metrics.txt"'

check "kubectl explain works for a built-in type" \
  'k explain deployment.spec.strategy 2>&1 | grep -q "DeploymentStrategy"'

# ---- transport limitations of the Worker passthrough -------------------------

# `kubectl get --raw <path>` keeps only the HOST from the kubeconfig server URL and
# throws away the /k8s path prefix, so it lands on the Worker's dashboard route.
# Because the kubeconfig token doubles as the dashboard token, that route answers
# 200 + HTML -- a raw check can therefore "succeed" while never reaching the
# apiserver at all. This is a transport artifact, not a cluster defect.
xcheck "kubectl get --raw with a bare path reaches the apiserver" \
  "bare --raw path hits the Worker dashboard and returns HTML 200; use --raw /k8s/<path>" \
  'k get --raw /version 2>/dev/null | grep -q "\"gitVersion\""'

check "the same raw path DOES work when /k8s is spelled out" \
  'kraw /version | grep -q "\"gitVersion\": \"v1.36"'

# There is exactly one external identity: the Worker compares the bearer token
# against KUBE_GUARD before forwarding, so no other credential can authenticate.
xcheck "a ServiceAccount token can authenticate from outside the cluster" \
  "the Worker validates the bearer token against KUBE_GUARD and 403s anything else" \
  'kn create sa extauth >/dev/null 2>&1;
   t=$(kn create token extauth 2>/dev/null);
   [ -n "$t" ] && k -n "$NS" --token="$t" get configmaps >/dev/null 2>&1'
