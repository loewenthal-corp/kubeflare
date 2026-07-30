# shellcheck shell=bash
# Pod lifecycle (init containers, native sidecars, probes, hooks, termination) and
# the kubectl surface that has to cross the Worker's WebSocket transport.

group "pod lifecycle"

check "init containers run in order, native sidecar runs alongside, postStart fires" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: life}
spec:
  terminationGracePeriodSeconds: 20
  initContainers:
  - name: init-1
    image: $IMG_BUSYBOX
    command: ["sh","-c","echo init-1 >> /shared/order; sleep 1"]
    volumeMounts: [{name: sh, mountPath: /shared}]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
  - name: init-2
    image: $IMG_BUSYBOX
    command: ["sh","-c","echo init-2 >> /shared/order"]
    volumeMounts: [{name: sh, mountPath: /shared}]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
  - name: sidecar
    image: $IMG_BUSYBOX
    restartPolicy: Always
    # ticks go to STDOUT so `kubectl logs`/`--follow` have something to read
    command: ["sh","-c","echo sidecar >> /shared/order; while true; do echo tick; sleep 2; done"]
    volumeMounts: [{name: sh, mountPath: /shared}]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
  containers:
  - name: main
    image: $IMG_BUSYBOX
    command: ["sh","-c","echo main >> /shared/order; httpd -f -p 8080 -h /shared"]
    ports: [{containerPort: 8080}]
    volumeMounts: [{name: sh, mountPath: /shared}]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
    lifecycle:
      postStart: {exec: {command: ["sh","-c","echo poststart >> /shared/hooks"]}}
      preStop:   {exec: {command: ["sh","-c","echo prestop >> /shared/hooks; sleep 2"]}}
    startupProbe:   {httpGet: {path: /order, port: 8080}, failureThreshold: 15, periodSeconds: 2}
    readinessProbe: {httpGet: {path: /order, port: 8080}, periodSeconds: 3}
  volumes: [{name: sh, emptyDir: {}}]
Y
  wait_ready pod/life 240s || exit 1
  [ "$(kn exec life -c main -- cat /shared/order 2>/dev/null | tr "\n" " ")" = "init-1 init-2 sidecar main " ] &&
  kn exec life -c main -- cat /shared/hooks 2>/dev/null | grep -qx poststart'

check "native sidecar (initContainer restartPolicy=Always) stays running with the pod" \
  'kn get pod life -o jsonpath="{.status.initContainerStatuses[?(@.name==\"sidecar\")].state.running.startedAt}" | grep -q T'

check "startup + readiness probes gate pod readiness" \
  '[ "$(kn get pod life -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}")" = True ]'

check "a failing liveness probe restarts the container" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: badprobe}
spec:
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sleep","3600"]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
    livenessProbe:
      httpGet: {path: /nope, port: 9999}
      periodSeconds: 2
      failureThreshold: 1
      initialDelaySeconds: 2
Y
  ok=1
  for i in $(seq 1 35); do
    rc=$(kn get pod badprobe -o jsonpath="{.status.containerStatuses[0].restartCount}" 2>/dev/null)
    [ -n "$rc" ] && [ "$rc" -ge 1 ] 2>/dev/null && { ok=0; break; }
    sleep 3
  done
  [ $ok = 0 ] &&
  kn get event --field-selector involvedObject.name=badprobe -o jsonpath="{.items[*].reason}" |
    grep -q Unhealthy'

check "restartPolicy: Never leaves a failed pod Failed with 0 restarts" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: rp-never}
spec:
  restartPolicy: Never
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sh","-c","exit 3"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_phase rp-never Failed 30 &&
  [ "$(kn get pod rp-never -o jsonpath="{.status.containerStatuses[0].restartCount}")" = 0 ]'

check "restartPolicy: OnFailure restarts a failing container" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: rp-onfail}
spec:
  restartPolicy: OnFailure
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sh","-c","exit 3"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  ok=1
  for i in $(seq 1 30); do
    rc=$(kn get pod rp-onfail -o jsonpath="{.status.containerStatuses[0].restartCount}" 2>/dev/null)
    [ -n "$rc" ] && [ "$rc" -ge 1 ] 2>/dev/null && { ok=0; break; }
    sleep 3
  done
  [ $ok = 0 ]'

check "SIGTERM is delivered: a trapping container exits well inside its grace period" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: term-fast}
spec:
  terminationGracePeriodSeconds: 30
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sh","-c","trap ${SQ}exit 0${SQ} TERM; while true; do sleep 0.5; done"]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
Y
  wait_ready pod/term-fast 180s || exit 1
  s=$(date +%s); kn delete pod term-fast --timeout=60s >/dev/null 2>&1; e=$(date +%s)
  [ $((e-s)) -lt 12 ]'

