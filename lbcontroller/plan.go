package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
)

const (
	// hostnameAnnotation overrides the derived hostname with a fully-qualified
	// name. It is taken literally (only lowercased and stripped of a trailing
	// dot) rather than sanitised: silently rewriting somebody's explicit FQDN
	// into a different one would publish a Service at an address nobody asked
	// for. An unusable value is refused with a log line instead.
	hostnameAnnotation = "kubeflare.io/hostname"
	// portAnnotation picks a spec.ports entry by name or by number. Without it
	// the first port wins, which is what a single-port Service means anyway.
	portAnnotation = "kubeflare.io/port"
	// finalizerName gates deletion so the tunnel rule and the DNS record can be
	// withdrawn before the Service object disappears.
	finalizerName = "kubeflare.io/lb-controller"
	// catchAllService is the fallback rule appended when the tunnel config has
	// none of its own. Cloudflare rejects an ingress list whose last entry
	// still matches on hostname or path, so there is always a final rule.
	catchAllService = "http_status:404"

	maxDNSLabel = 63
	maxDNSName  = 253
)

// lbTarget is one LoadBalancer Service reduced to the two things the rest of
// the controller needs: the public hostname it should answer on and the origin
// cloudflared should forward to. Services being cleaned up carry an empty
// origin.
type lbTarget struct {
	namespace, name string
	hostname        string
	origin          string // http://<clusterIP>:<port>
}

// key is the namespace/name form used for logs and for the controller's
// per-Service bookkeeping maps.
func (t lbTarget) key() string { return t.namespace + "/" + t.name }

// ingressRule is one entry of the tunnel's ingress list. It is kept as the
// decoded JSON object rather than a struct on purpose: a PUT replaces the whole
// configuration document, so every field of every rule this controller does not
// understand (originRequest, access, path, ...) has to survive a rebuild
// verbatim. A struct would quietly drop them.
type ingressRule map[string]any

func (r ingressRule) hostname() string { s, _ := r["hostname"].(string); return s }
func (r ingressRule) path() string     { s, _ := r["path"].(string); return s }
func (r ingressRule) service() string  { s, _ := r["service"].(string); return s }

// isCatchAll reports whether a rule matches every request. cloudflared requires
// exactly one of these and requires it last.
func (r ingressRule) isCatchAll() bool { return r.hostname() == "" && r.path() == "" }

// conflict is a desired rule that could not be published, or a pre-existing
// rule that will stop the managed rules from ever matching.
type conflict struct {
	hostname string // empty for a shadowing catch-all in the middle of the list
	reason   string
}

// isManagedHostname reports whether a hostname belongs to this controller.
//
// Two things make a hostname ours. Anything under --hostname-suffix is ours by
// construction: that subdomain is the controller's namespace and hand-written
// rules do not belong in it. Anything in owned is ours because this process
// published it — that set carries hostnames of Services that are being deleted,
// of Services whose hostname annotation just changed, and of hostnames left
// behind by a forced finalizer release, none of which can be recognised from
// the suffix when the annotation put them somewhere else in the zone.
// protected hostnames are never managed, whatever the suffix says. This exists
// because --hostname-suffix is legitimately set to the zone apex (Cloudflare's
// Universal SSL covers example.com and *.example.com but NOT *.lb.example.com,
// so a nested suffix means no working TLS without Advanced Certificate
// Manager). At the apex, "under the suffix" matches every hostname in the zone
// — including the apiserver's own tunnel rule, which this controller then
// cheerfully deleted. Measured, on a live tunnel: rules=2 managed=1
// preserved=0, and the k8s.* rule was gone.
func isManagedHostname(h, suffix string, owned map[string]bool, protected map[string]bool) bool {
	if h == "" {
		return false
	}
	// Protection beats everything, including owned: if a hostname is declared
	// off-limits, no amount of controller state should let it be rewritten.
	if protected[h] {
		return false
	}
	if owned[h] {
		return true
	}
	return h == suffix || strings.HasSuffix(h, "."+suffix)
}

