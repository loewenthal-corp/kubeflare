# shellcheck shell=bash
# PVC/PV lifecycle on the vendored local-path provisioner, plus scheduler features.

group "storage"

check "PVC binds via the local-path provisioner" \
  '[ "$(kn get pvc standalone-pvc -o jsonpath="{.status.phase}")" = Bound ]'

check "a bound PVC gets a PV with the local-path StorageClass" \
  'pv=$(kn get pvc standalone-pvc -o jsonpath="{.spec.volumeName}");
   [ -n "$pv" ] && [ "$(k get pv "$pv" -o jsonpath="{.spec.storageClassName}")" = local-path ]'

check "PVC is RWO" \
  'kn get pvc standalone-pvc -o jsonpath="{.status.accessModes[0]}" | grep -qx ReadWriteOnce'

# Self-contained: depending on the kitchen pod from the previous group would race with
# its asynchronous delete. The PVC for an inline ephemeral volume is <pod>-<volume>.
check "generic ephemeral inline volume is provisioned, then reclaimed with the pod" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: ephpod}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sh","-c","echo eph-ok > /d/f; cat /d/f; sleep 120"]
    volumeMounts: [{name: v, mountPath: /d}]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
  volumes:
  - name: v
    ephemeral:
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources: {requests: {storage: 32Mi}}
Y
  wait_ready pod/ephpod 240s || exit 1
  wait_jsonpath pvc/ephpod-v "{.status.phase}" Bound 30 3 || exit 1
  kn exec ephpod -- cat /d/f 2>/dev/null | grep -qx eph-ok || exit 1
  kn delete pod ephpod --wait=true >/dev/null 2>&1
  for i in $(seq 1 25); do
    kn get pvc ephpod-v >/dev/null 2>&1 || exit 0
    sleep 3
  done
  exit 1'

check "reclaimPolicy Delete removes the PV when the PVC goes away" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: reclaim-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 32Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: reclaim-pod}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sh","-c","echo hi > /d/f"]
    volumeMounts: [{name: v, mountPath: /d}]
    resources: {requests: {cpu: 10m, memory: 16Mi}}
  volumes: [{name: v, persistentVolumeClaim: {claimName: reclaim-pvc}}]
Y
  wait_jsonpath pvc/reclaim-pvc "{.status.phase}" Bound 40 3 || exit 1
  pv=$(kn get pvc reclaim-pvc -o jsonpath="{.spec.volumeName}")
  [ "$(k get pv "$pv" -o jsonpath="{.spec.persistentVolumeReclaimPolicy}")" = Delete ] || exit 1
  kn delete pod reclaim-pod --wait=true >/dev/null 2>&1
  kn delete pvc reclaim-pvc --wait=true >/dev/null 2>&1
  for i in $(seq 1 25); do
    k get pv "$pv" >/dev/null 2>&1 || exit 0
    sleep 3
  done
  exit 1'

check "StorageClass WaitForFirstConsumer defers binding until a pod exists" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: wffc-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 32Mi}}
Y
  sleep 8
  [ "$(kn get pvc wffc-pvc -o jsonpath="{.status.phase}")" = Pending ]'

kn delete pvc wffc-pvc --wait=false >/dev/null 2>&1

skip "ReadWriteMany / ReadOnlyMany volumes" "local-path provisions RWO only; single node"
skip "VolumeSnapshot / CSI snapshots"       "no CSI driver is installed (kubectl get csidrivers is empty)"
skip "volume expansion"                     "local-path sets allowVolumeExpansion=false"
skip "juicefs-r2 StorageClass"              "not present in the running cluster"

group "scheduling"

check "QoS class Guaranteed (requests == limits)" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: qos-g}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 50m, memory: 32Mi}, limits: {cpu: 50m, memory: 32Mi}}}]
Y
  wait_phase qos-g Running 30 &&
  [ "$(kn get pod qos-g -o jsonpath="{.status.qosClass}")" = Guaranteed ]'

check "QoS class BestEffort (no requests or limits)" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: qos-b}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"]}]
Y
  wait_phase qos-b Running 30 &&
  [ "$(kn get pod qos-b -o jsonpath="{.status.qosClass}")" = BestEffort ]'