check "terminationGracePeriodSeconds is enforced, then SIGKILL" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: term-slow}
spec:
  terminationGracePeriodSeconds: 8
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sh","-c","trap ${SQ}${SQ} TERM; while true; do sleep 0.5; done"]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
Y
  wait_ready pod/term-slow 180s || exit 1
  s=$(date +%s); kn delete pod term-slow --timeout=60s >/dev/null 2>&1; e=$(date +%s)
  d=$((e-s)); [ $d -ge 7 ] && [ $d -le 20 ]'

check "ephemeral container via kubectl debug, and exec into it" '
  kn debug life -c dbg --image="$IMG_BUSYBOX" --target=main -- sleep 300 >/dev/null 2>&1
  ok=1
  for i in $(seq 1 20); do
    kn get pod life -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"dbg\")].state.running.startedAt}" 2>/dev/null | grep -q T && { ok=0; break; }
    sleep 3
  done
  [ $ok = 0 ] && kn exec life -c dbg -- echo ephemeral-ok 2>/dev/null | grep -qx ephemeral-ok'

group "kubectl surface (through the Worker)"

check "kubectl logs" \
  'kn logs life -c sidecar --tail=1 2>/dev/null | grep -q tick'

check "kubectl logs --previous returns the prior incarnation" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: logger}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX,
                command: ["sh","-c","echo INCARNATION-\$(date +%s%N); sleep 5; exit 1"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  ok=1
  for i in $(seq 1 30); do
    rc=$(kn get pod logger -o jsonpath="{.status.containerStatuses[0].restartCount}" 2>/dev/null)
    [ -n "$rc" ] && [ "$rc" -ge 1 ] 2>/dev/null && { ok=0; break; }
    sleep 3
  done
  [ $ok = 0 ] || exit 1
  prev=$(kn logs logger --previous --tail=1 2>/dev/null)
  cur=$(kn logs logger --tail=1 2>/dev/null)
  printf "%s" "$prev" | grep -q INCARNATION &&
  [ "$prev" != "$cur" ]'

check "kubectl logs --follow streams" \
  'timeout 15 kubectl -n "$NS" logs life -c sidecar --follow --tail=1 2>/dev/null | head -1 | grep -q tick'

check "kubectl exec" \
  'kn exec client -- echo exec-ok 2>/dev/null | grep -qx exec-ok'

check "kubectl attach connects over the WebSocket transport" \
  'timeout 15 kubectl -n "$NS" attach client 2>&1 | grep -qi "command prompt\|^$"'

check "kubectl cp into a pod" \
  'printf "cp-payload-%s\n" "$RUN_ID" > "$LOGDIR/cp-in.txt";
   kn cp "$LOGDIR/cp-in.txt" "client:/tmp/cp-in.txt" >/dev/null 2>&1;
   kn exec client -- cat /tmp/cp-in.txt 2>/dev/null | grep -qx "cp-payload-$RUN_ID"'

check "kubectl cp out of a pod" \
  'kn exec client -- sh -c "echo from-pod > /tmp/cp-out.txt" >/dev/null 2>&1;
   rm -f "$LOGDIR/cp-out.txt";
   kn cp "client:/tmp/cp-out.txt" "$LOGDIR/cp-out.txt" >/dev/null 2>&1;
   grep -qx from-pod "$LOGDIR/cp-out.txt"'

# A per-run random port: a leaked port-forward from an earlier run would otherwise hold
# a fixed port and make this fail for the wrong reason. Children are reaped explicitly
# because killing the backgrounded function does not kill its timeout/kubectl children.
check "kubectl port-forward carries real traffic" '
  pfport=$(( 20000 + RANDOM % 20000 ))
  kn port-forward deploy/echo "$pfport:8080" >"$LOGDIR/pf.log" 2>&1 &
  pf=$!
  ok=1
  for i in $(seq 1 15); do
    curl -s -m 5 "http://127.0.0.1:$pfport/hostname" 2>/dev/null | grep -q "^echo-" && { ok=0; break; }
    sleep 2
  done
  pkill -P $pf 2>/dev/null; kill $pf 2>/dev/null; wait $pf 2>/dev/null
  pkill -f "port-forward deploy/echo $pfport" 2>/dev/null
  [ $ok = 0 ] || { echo "port-forward log:"; cat "$LOGDIR/pf.log" 2>/dev/null; exit 1; }'

# Revisions are created with `set env`, not `set image`: changing the image would pull a
# second nginx variant, which on 2 vCPU can outlast any sane rollout timeout and makes
# this check flaky for reasons unrelated to rollout machinery.
check "kubectl rollout status / history / undo / restart" '
  kn set env deployment/roll ROLLOUT_MARKER=v2 >/dev/null 2>&1
  wait_rollout deployment/roll 240s || exit 1
  kn rollout history deployment/roll 2>/dev/null | grep -q "REVISION" || exit 1
  kn rollout undo deployment/roll >/dev/null 2>&1
  wait_rollout deployment/roll 240s || exit 1
  # undo must remove the env added in the newer revision
  kn get deploy roll -o jsonpath="{.spec.template.spec.containers[0].env}" 2>/dev/null |
    grep -q ROLLOUT_MARKER && exit 1
  kn rollout restart deployment/roll >/dev/null 2>&1
  wait_rollout deployment/roll 240s'

check "kubectl scale" \
  'kn scale deployment roll --replicas=3 >/dev/null 2>&1;
   wait_jsonpath deploy/roll "{.status.readyReplicas}" 3 40 3'

check "kubectl wait --for=jsonpath" \
  'kn wait --for=jsonpath="{.status.readyReplicas}"=3 deployment/roll --timeout=60s >/dev/null 2>&1'

check "kubectl diff reports a pending change" \
  'kn get deploy roll -o yaml > "$LOGDIR/roll.yaml" 2>/dev/null;
   sed -i.bak "s/replicas: 3/replicas: 5/" "$LOGDIR/roll.yaml";
   kn diff -f "$LOGDIR/roll.yaml" 2>/dev/null | grep -q "replicas"'

check "kubectl apply --prune removes objects dropped from the manifest set" '
  d="$LOGDIR/prune"; mkdir -p "$d"
  cat > "$d/a.yaml" <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: prune-a, labels: {pruneset: "yes"}}