// rebuildIngress produces the complete ingress list to PUT.
//
// The list is a single document shared with whatever else uses this tunnel — on
// kubeflare that is the apiserver rule, `k8s.kubeflare.dev -> tcp://localhost:6443`,
// which is how kubectl reaches the cluster at all. PUT replaces the document
// wholesale, so the list is rebuilt from scratch every time in three parts:
//
//  1. every pre-existing rule this controller does not manage, in its original
//     order and with its original fields, first — so a Service can never take
//     precedence over the apiserver rule (first match wins in cloudflared);
//  2. the managed rules, sorted by hostname so the same cluster state always
//     produces the same document and no-op passes stay no-ops;
//  3. the catch-all, last, preserved verbatim from the old document if it had
//     one so a hand-configured fallback is not downgraded to a 404.
//
// A desired hostname that collides with a preserved rule is dropped and
// reported: refusing to publish one Service is much better than evicting the
// rule that carries kubectl traffic.
func rebuildIngress(existing, desired []ingressRule, owned map[string]bool, suffix string, protected map[string]bool) ([]ingressRule, []conflict) {
	var conflicts []conflict

	body := existing
	var catchAll ingressRule
	if n := len(existing); n > 0 && existing[n-1].isCatchAll() {
		body, catchAll = existing[:n-1], existing[n-1]
	}
	if catchAll == nil {
		catchAll = ingressRule{"service": catchAllService}
	}

	desiredByHost := make(map[string]ingressRule, len(desired))
	for _, r := range desired {
		desiredByHost[r.hostname()] = r
	}

	preserved := make([]ingressRule, 0, len(body))
	foreign := make(map[string]bool, len(body))
	for _, r := range body {
		h := r.hostname()
		// Ours: it is rebuilt from the desired set below, or it belonged to a
		// Service that has gone away and this is where it gets reaped.
		if isManagedHostname(h, suffix, owned, protected) {
			continue
		}
		// Not recognisably ours, but identical to what would be written for it
		// anyway — our own rule from a previous run whose Service status never
		// got written, most likely. Adopting a rule that is already exactly
		// right cannot lose anything, so there is nothing here to protect.
		if d, wanted := desiredByHost[h]; wanted && rulesEqual([]ingressRule{r}, []ingressRule{d}) {
			continue
		}
		preserved = append(preserved, r)
		if h == "" {
			// A hostname-less rule that is not last matches everything and
			// swallows every rule after it, including all of ours. It is not
			// this controller's config to delete, so say so loudly instead.
			conflicts = append(conflicts, conflict{reason: "a pre-existing rule with no hostname precedes the managed rules and will shadow all of them"})
			continue
		}
		foreign[h] = true
	}

	managed := slices.Clone(desired)
	slices.SortFunc(managed, func(a, b ingressRule) int {
		if n := strings.Compare(a.hostname(), b.hostname()); n != 0 {
			return n
		}
		return strings.Compare(a.path(), b.path())
	})

	out := make([]ingressRule, 0, len(preserved)+len(managed)+1)
	out = append(out, preserved...)
	for _, r := range managed {
		if foreign[r.hostname()] {
			conflicts = append(conflicts, conflict{
				hostname: r.hostname(),
				reason:   "already served by a tunnel rule this controller does not manage; refusing to replace it",
			})
			continue
		}
		out = append(out, r)
	}
	return append(out, catchAll), conflicts
}

// rulesEqual compares two ingress lists as canonical JSON, which is exactly the
// comparison that matters: equal here means a PUT would be a no-op, so the pass
// can skip the write entirely. encoding/json sorts object keys, and numbers
// decoded with UseNumber re-marshal to their original literal, so the encoding
// is stable across round-trips.
func rulesEqual(a, b []ingressRule) bool {
	ja, errA := json.Marshal(a)
	jb, errB := json.Marshal(b)
	return errA == nil && errB == nil && bytes.Equal(ja, jb)
}

// deriveHostname computes the public hostname for a Service: the annotation if
// it carries a usable FQDN, otherwise "<service>-<namespace>.<suffix>".
func deriveHostname(svc *corev1.Service, suffix string) (string, error) {
	if raw := strings.TrimSpace(svc.Annotations[hostnameAnnotation]); raw != "" {
		h := strings.ToLower(strings.TrimSuffix(raw, "."))
		if !validDNSName(h) {
			return "", fmt.Errorf("annotation %s=%q is not a usable fully-qualified DNS name", hostnameAnnotation, raw)
		}
		return h, nil
	}
	label := sanitizeLabel(svc.Name + "-" + svc.Namespace)
	if label == "" {
		return "", fmt.Errorf("no DNS label can be derived from %s/%s; set %s", svc.Namespace, svc.Name, hostnameAnnotation)
	}
	return label + "." + suffix, nil
}

// sanitizeLabel folds "<name>-<namespace>" into one legal DNS label: lowercase,
// [a-z0-9-] only, no leading or trailing hyphen, at most 63 characters.
//
// Kubernetes names are far more permissive than a DNS label (up to 253
// characters, dots allowed), so two different Services can sanitise to the same
// label — "a-b" in namespace "c" and "a" in namespace "b-c" both give "a-b-c".
// Truncation would create many more of those. Over-long names therefore keep 54
// characters of the readable form plus a hash of the full input, which makes
// truncation collisions vanishingly unlikely; the remaining structural
// collisions are resolved by the controller (oldest Service keeps the name).
func sanitizeLabel(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else {
			b.WriteByte('-')
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" || len(out) <= maxDNSLabel {
		return out
	}
	sum := sha256.Sum256([]byte(s))
	return strings.Trim(out[:maxDNSLabel-9], "-") + "-" + hex.EncodeToString(sum[:])[:8]
}

