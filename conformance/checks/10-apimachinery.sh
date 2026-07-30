# shellcheck shell=bash
# CRDs, server-side apply, patch strategies, selectors, watch, paging, admission,
# aggregation, eviction, and the metrics gap.

group "API machinery"

CRD="widgets-$RUN_ID.conformance.kubeflare.test"

check "CRD create + Established condition" '
  k apply -f - >/dev/null <<Y && k wait --for=condition=Established "crd/$CRD" --timeout=60s >/dev/null
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata: {name: $CRD}
spec:
  group: conformance.kubeflare.test
  scope: Namespaced
  names: {plural: widgets-$RUN_ID, singular: widget-$RUN_ID, kind: Widget$RUN_ID, shortNames: [wid$RUN_ID]}
  versions:
  - name: v1
    served: true
    storage: true
    subresources: {status: {}}
    additionalPrinterColumns: [{name: Size, type: integer, jsonPath: .spec.size}]
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            required: [size]
            properties:
              size: {type: integer, minimum: 1, maximum: 10}
              color: {type: string, enum: [red, green, blue]}
Y'

check "custom resource instance create + printer column" '
  kn apply -f - >/dev/null <<Y && kn get "widgets-$RUN_ID" -o jsonpath="{.items[0].spec.size}" | grep -qx 5
apiVersion: conformance.kubeflare.test/v1
kind: Widget$RUN_ID
metadata: {name: w1}
spec: {size: 5, color: blue}
Y'

check "CRD schema validation rejects out-of-range integer" '
  kn apply -f - 2>&1 <<Y | grep -q "should be less than or equal to 10"
apiVersion: conformance.kubeflare.test/v1
kind: Widget$RUN_ID
metadata: {name: w-bad}
spec: {size: 99}
Y'

check "CRD schema validation rejects bad enum value" '
  kn apply -f - 2>&1 <<Y | grep -q "Unsupported value"
apiVersion: conformance.kubeflare.test/v1
kind: Widget$RUN_ID
metadata: {name: w-bad2}
spec: {size: 2, color: purple}
Y'

check "kubectl explain works for the CRD" \
  'k explain "widget-$RUN_ID.spec" 2>&1 | grep -q "enum: red, green, blue"'

# ---- server-side apply -------------------------------------------------------

check "server-side apply records a field manager" '
  kn apply --server-side --field-manager=mgr-a -f - >/dev/null <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: ssa-cm, labels: {app: ssa}}
data: {owner: a, shared: one}
Y
  kn get cm ssa-cm -o jsonpath="{.metadata.managedFields[*].manager}" | grep -q mgr-a'

check "server-side apply detects a field-ownership conflict" '
  kn apply --server-side --field-manager=mgr-b -f - 2>&1 <<Y | grep -q "conflict with \"mgr-a\""
apiVersion: v1
kind: ConfigMap
metadata: {name: ssa-cm}
data: {owner: b}
Y'

check "server-side apply --force-conflicts takes ownership" '
  kn apply --server-side --force-conflicts --field-manager=mgr-b -f - >/dev/null <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: ssa-cm}
data: {owner: b}
Y
  kn get cm ssa-cm -o jsonpath="{.data.owner}" | grep -qx b'

# ---- patches -----------------------------------------------------------------

check "strategic merge patch on a Deployment pod template" '
  kn create deployment smp --image="$IMG_BUSYBOX" --replicas=1 -- sleep 3600 >/dev/null 2>&1
  kn patch deployment smp -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"busybox\",\"env\":[{\"name\":\"SMP\",\"value\":\"yes\"}]}]}}}}" >/dev/null
  kn get deploy smp -o jsonpath="{.spec.template.spec.containers[0].env[0].value}" | grep -qx yes'

check "JSON merge patch" \
  'kn patch cm ssa-cm --type=merge -p "{\"data\":{\"jm\":\"yes\"}}" >/dev/null &&
   kn get cm ssa-cm -o jsonpath="{.data.jm}" | grep -qx yes'

check "JSON patch (add + remove)" \
  'kn patch cm ssa-cm --type=json -p "[{\"op\":\"add\",\"path\":\"/data/jp\",\"value\":\"yes\"},{\"op\":\"remove\",\"path\":\"/data/jm\"}]" >/dev/null &&
   kn get cm ssa-cm -o jsonpath="{.data}" | grep -q "\"jp\"" &&
   ! kn get cm ssa-cm -o jsonpath="{.data}" | grep -q "\"jm\""'

check "--dry-run=server validates without persisting" \
  'kn create configmap dr-test --from-literal=a=b --dry-run=server -o jsonpath="{.metadata.name}" | grep -qx dr-test &&
   ! kn get configmap dr-test >/dev/null 2>&1'

# ---- selectors, watch, paging, resourceVersion --------------------------------

check "label selectors (equality, set-based, negated)" \
  'kn get cm -l app=ssa -o name | grep -q ssa-cm &&
   kn get cm -l "app in (ssa,other)" -o name | grep -q ssa-cm &&
   ! kn get cm -l "!app" -o name | grep -q ssa-cm'

