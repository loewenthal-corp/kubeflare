# shellcheck shell=bash
# ConfigMaps, Secrets, projected volumes, the downward API, ServiceAccount tokens,
# and RBAC enforcement.

group "config and identity"

check "kitchen-sink pod mounting every config/identity/storage source becomes ready" '
  kn create configmap cfg --from-literal=KEY1=val1 --from-literal=KEY2=val2 \
     --from-literal=file.conf="line1
line2" >/dev/null 2>&1
  kn create secret generic sec --from-literal=USER=admin --from-literal=PASS=s3cr3t >/dev/null 2>&1
  kn create sa apicaller >/dev/null 2>&1
  kn create role cm-only --verb=get,list --resource=configmaps >/dev/null 2>&1
  kn create rolebinding cm-only --role=cm-only --serviceaccount=$NS:apicaller >/dev/null 2>&1
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: standalone-pvc}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 64Mi}}
---
apiVersion: v1
kind: Pod
metadata:
  name: kitchen
  labels: {app: kitchen, tier: test}
  annotations: {conformance/note: "hello"}
spec:
  serviceAccountName: apicaller
  containers:
  - name: c
    image: $IMG_BUSYBOX
    command: ["sleep","3600"]
    resources:
      requests: {cpu: 20m, memory: 32Mi}
      limits: {cpu: 200m, memory: 64Mi}
    env:
    - {name: FROM_CM,  valueFrom: {configMapKeyRef: {name: cfg, key: KEY1}}}
    - {name: FROM_SEC, valueFrom: {secretKeyRef: {name: sec, key: PASS}}}
    - {name: MY_POD_NAME, valueFrom: {fieldRef: {fieldPath: metadata.name}}}
    - {name: MY_POD_IP,   valueFrom: {fieldRef: {fieldPath: status.podIP}}}
    - {name: MY_NODE,     valueFrom: {fieldRef: {fieldPath: spec.nodeName}}}
    - {name: MY_ANNOT,    valueFrom: {fieldRef: {fieldPath: "metadata.annotations[${SQ}conformance/note${SQ}]"}}}
    - {name: MEM_REQ,     valueFrom: {resourceFieldRef: {containerName: c, resource: requests.memory}}}
    envFrom:
    - configMapRef: {name: cfg}
    - secretRef: {name: sec}
    volumeMounts:
    - {name: cmvol,  mountPath: /etc/cfg}
    - {name: secvol, mountPath: /etc/sec}
    - {name: cmvol,  mountPath: /etc/sub/only.conf, subPath: file.conf}
    - {name: proj,   mountPath: /etc/proj}
    - {name: ed,     mountPath: /scratch}
    - {name: hp,     mountPath: /hostetc, readOnly: true}
    - {name: pvc,    mountPath: /pvcdata}
    - {name: eph,    mountPath: /ephdata}
  volumes:
  - {name: cmvol,  configMap: {name: cfg}}
  - {name: secvol, secret: {secretName: sec, defaultMode: 0400}}
  - name: proj
    projected:
      sources:
      - configMap: {name: cfg, items: [{key: KEY1, path: cm-key1}]}
      - secret: {name: sec, items: [{key: USER, path: sec-user}]}
      - downwardAPI: {items: [{path: labels, fieldRef: {fieldPath: metadata.labels}}]}
      - serviceAccountToken: {path: sa-token, audience: conformance-aud, expirationSeconds: 3600}
  - {name: ed,  emptyDir: {}}
  - {name: hp,  hostPath: {path: /etc, type: Directory}}
  - {name: pvc, persistentVolumeClaim: {claimName: standalone-pvc}}
  - name: eph
    ephemeral:
      volumeClaimTemplate:
        spec:
          accessModes: [ReadWriteOnce]
          resources: {requests: {storage: 32Mi}}
Y
  wait_ready pod/kitchen 240s'

kk() { kn exec kitchen -- sh -c "$1" 2>&1; }

check "ConfigMap and Secret as individual env vars" \
  'kk "echo \$FROM_CM/\$FROM_SEC" | grep -qx "val1/s3cr3t"'

check "envFrom projects whole ConfigMap and Secret" \
  'kk "echo \$KEY2/\$USER" | grep -qx "val2/admin"'

# Each value is checked on its own: a "|" separator inside `echo` would be parsed as a
# pipe by the pod's shell, not printed.
check "downward API: metadata, status, spec and annotation fieldRefs" \
  'kk "echo \$MY_POD_NAME" | grep -qx kitchen &&
   kk "echo \$MY_NODE"     | grep -qx "$NODE" &&
   kk "echo \$MY_ANNOT"    | grep -qx hello &&
   kk "echo \$MY_POD_IP"   | grep -q "^10\.42\."'

check "downward API: resourceFieldRef exposes requests" \
  'kk "echo \$MEM_REQ" | grep -qx 33554432'

check "ConfigMap as a volume" \
  'kk "cat /etc/cfg/KEY1" | grep -qx val1'

check "Secret as a volume" \
  'kk "cat /etc/sec/USER" | grep -qx admin'

