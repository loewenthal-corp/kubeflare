# shellcheck shell=bash
# Services and DNS. This is where the platform diverges most from stock Kubernetes:
# kube-proxy is disabled entirely and ClusterIPs are served by svcproxy/, a userspace
# proxy listening on an AnyIP-routed service CIDR.

group "services and networking"

CIP="$(kn get svc echo -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
EPIP="$(kn get pod -l app=echo -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)"
CLIENTIP="$(kn get pod client -o jsonpath='{.status.podIP}' 2>/dev/null)"

check "pod to pod directly by pod IP" \
  'kx "wget -q -T8 -O- http://$EPIP:8080/hostname" | grep -q "^echo-"'

check "pod to ClusterIP by IP" \
  'kx "wget -q -T8 -O- http://$CIP:80/hostname" | grep -q "^echo-"'

check "pod to Service by short DNS name" \
  'kx "wget -q -T8 -O- http://echo/hostname" | grep -q "^echo-"'

check "pod to Service by FQDN" \
  'kx "wget -q -T8 -O- http://echo.$NS.svc.cluster.local/hostname" | grep -q "^echo-"'

check "svcproxy round-robins across ready endpoints" \
  '[ "$(kx "for i in 1 2 3 4 5 6; do wget -q -T8 -O- http://echo/hostname; echo; done" |
        sort -u | grep -c "^echo-")" -eq 2 ]'

check "named targetPort resolves (port 80 -> targetPort http)" \
  'kn get svc echo -o jsonpath="{.spec.ports[0].targetPort}" | grep -qx http'

check "UDP Services work through svcproxy" \
  'kx "echo -n hostname | timeout 8 nc -u -w4 echo 90" | grep -q "^echo-"'

check "multi-port Service serves every port (non-colliding ports)" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Service
metadata: {name: mp}
spec:
  selector: {app: echo}
  ports:
  - {name: p1, port: 9090, targetPort: 8080}
  - {name: p2, port: 9091, targetPort: 8080}
Y
  sleep 5
  kx "wget -q -T8 -O- http://mp:9090/hostname" | grep -q "^echo-" &&
  kx "wget -q -T8 -O- http://mp:9091/hostname" | grep -q "^echo-"'

check "headless Service returns every pod IP" \
  '[ "$(kx "nslookup sts.$NS.svc.cluster.local" | grep -c "Address: 10.42")" -ge 1 ]'

check "ExternalName Service resolves to a CNAME" '
  kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Service
metadata: {name: ext}
spec: {type: ExternalName, externalName: example.com}
Y
  sleep 5
  kx "nslookup ext.$NS.svc.cluster.local" | grep -q "canonical name = example.com"'

check "EndpointSlices are populated for a Service" \
  'kn get endpointslices -o jsonpath="{.items[*].endpoints[*].addresses[*]}" | grep -q 10.42.'

# ---- DNS record types --------------------------------------------------------

check "DNS: kube-dns ClusterIP 10.43.0.10 answers queries" \
  'kx "nslookup echo.$NS.svc.cluster.local 10.43.0.10" | grep -q "Address: $CIP"'

check "DNS: pods are given the node IP as nameserver" \
  'kx "cat /etc/resolv.conf" | grep -qx "nameserver 10.0.0.1"'

check "DNS: SRV record for a named Service port" \
  'kx "nslookup -type=srv _http._tcp.echo.$NS.svc.cluster.local" | grep -q "service = "'

check "DNS: PTR (reverse) for a ClusterIP" \
  'r=$(printf "%s" "$CIP" | awk -F. "{print \$4\".\"\$3\".\"\$2\".\"\$1}");
   kx "nslookup -type=ptr $r.in-addr.arpa" | grep -q "name = echo.$NS.svc.cluster.local"'

check "DNS: PTR (reverse) for a pod IP" \
  'r=$(printf "%s" "$EPIP" | awk -F. "{print \$4\".\"\$3\".\"\$2\".\"\$1}");
   kx "nslookup -type=ptr $r.in-addr.arpa" | grep -q "name = "'

check "DNS: external names resolve" \
  'kx "nslookup example.com" | grep -q "Address:"'

check "egress: pod reaches the internet over HTTP" \
  'kx "wget -q -T15 -O- http://example.com/" | grep -qi "example domain"'

check "egress: pod reaches the internet over HTTPS" \
  'kx "wget -q -T15 -O- https://example.com/" | grep -qi "example domain"'

# ---- known Service limitations ------------------------------------------------

# svcproxy only serves the ClusterIP. No NodePort listener is ever opened, and
# nothing outside the Worker can reach the container anyway.
check "NodePort object is accepted and allocated a port" '
  kn expose deployment echo --name=np --port=80 --target-port=8080 --type=NodePort >/dev/null 2>&1
  [ -n "$(kn get svc np -o jsonpath="{.spec.ports[0].nodePort}")" ]'

xcheck "NodePort actually listens on the node" \
  "svcproxy serves the ClusterIP only; no NodePort listener is opened and no inbound TCP reaches the container except through the Worker" \
  'np=$(kn get svc np -o jsonpath="{.spec.ports[0].nodePort}");
   kx "timeout 5 nc -z -w4 10.0.0.1 $np"'

check "type: LoadBalancer object is accepted" '
  kn expose deployment echo --name=lb --port=80 --target-port=8080 --type=LoadBalancer >/dev/null 2>&1
  [ "$(kn get svc lb -o jsonpath="{.spec.type}")" = LoadBalancer ]'