check "field selector on pod status.phase" \
  'kn get pods --field-selector=status.phase=Running -o name | grep -q pod/'

check "pagination returns a continue token" \
  'kraw "/api/v1/configmaps?limit=2" |
     python3 -c "import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if len(d[\"items\"])==2 and d[\"metadata\"].get(\"continue\") else 1)"'

check "kubectl --chunk-size lists across pages" \
  '[ "$(k get cm -A --chunk-size=2 -o name | wc -l | tr -d " ")" -ge 3 ]'

check "stale resourceVersion is rejected with a Conflict" \
  'kn get cm ssa-cm -o yaml | sed "s/resourceVersion: .*/resourceVersion: \"1\"/" |
     kn replace --dry-run=server -f - 2>&1 | grep -q "Conflict\|has been modified"'

check "watch delivers an ADDED event for a new object" '
  ( kn get cm --watch --request-timeout=12s -o name 2>/dev/null > "$LOGDIR/watch.out" ) &
  wpid=$!
  sleep 3
  kn create configmap watch-probe --from-literal=x=1 >/dev/null 2>&1
  wait $wpid 2>/dev/null
  grep -q watch-probe "$LOGDIR/watch.out"'

check "events are recorded (core and events.k8s.io)" \
  '[ "$(kn get events --no-headers 2>/dev/null | wc -l | tr -d " ")" -gt 0 ] &&
   [ "$(kn get events.events.k8s.io --no-headers 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'

# ---- admission ---------------------------------------------------------------

check "ValidatingAdmissionPolicy (CEL) denies a non-conforming object" '
  k apply -f - >/dev/null <<Y
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata: {name: vap-$RUN_ID}
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups: [""]
      apiVersions: ["v1"]
      operations: ["CREATE"]
      resources: ["configmaps"]
  validations:
  - expression: "has(object.metadata.labels) && ${SQ}cf-required${SQ} in object.metadata.labels"
    message: "configmap must carry the cf-required label"
---
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicyBinding
metadata: {name: vap-$RUN_ID}
spec:
  policyName: vap-$RUN_ID
  validationActions: [Deny]
  matchResources:
    namespaceSelector:
      matchLabels: {kubernetes.io/metadata.name: $NS}
Y
  sleep 8
  kn create configmap vap-denied --from-literal=a=b 2>&1 | grep -q "must carry the cf-required label"'

check "ValidatingAdmissionPolicy admits a conforming object" '
  kn apply -f - >/dev/null 2>&1 <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: vap-ok, labels: {cf-required: "yes"}}
data: {a: b}
Y'

# Tear the policy down immediately: it would otherwise block later ConfigMap creates.
k delete validatingadmissionpolicybinding "vap-$RUN_ID" >/dev/null 2>&1
k delete validatingadmissionpolicy "vap-$RUN_ID" >/dev/null 2>&1

# An admission webhook needs a reachable in-cluster Service. Pointing one at the
# plain-HTTP echo Service proves the apiserver resolved the Service DNS name and
# completed a TCP connection: the only complaint left is the protocol mismatch.
check "apiserver can DELIVER an admission webhook to a ClusterIP Service" '
  cab=$(openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
          -out /dev/stdout -days 2 -subj "/CN=echo.$NS.svc" 2>/dev/null | base64 | tr -d "\n")
  k apply -f - >/dev/null <<Y
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: wh-$RUN_ID}
webhooks:
- name: probe.conformance.kubeflare.test
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Fail
  timeoutSeconds: 5
  clientConfig:
    service: {name: echo, namespace: $NS, port: 80, path: /webhook}
    caBundle: $cab
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["configmaps"]
Y
  sleep 5
  out=$(kn create configmap wh-probe --from-literal=a=b 2>&1)
  k delete validatingwebhookconfiguration "wh-$RUN_ID" >/dev/null 2>&1
  printf "%s" "$out" | grep -q "server gave HTTP response to HTTPS client"'

check "webhook against a missing Service reports service not found" '
  cab=$(openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
          -out /dev/stdout -days 2 -subj "/CN=nope.$NS.svc" 2>/dev/null | base64 | tr -d "\n")
  k apply -f - >/dev/null <<Y
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: whmissing-$RUN_ID}
webhooks:
- name: probe.conformance.kubeflare.test
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Fail
  timeoutSeconds: 5
  clientConfig:
    service: {name: nope-does-not-exist, namespace: $NS, port: 443}
    caBundle: $cab
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE"]
    resources: ["configmaps"]
Y
  sleep 5
  out=$(kn create configmap wh-probe2 --from-literal=a=b 2>&1)
  k delete validatingwebhookconfiguration "whmissing-$RUN_ID" >/dev/null 2>&1
  printf "%s" "$out" | grep -q "not found"'

skip "admission webhook that actually admits/denies" \
  "needs a TLS-serving webhook backend with a matching caBundle; delivery is proven above"

# ---- aggregation -------------------------------------------------------------