check "nodeSelector schedules a matching pod" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: sel-ok}
spec:
  nodeSelector: {kubernetes.io/hostname: $NODE}
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_phase sel-ok Running 30'

check "nodeSelector leaves an unmatched pod Pending with FailedScheduling" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: sel-no}
spec:
  nodeSelector: {disktype: does-not-exist}
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  sleep 10
  [ "$(phase sel-no)" = Pending ] &&
  kn get event --field-selector involvedObject.name=sel-no -o jsonpath="{.items[*].reason}" |
    grep -q FailedScheduling'

check "required nodeAffinity schedules a matching pod" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: aff-node, labels: {grp: aff}}
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions: [{key: kubernetes.io/os, operator: In, values: [linux]}]
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_phase aff-node Running 30'

check "podAffinity co-locates with an existing pod" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: aff-co}
spec:
  affinity:
    podAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector: {matchLabels: {grp: aff}}
        topologyKey: kubernetes.io/hostname
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_phase aff-co Running 30'

# The mechanism works: on one node, hostname anti-affinity correctly has nowhere to
# put a second pod, so it stays Pending. That is right, not broken -- but it does
# mean anti-affinity buys you nothing here.
check "podAntiAffinity is evaluated and correctly refuses the single node" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: aff-anti, labels: {grp: aff}}
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector: {matchLabels: {grp: aff}}
        topologyKey: kubernetes.io/hostname
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  sleep 10
  [ "$(phase aff-anti)" = Pending ] &&
  kn get event --field-selector involvedObject.name=aff-anti -o jsonpath="{.items[*].message}" |
    grep -q "anti-affinity"'

skip "podAntiAffinity actually spreading pods" "single node: there is no second topology domain"

check "topologySpreadConstraints admit both replicas in one domain" '
  kn apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: Deployment
metadata: {name: tsc}
spec:
  replicas: 2
  selector: {matchLabels: {app: tsc}}
  template:
    metadata: {labels: {app: tsc}}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: tsc}}
      containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                    resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_jsonpath deploy/tsc "{.status.readyReplicas}" 2 30 3'

kn delete deploy tsc --wait=false >/dev/null 2>&1
kn delete pod qos-g qos-b sel-ok sel-no aff-node aff-co aff-anti --wait=false >/dev/null 2>&1

check "taint blocks an untolerating pod and a toleration admits one" '
  k taint node "$NODE" "taint-$RUN_ID=yes:NoSchedule" --overwrite >/dev/null 2>&1
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: taint-no}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
---
apiVersion: v1
kind: Pod
metadata: {name: taint-yes}
spec:
  tolerations: [{key: taint-$RUN_ID, operator: Equal, value: "yes", effect: NoSchedule}]
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_phase taint-yes Running 30; ok_yes=$?
  sleep 5
  [ "$(phase taint-no)" = Pending ]; ok_no=$?
  # Always remove the taint, whatever happened.
  k taint node "$NODE" "taint-$RUN_ID-" >/dev/null 2>&1
  [ $ok_yes = 0 ] && [ $ok_no = 0 ]'

check "the test taint was removed from the node" \
  '! k get node "$NODE" -o jsonpath="{.spec.taints[*].key}" | grep -q "taint-$RUN_ID"'

kn delete pod taint-no taint-yes --wait=false >/dev/null 2>&1

check "PriorityClass preemption evicts a lower-priority pod" '
  k apply -f - >/dev/null <<Y
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: low-$RUN_ID}
value: 100
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: high-$RUN_ID}
value: 100000
Y
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: victim}
spec:
  priorityClassName: low-$RUN_ID
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 1200m, memory: 64Mi}}}]
Y
  wait_phase victim Running 40 || exit 1
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: preemptor}
spec:
  priorityClassName: high-$RUN_ID
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 1200m, memory: 64Mi}}}]
Y
  ok=1
  for i in $(seq 1 30); do
    if [ "$(phase preemptor)" = Running ] && [ -z "$(phase victim)" ]; then ok=0; break; fi
    sleep 3
  done
  [ $ok = 0 ] &&
  kn get event --field-selector reason=Preempted -o jsonpath="{.items[*].message}" | grep -q "Preempted by"'