xcheck "type: LoadBalancer is provisioned an external address" \
  "k3s runs with --disable servicelb and there is no cloud LB controller; status.loadBalancer stays empty" \
  '[ -n "$(kn get svc lb -o jsonpath="{.status.loadBalancer.ingress}")" ]'

# svcproxy re-originates every connection from the node, so the backend sees the
# cni0 bridge address (10.42.0.1) rather than the client pod IP.
check "source IP is NOT preserved through a ClusterIP (backend sees the bridge)" \
  'via=$(kx "wget -q -T8 -O- http://echo/clientip" | cut -d: -f1);
   [ "$via" = "10.42.0.1" ] && [ "$via" != "$CLIENTIP" ]'

check "source IP IS preserved on direct pod-to-pod traffic" \
  'kx "wget -q -T8 -O- http://$EPIP:8080/clientip" | grep -q "^$CLIENTIP:"'

xcheck "sessionAffinity: ClientIP pins a client to one backend" \
  "svcproxy ignores sessionAffinity and always round-robins" \
  'kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Service
metadata: {name: aff}
spec:
  selector: {app: echo}
  sessionAffinity: ClientIP
  ports: [{name: http, port: 80, targetPort: 8080}]
Y
   sleep 5
   [ "$(kx "for i in 1 2 3 4 5 6 7 8; do wget -q -T8 -O- http://aff/hostname; echo; done" |
        sort -u | grep -c "^echo-")" -eq 1 ]'

# The AnyIP local route makes the WHOLE service CIDR local to the node, so a
# ClusterIP:port that svcproxy has not bound falls through to whatever host
# process is listening on that port. 8080 is the container's status dashboard.
xcheck "an unbound ClusterIP:port is isolated from node-local listeners" \
  "AnyIP routes the entire 10.43.0.0/16 to the node, so any unbound ClusterIP:port reaches a host process on that port (8080 = status dashboard)" \
  '! kx "wget -q -T8 -S -O /dev/null http://10.43.99.99:8080/ 2>&1" | grep -qi "BaseHTTP\|Python"'

xcheck "a Service port that collides with a host listener reaches its endpoints" \
  "same AnyIP fall-through: a Service on port 10250 hits the kubelet, not the Service backends" \
  'kn apply -f - >/dev/null <<Y
apiVersion: v1
kind: Service
metadata: {name: collide}
spec:
  selector: {app: echo}
  ports: [{name: p, port: 10250, targetPort: 8080}]
Y
   sleep 5
   kx "wget -q -T8 -O- http://collide:10250/hostname" | grep -q "^echo-"'

# ---- NetworkPolicy -----------------------------------------------------------

check "NetworkPolicy objects are accepted by the API" '
  kn apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-echo}
spec:
  podSelector: {matchLabels: {app: echo}}
  policyTypes: [Ingress]
  ingress: []
Y'

# k3s ships the kube-router netpol controller, and it does write chains -- but its
# iptables-restore aborts because this kernel has no NFLOG target, so the ruleset is
# never completed and no policy decision is ever reached. Same transactional-restore
# failure mode that disables kube-proxy. Enforcement is a silent no-op.
NETPOL_WHY="kube-router netpol sync aborts: 'Extension NFLOG revision 0 not supported' -> iptables-restore is transactional, so the whole ruleset is dropped"

xcheck "NetworkPolicy default-deny blocks ClusterIP traffic" "$NETPOL_WHY" \
  'sleep 12; ! kx "wget -q -T8 -O- http://echo/hostname" | grep -q "^echo-"'

xcheck "NetworkPolicy default-deny blocks direct pod-IP traffic" "$NETPOL_WHY" \
  '! kx "wget -q -T8 -O- http://$EPIP:8080/hostname" | grep -q "^echo-"'

xcheck "NetworkPolicy deny-all-egress blocks egress to the internet" "$NETPOL_WHY" \
  'kn apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-egress}
spec:
  podSelector: {matchLabels: {app: client}}
  policyTypes: [Egress]
  egress: []
Y
   sleep 12
   ! kx "wget -q -T10 -O- http://example.com/" | grep -qi "example domain"'

kn delete networkpolicy deny-echo deny-egress --ignore-not-found >/dev/null 2>&1

# ---- Ingress -----------------------------------------------------------------

check "Ingress object is accepted by the API" '
  kn apply -f - >/dev/null <<Y
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: ing}
spec:
  rules:
  - host: conformance.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: echo, port: {number: 80}}}
Y'

xcheck "an Ingress controller exists to serve the object" \
  "k3s runs with --disable traefik and no controller is vendored back in; 0 IngressClasses, 0 controller pods" \
  '[ "$(k get ingressclass -o name 2>/dev/null | wc -l | tr -d " ")" -gt 0 ]'

xcheck "Ingress is assigned an address" \
  "no Ingress controller, so status.loadBalancer is never populated" \
  '[ -n "$(kn get ingress ing -o jsonpath="{.status.loadBalancer.ingress}")" ]'

skip "Ingress data path (HTTP routing by host/path)" \
  "no controller to serve it, and no inbound TCP except through the Worker"

# ---- structural single-node limits -------------------------------------------

skip "multi-node pod overlay"            "single node: flannel vxlan is unavailable and there is no inbound UDP"
skip "cross-node Service load balancing" "single node"
skip "SCTP Services"                     "svcproxy skips SCTP; kernel support untested"
skip "IPv6 / dual-stack Services"        "svcproxy is IPv4 only; cluster is single-stack IPv4"