data: {k: a}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: prune-b, labels: {pruneset: "yes"}}
data: {k: b}
Y
  kn apply -f "$d/a.yaml" >/dev/null 2>&1
  [ "$(kn get cm -l pruneset=yes --no-headers 2>/dev/null | wc -l | tr -d " ")" = 2 ] || exit 1
  cat > "$d/a.yaml" <<Y
apiVersion: v1
kind: ConfigMap
metadata: {name: prune-a, labels: {pruneset: "yes"}}
data: {k: a}
Y
  kn apply -f "$d/a.yaml" --prune -l pruneset=yes >/dev/null 2>&1
  [ "$(kn get cm -l pruneset=yes --no-headers 2>/dev/null | wc -l | tr -d " ")" = 1 ]'

kn delete pod life badprobe rp-never rp-onfail logger --wait=false >/dev/null 2>&1

group "security posture"

# The container runs `kubectl proxy` on the node so the Worker can forward to it.
# That proxy holds the real cluster-admin kubeconfig and requires NO authentication.
# Because the AnyIP route makes the whole service CIDR local, every pod can reach it
# -- at the node IP or at any ClusterIP -- and act as cluster-admin.
PROXY_WHY="node-local kubectl proxy on :8001 holds cluster-admin and requires no auth; the AnyIP service CIDR makes it reachable from every pod"

# These assert the hole POSITIVELY and return 2 if the probe pod is unusable, so a
# missing fixture can never be reported as "the hole is closed".
_probe_ready() { kn get pod client >/dev/null 2>&1 && kn exec client -- true >/dev/null 2>&1; }

defect "unprivileged pod can read kube-system Secrets with no credentials" "$PROXY_WHY" \
  '_probe_ready || exit 2
   kx "wget -q -T10 -O- http://10.0.0.1:8001/k8s/api/v1/namespaces/kube-system/secrets?limit=1" |
     grep -q SecretList'

defect "unprivileged pod can reach the admin proxy via an arbitrary ClusterIP" "$PROXY_WHY" \
  '_probe_ready || exit 2
   kx "wget -q -T10 -O- http://10.43.77.77:8001/k8s/api/v1/nodes" | grep -q NodeList'

defect "unprivileged pod can WRITE to the API with no credentials" "$PROXY_WHY" \
  '_probe_ready || exit 2
   body="{\"apiVersion\":\"v1\",\"kind\":\"ConfigMap\",\"metadata\":{\"name\":\"pwned-$RUN_ID\"},\"data\":{\"x\":\"y\"}}"
   kx "wget -q -T10 -O- --header=${SQ}Content-Type: application/json${SQ} \
        --post-data=${SQ}$body${SQ} \
        http://10.0.0.1:8001/k8s/api/v1/namespaces/$NS/configmaps" >/dev/null 2>&1
   landed=1
   kn get configmap "pwned-$RUN_ID" >/dev/null 2>&1 && landed=0
   kn delete configmap "pwned-$RUN_ID" --ignore-not-found >/dev/null 2>&1
   [ $landed = 0 ]'