kn delete pod preemptor victim --wait=false >/dev/null 2>&1

# Quota and LimitRange live in their own namespace: a CPU quota forces every pod in
# the namespace to declare requests, which would break unrelated checks.
check "ResourceQuota enforces a hard limit and requires requests" '
  k create ns "$QNS" >/dev/null 2>&1
  # The namespace must be Active before the quota lands, and the quota controller must
  # have published .status before admission will enforce it. A fixed sleep is not enough
  # on a loaded 2-vCPU node, and an unenforced quota silently lets the test pods through.
  wait_jsonpath_ns(){ for i in $(seq 1 30); do
      [ "$(k get ns "$QNS" -o jsonpath="{.status.phase}" 2>/dev/null)" = Active ] && return 0
      sleep 2; done; return 1; }
  wait_jsonpath_ns || exit 1
  k -n "$QNS" apply -f - >/dev/null <<Y
apiVersion: v1
kind: ResourceQuota
metadata: {name: rq}
spec:
  hard: {pods: "2", requests.cpu: 200m, requests.memory: 128Mi, configmaps: "3"}
Y
  quota_ready=1
  for i in $(seq 1 30); do
    if k -n "$QNS" get resourcequota rq -o jsonpath="{.status.hard.pods}" 2>/dev/null | grep -qx 2; then
      quota_ready=0; break
    fi
    sleep 2
  done
  [ $quota_ready = 0 ] || exit 1
  sleep 3
  k -n "$QNS" apply -f - >/dev/null 2>&1 <<Y
apiVersion: v1
kind: Pod
metadata: {name: q-ok}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 50m, memory: 32Mi}}}]
Y
  over=$(k -n "$QNS" apply -f - 2>&1 <<Y
apiVersion: v1
kind: Pod
metadata: {name: q-over}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 500m, memory: 32Mi}}}]
Y
)
  norq=$(k -n "$QNS" apply -f - 2>&1 <<Y
apiVersion: v1
kind: Pod
metadata: {name: q-none}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"]}]
Y
)
  printf "%s" "$over"  | grep -q "exceeded quota" &&
  printf "%s" "$norq" | grep -q "must specify requests.cpu"'

check "LimitRange injects defaults and rejects out-of-range resources" '
  k -n "$QNS" apply -f - >/dev/null <<Y
apiVersion: v1
kind: LimitRange
metadata: {name: lr}
spec:
  limits:
  - type: Container
    default: {cpu: 60m, memory: 48Mi}
    defaultRequest: {cpu: 30m, memory: 24Mi}
    max: {cpu: 100m, memory: 64Mi}
    min: {cpu: 5m, memory: 8Mi}
Y
  sleep 4
  k -n "$QNS" delete pod q-ok --ignore-not-found >/dev/null 2>&1
  k -n "$QNS" apply -f - >/dev/null 2>&1 <<Y
apiVersion: v1
kind: Pod
metadata: {name: lr1}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"]}]
Y
  sleep 4
  injected=$(k -n "$QNS" get pod lr1 -o jsonpath="{.spec.containers[0].resources.requests.cpu}" 2>/dev/null)
  overmax=$(k -n "$QNS" apply -f - 2>&1 <<Y
apiVersion: v1
kind: Pod
metadata: {name: lr2}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 90m, memory: 32Mi}, limits: {cpu: 900m, memory: 32Mi}}}]
Y
)
  undermin=$(k -n "$QNS" apply -f - 2>&1 <<Y
apiVersion: v1
kind: Pod
metadata: {name: lr3}
spec:
  containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                resources: {requests: {cpu: 1m, memory: 32Mi}, limits: {cpu: 50m, memory: 32Mi}}}]
Y
)
  [ "$injected" = 30m ] &&
  printf "%s" "$overmax"  | grep -q "maximum cpu usage per Container" &&
  printf "%s" "$undermin" | grep -q "minimum cpu usage per Container"'