check "subPath mounts a single key as a file" \
  'kk "cat /etc/sub/only.conf" | tr "\n" " " | grep -q "line1 line2"'

check "projected volume combines configMap + secret + downwardAPI + SA token" \
  'kk "cat /etc/proj/cm-key1" | grep -qx val1 &&
   kk "cat /etc/proj/sec-user" | grep -qx admin &&
   kk "cat /etc/proj/labels" | grep -q "app=\"kitchen\"" &&
   [ "$(kk "wc -c < /etc/proj/sa-token" | tr -d " ")" -gt 500 ]'

check "default ServiceAccount token is projected with ca.crt and namespace" \
  'kk "cat /var/run/secrets/kubernetes.io/serviceaccount/namespace" | grep -qx "$NS" &&
   kk "test -s /var/run/secrets/kubernetes.io/serviceaccount/ca.crt && echo ok" | grep -qx ok'

check "emptyDir is writable" \
  'kk "echo ok > /scratch/f && cat /scratch/f" | grep -qx ok'

check "hostPath exposes a node directory" \
  'kk "cat /hostetc/hostname" | grep -q .'

check "PVC is writable and readable from the pod" \
  'kk "echo pvc-ok > /pvcdata/f && cat /pvcdata/f" | grep -qx pvc-ok'

check "inline ephemeral volume is mounted and writable" \
  'kk "echo eph-ok > /ephdata/f && cat /ephdata/f" | grep -qx eph-ok'

check "QoS class is Burstable for requests<limits" \
  '[ "$(kn get pod kitchen -o jsonpath="{.status.qosClass}")" = Burstable ]'

# ---- a pod calling the apiserver with its own identity -------------------------

# NOTE: busybox's minimal TLS stack cannot complete a handshake with the apiserver
# (it gets peer alert 47 against the node IP too), so this must NOT be tested with
# busybox wget -- doing so records a false BROKEN. agnhost is a Go client and is the
# correct instrument here.
check "pod reaches the apiserver via kubernetes.default using its own SA token" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Pod
metadata: {name: apiclient}
spec:
  serviceAccountName: apicaller
  restartPolicy: Never
  containers:
  - name: c
    image: $IMG_AGNHOST
    args: ["inclusterclient", "--poll-interval=2"]
    resources: {requests: {cpu: 20m, memory: 32Mi}}
Y
  wait_ready pod/apiclient 240s || exit 1
  ok=1
  for i in $(seq 1 15); do
    kn logs apiclient 2>/dev/null | grep -q "calling /healthz" && { ok=0; break; }
    sleep 3
  done
  [ $ok = 0 ]'

# The pod spec injects no env of its own, so this value is the kubelet's -- i.e. the
# real Service ClusterIP, not the historical KUBERNETES_SERVICE_HOST=10.0.0.1 override.
check "KUBERNETES_SERVICE_HOST is the real ClusterIP (no 10.0.0.1 workaround needed)" \
  '[ -z "$(kn get pod apiclient -o jsonpath="{.spec.containers[0].env}" 2>/dev/null)" ] &&
   kn exec apiclient -- sh -c "echo \$KUBERNETES_SERVICE_HOST" 2>/dev/null | tr -d "\r" | grep -qx 10.43.0.1'

xcheck "busybox wget can complete a TLS handshake with the apiserver" \
  "busybox's built-in TLS offers no cipher the apiserver accepts (peer alert 47); a client limitation, not a cluster one" \
  'kx "wget -q -T10 -O- https://10.43.0.1:443/version"'

# ---- RBAC --------------------------------------------------------------------

check "RBAC allows what the Role grants" \
  'k auth can-i get configmaps -n "$NS" --as="system:serviceaccount:$NS:apicaller" | grep -qx yes'

check "RBAC denies verbs the Role does not grant" \
  'k auth can-i delete configmaps -n "$NS" --as="system:serviceaccount:$NS:apicaller" | grep -qx no'

check "RBAC denies resources the Role does not grant" \
  'k auth can-i list secrets -n "$NS" --as="system:serviceaccount:$NS:apicaller" | grep -qx no'

check "a real impersonated request is actually Forbidden (not just can-i)" \
  'k get secrets -n "$NS" --as="system:serviceaccount:$NS:apicaller" 2>&1 |
     grep -q "Forbidden.*cannot list resource \"secrets\""'

check "SelfSubjectRulesReview enumerates the granted rules" \
  'k auth can-i --list -n "$NS" --as="system:serviceaccount:$NS:apicaller" 2>/dev/null |
     grep -q "configmaps"'

check "ClusterRole + ClusterRoleBinding grant cluster-scoped access" '
  k create clusterrole "cr-$RUN_ID" --verb=get,list --resource=nodes >/dev/null 2>&1
  k create clusterrolebinding "crb-$RUN_ID" --clusterrole="cr-$RUN_ID" \
     --serviceaccount="$NS:apicaller" >/dev/null 2>&1
  k auth can-i get nodes --as="system:serviceaccount:$NS:apicaller" 2>/dev/null | grep -qx yes'

kn delete pod kitchen apiclient --wait=false >/dev/null 2>&1