# The aggregation layer dials the Service's pod endpoint directly. Reaching it at
# all is the interesting part on a cluster with no kube-proxy.
check "API aggregation dials the backing Service endpoint" '
  agg="v1alpha1.agg-$RUN_ID.conformance.kubeflare.test"
  k apply -f - >/dev/null <<Y
apiVersion: apiregistration.k8s.io/v1
kind: APIService
metadata: {name: $agg}
spec:
  group: agg-$RUN_ID.conformance.kubeflare.test
  version: v1alpha1
  groupPriorityMinimum: 100
  versionPriority: 100
  insecureSkipTLSVerify: true
  service: {name: echo, namespace: $NS, port: 80}
Y
  ok=1
  for i in $(seq 1 12); do
    msg=$(k get apiservice "$agg" -o jsonpath="{.status.conditions[*].message}" 2>/dev/null)
    printf "%s" "$msg" | grep -q "server gave HTTP response to HTTPS client" && { ok=0; break; }
    sleep 3
  done
  k delete apiservice "$agg" >/dev/null 2>&1
  [ $ok = 0 ]'

# ---- PodDisruptionBudget + eviction subresource -------------------------------

check "PDB reports allowed disruptions and eviction subresource succeeds" '
  kn create deployment pdbapp --image="$IMG_NGINX" --replicas=2 >/dev/null 2>&1
  kn create poddisruptionbudget pdbapp --selector=app=pdbapp --min-available=1 >/dev/null 2>&1
  wait_rollout deployment/pdbapp 180s
  wait_jsonpath pdb/pdbapp "{.status.disruptionsAllowed}" 1 20 3 || exit 1
  pod=$(kn get pod -l app=pdbapp -o jsonpath="{.items[0].metadata.name}")
  k create -f - --raw "/k8s/api/v1/namespaces/$NS/pods/$pod/eviction" <<Y 2>&1 | grep -q "\"code\":201"
{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"$pod","namespace":"$NS"}}
Y'

# Deliberately a SEPARATE, never-evicted fixture at replicas=1. Reusing pdbapp here
# races: its replacement pod from the eviction above can still be terminating, which
# briefly makes disruptionsAllowed 1 again and lets the eviction through.
check "PDB blocks an eviction that would breach the budget (429)" '
  kn create deployment pdblock --image="$IMG_NGINX" --replicas=1 >/dev/null 2>&1
  kn create poddisruptionbudget pdblock --selector=app=pdblock --min-available=1 >/dev/null 2>&1
  wait_rollout deployment/pdblock 180s || exit 1
  wait_jsonpath pdb/pdblock "{.status.disruptionsAllowed}" 0 25 3 || exit 1
  pod=$(kn get pod -l app=pdblock -o jsonpath="{.items[0].metadata.name}")
  [ -n "$pod" ] || exit 1
  k create -f - --raw "/k8s/api/v1/namespaces/$NS/pods/$pod/eviction" <<Y 2>&1 | grep -q "TooManyRequests\|disruption budget"
{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"$pod","namespace":"$NS"}}
Y'

kn delete deployment pdbapp pdblock --wait=false >/dev/null 2>&1
kn delete pdb pdbapp pdblock --ignore-not-found >/dev/null 2>&1

# ---- metrics / autoscaling gap ------------------------------------------------

# k3s runs with `--disable metrics-server`, so there is no metrics.k8s.io APIService.
xcheck "metrics.k8s.io API is served" \
  "k3s runs with --disable metrics-server; no metrics-server is vendored back in" \
  'kraw /apis/metrics.k8s.io/v1beta1 >/dev/null 2>&1'

xcheck "kubectl top nodes works" \
  "no metrics-server, so the Metrics API is absent" \
  'k top nodes >/dev/null 2>&1'

check "kubectl top fails with the expected 'Metrics API not available'" \
  'k top nodes 2>&1 | grep -q "Metrics API not available"'

check "HPA object is accepted and reports FailedGetResourceMetric" '
  kn create deployment hpa-target --image="$IMG_BUSYBOX" --replicas=1 -- sleep 3600 >/dev/null 2>&1
  kn set resources deployment hpa-target --requests=cpu=10m >/dev/null 2>&1
  kn autoscale deployment hpa-target --min=1 --max=3 --cpu-percent=50 >/dev/null 2>&1
  ok=1
  for i in $(seq 1 12); do
    r=$(kn get hpa hpa-target -o jsonpath="{.status.conditions[?(@.type==\"ScalingActive\")].reason}" 2>/dev/null)
    [ "$r" = FailedGetResourceMetric ] && { ok=0; break; }
    sleep 4
  done
  [ $ok = 0 ]'

xcheck "HPA actually scales on CPU" \
  "HPA controller cannot read metrics without metrics-server: ScalingActive=False" \
  'kn get hpa hpa-target -o jsonpath="{.status.conditions[?(@.type==\"ScalingActive\")].status}" 2>/dev/null | grep -qx True'

kn delete hpa hpa-target --ignore-not-found >/dev/null 2>&1
kn delete deployment hpa-target smp --wait=false >/dev/null 2>&1