// validDNSName checks a hostname the way Cloudflare will. Wildcards are
// rejected: cloudflared accepts them in ingress rules, but a Service claiming
// "*.example.com" would swallow traffic meant for every other rule below it.
func validDNSName(name string) bool {
	if name == "" || len(name) > maxDNSName {
		return false
	}
	labels := strings.Split(name, ".")
	if len(labels) < 2 {
		return false
	}
	for _, l := range labels {
		if l == "" || len(l) > maxDNSLabel || l[0] == '-' || l[len(l)-1] == '-' {
			return false
		}
		for i := 0; i < len(l); i++ {
			c := l[i]
			if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}

// originFor builds the URL cloudflared should forward matching requests to.
//
// It is the ClusterIP, not a NodePort and not a pod IP. cloudflared runs as a
// host process in the same network namespace as svcproxy, and svcproxy binds a
// listener on every ClusterIP:port there (the AnyIP local route on lo makes
// those addresses bindable). So "http://10.43.x.y:80" is a local connection
// that svcproxy answers and load-balances across ready endpoints — no NodePort
// hop, no dependency on the pod network, and the endpoint set stays live
// without this controller having to watch EndpointSlices at all.
func originFor(svc *corev1.Service) (string, error) {
	ip := svc.Spec.ClusterIP
	if ip == "" || ip == corev1.ClusterIPNone {
		return "", fmt.Errorf("no ClusterIP (headless or ExternalName Services cannot be published)")
	}
	addr, err := netip.ParseAddr(ip)
	if err != nil || !addr.Is4() {
		// svcproxy binds IPv4 ClusterIPs only, so an IPv6 origin would be a
		// rule pointing at an address nothing is listening on.
		return "", fmt.Errorf("ClusterIP %q is not IPv4", ip)
	}
	port, err := servicePort(svc)
	if err != nil {
		return "", err
	}
	return "http://" + net.JoinHostPort(ip, strconv.Itoa(int(port.Port))), nil
}

// servicePort picks the port to publish: the one named by the annotation, else
// the first. Only TCP can be carried by an HTTP ingress rule.
func servicePort(svc *corev1.Service) (corev1.ServicePort, error) {
	if len(svc.Spec.Ports) == 0 {
		return corev1.ServicePort{}, fmt.Errorf("Service has no ports")
	}
	port := svc.Spec.Ports[0]
	if want := strings.TrimSpace(svc.Annotations[portAnnotation]); want != "" {
		i := slices.IndexFunc(svc.Spec.Ports, func(p corev1.ServicePort) bool {
			return p.Name == want || strconv.Itoa(int(p.Port)) == want
		})
		if i < 0 {
			return corev1.ServicePort{}, fmt.Errorf("annotation %s=%q matches no port on this Service", portAnnotation, want)
		}
		port = svc.Spec.Ports[i]
	}
	if port.Protocol != "" && port.Protocol != corev1.ProtocolTCP {
		return corev1.ServicePort{}, fmt.Errorf("port %d is %s; only TCP can be published over an HTTP tunnel rule", port.Port, port.Protocol)
	}
	return port, nil
}

// dnsVerb is what ensureDNS has to do to make reality match the desired record.
type dnsVerb int

const (
	dnsNoop dnsVerb = iota
	dnsCreate
	dnsUpdate
)

func (v dnsVerb) String() string {
	switch v {
	case dnsCreate:
		return "create"
	case dnsUpdate:
		return "update"
	default:
		return "no-op"
	}
}

// decideDNS diffs the records already at a name against the one wanted.
//
// Only the fields this controller sets are compared. TTL is not: Cloudflare
// forces ttl=1 ("automatic") on proxied records, so diffing it would make every
// pass want an update. The comment is not either — it is set once at create
// time for whoever finds the record later, and rewriting it on every drift
// check would be churn for nothing.
//
// Anything unexpected at the name — a record of another type, or several
// records — is an error rather than a guess. Those are somebody else's records
// far more often than they are a mess this controller made.
func decideDNS(existing []dnsRecord, want dnsRecord) (verb dnsVerb, id string, err error) {
	var found *dnsRecord
	for i := range existing {
		r := &existing[i]
		// The list endpoint is asked to filter by name, but filter again:
		// depending on API version "name" can be a prefix/contains match.
		if !strings.EqualFold(strings.TrimSuffix(r.Name, "."), want.Name) {
			continue
		}
		if !strings.EqualFold(r.Type, "CNAME") {
			return dnsNoop, "", fmt.Errorf("a %s record already exists at %s; refusing to replace it", r.Type, want.Name)
		}
		if found != nil {
			return dnsNoop, "", fmt.Errorf("more than one CNAME already exists at %s; refusing to guess which is ours", want.Name)
		}
		found = r
	}
	if found == nil {
		return dnsCreate, "", nil
	}
	if strings.EqualFold(strings.TrimSuffix(found.Content, "."), want.Content) && found.proxied() == want.proxied() {
		return dnsNoop, found.ID, nil
	}
	return dnsUpdate, found.ID, nil
}

func ptr[T any](v T) *T { return &v }
