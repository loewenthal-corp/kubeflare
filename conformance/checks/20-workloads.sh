# shellcheck shell=bash
# Deployment, ReplicaSet, StatefulSet, DaemonSet, Job, CronJob.

group "workloads"

check "Deployment rolls out to the requested replica count" \
  'kn create deployment roll --image="$IMG_NGINX" --replicas=2 >/dev/null 2>&1;
   wait_rollout deployment/roll 180s'

check "ReplicaSet created directly reaches its replica count" '
  kn apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: ReplicaSet
metadata: {name: rs}
spec:
  replicas: 2
  selector: {matchLabels: {app: rs}}
  template:
    metadata: {labels: {app: rs}}
    spec:
      containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                    resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_jsonpath rs/rs "{.status.readyReplicas}" 2 30 3'

check "DaemonSet schedules exactly one pod on the single node" '
  kn apply -f - >/dev/null <<Y
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: ds}
spec:
  selector: {matchLabels: {app: ds}}
  template:
    metadata: {labels: {app: ds}}
    spec:
      containers: [{name: c, image: $IMG_BUSYBOX, command: ["sleep","3600"],
                    resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  wait_jsonpath ds/ds "{.status.numberReady}" 1 30 3'

kn delete rs rs ds ds --wait=false >/dev/null 2>&1

# ---- StatefulSet: ordinals, volumeClaimTemplates, stable network identity ------

check "StatefulSet with volumeClaimTemplates becomes ready" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Service
metadata: {name: sts}
spec:
  clusterIP: None
  selector: {app: sts}
  ports: [{name: http, port: 8080}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: sts}
spec:
  serviceName: sts
  replicas: 2
  podManagementPolicy: Parallel
  selector: {matchLabels: {app: sts}}
  template:
    metadata: {labels: {app: sts}}
    spec:
      terminationGracePeriodSeconds: 5
      containers:
      - name: c
        image: $IMG_BUSYBOX
        command: ["sh","-c","echo \$(hostname) > /data/id; httpd -f -p 8080 -h /data"]
        ports: [{name: http, containerPort: 8080}]
        volumeMounts: [{name: data, mountPath: /data}]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      resources: {requests: {storage: 64Mi}}
Y
  wait_jsonpath sts/sts "{.status.readyReplicas}" 2 45 4'

check "StatefulSet pods get stable ordinal names" \
  'kn get pod sts-0 sts-1 -o name >/dev/null 2>&1'

check "each StatefulSet replica binds its own PVC" \
  '[ "$(kn get pvc data-sts-0 -o jsonpath="{.status.phase}")" = Bound ] &&
   [ "$(kn get pvc data-sts-1 -o jsonpath="{.status.phase}")" = Bound ]'

check "per-pod DNS A records resolve for headless StatefulSet pods" \
  'kx "nslookup sts-0.sts.$NS.svc.cluster.local" | grep -q "Address: 10.42" &&
   kx "nslookup sts-1.sts.$NS.svc.cluster.local" | grep -q "Address: 10.42"'

check "a StatefulSet pod is reachable by its stable DNS name" \
  'kx "wget -q -T8 -O- http://sts-0.sts.$NS.svc.cluster.local:8080/id" | grep -qx sts-0'

check "StatefulSet PVC data survives pod deletion (volume reattach)" '
  kn exec sts-0 -- sh -c "echo persisted-marker > /data/marker" >/dev/null 2>&1
  kn delete pod sts-0 --wait=true >/dev/null 2>&1
  wait_phase sts-0 Running 30 || exit 1
  for i in $(seq 1 10); do
    kn exec sts-0 -- cat /data/marker 2>/dev/null | grep -qx persisted-marker && exit 0
    sleep 3
  done
  exit 1'

# whenDeleted/whenScaled retention defaults to Retain, so scaling down keeps the PVC.
check "StatefulSet PVC retention keeps the claim when scaled down" '
  kn scale statefulset sts --replicas=1 >/dev/null 2>&1
  sleep 10
  [ "$(kn get pvc data-sts-1 -o jsonpath="{.status.phase}" 2>/dev/null)" = Bound ]'

# ---- Job / CronJob ------------------------------------------------------------

check "Job with Indexed completion mode and parallelism completes all indexes" '
  kn apply -f - >/dev/null <<Y
apiVersion: batch/v1
kind: Job
metadata: {name: job-indexed}
spec:
  completions: 4
  parallelism: 2
  completionMode: Indexed
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: c
        image: $IMG_BUSYBOX
        command: ["sh","-c","echo idx=\$JOB_COMPLETION_INDEX; sleep 1"]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
Y
  kn wait --for=condition=Complete job/job-indexed --timeout=180s >/dev/null 2>&1 &&
  [ "$(kn get job job-indexed -o jsonpath="{.status.completedIndexes}")" = "0-3" ]'

check "JOB_COMPLETION_INDEX is injected into each pod" \
  '[ "$(kn get pods -l job-name=job-indexed \
      -o jsonpath="{range .items[*]}{.metadata.annotations.batch\.kubernetes\.io/job-completion-index}{\"\\n\"}{end}" \
      | sort -u | tr -d "\n")" = "0123" ]'

check "Job backoffLimit is enforced on a persistently failing pod" '
  kn apply -f - >/dev/null <<Y
apiVersion: batch/v1
kind: Job
metadata: {name: job-fail}
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers: [{name: c, image: $IMG_BUSYBOX, command: ["sh","-c","exit 1"],
                    resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  ok=1
  for i in $(seq 1 45); do
    r=$(kn get job job-fail -o jsonpath="{.status.conditions[?(@.type==\"Failed\")].reason}" 2>/dev/null)
    [ "$r" = BackoffLimitExceeded ] && { ok=0; break; }
    sleep 4
  done
  [ $ok = 0 ] && [ "$(kn get job job-fail -o jsonpath="{.status.failed}")" = 3 ]'

check "CronJob is accepted and suspend toggles" '
  kn apply -f - >/dev/null <<Y
apiVersion: batch/v1
kind: CronJob
metadata: {name: cj}
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers: [{name: c, image: $IMG_BUSYBOX, command: ["sh","-c","echo cronjob-ran"],
                        resources: {requests: {cpu: 10m, memory: 16Mi}}}]
Y
  kn patch cronjob cj -p "{\"spec\":{\"suspend\":true}}" >/dev/null &&
  [ "$(kn get cronjob cj -o jsonpath="{.spec.suspend}")" = true ] &&
  kn patch cronjob cj -p "{\"spec\":{\"suspend\":false}}" >/dev/null &&
  [ "$(kn get cronjob cj -o jsonpath="{.spec.suspend}")" = false ]'

check "CronJob controller actually fires a scheduled Job (<=90s)" '
  ok=1
  for i in $(seq 1 24); do
    [ -n "$(kn get cronjob cj -o jsonpath="{.status.lastScheduleTime}" 2>/dev/null)" ] && { ok=0; break; }
    sleep 5
  done
  [ $ok = 0 ]'

kn delete cronjob cj --wait=false >/dev/null 2>&1
kn delete job job-indexed job-fail --wait=false >/dev/null 2>&1
