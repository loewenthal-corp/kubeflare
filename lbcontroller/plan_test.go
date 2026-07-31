package main

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const testSuffix = "lb.kubeflare.dev"

// apiserverRule is the rule that carries every kubectl request into the
// cluster. Nothing in this file is allowed to lose it.
func apiserverRule() ingressRule {
	return ingressRule{"hostname": "k8s.kubeflare.dev", "service": "tcp://localhost:6443"}
}

func catchAllRule() ingressRule { return ingressRule{"service": catchAllService} }

func managed(host, origin string) ingressRule {
	return ingressRule{"hostname": host, "service": origin}
}

// summary renders a rule list as "hostname=>service" strings, which is what the
// assertions below actually care about.
func summary(rules []ingressRule) []string {
	out := make([]string, 0, len(rules))
	for _, r := range rules {
		out = append(out, r.hostname()+"=>"+r.service())
	}
	return out
}

func TestRebuildIngressPreservesTheAPIServerRule(t *testing.T) {
	existing := []ingressRule{
		apiserverRule(),
		managed("gone-default."+testSuffix, "http://10.43.0.9:80"), // Service deleted while we were down
		catchAllRule(),
	}
	desired := []ingressRule{managed("web-default."+testSuffix, "http://10.43.0.7:80")}

	got, conflicts := rebuildIngress(existing, desired, nil, testSuffix, nil)
	want := []string{
		"k8s.kubeflare.dev=>tcp://localhost:6443",
		"web-default.lb.kubeflare.dev=>http://10.43.0.7:80",
		"=>http_status:404",
	}
	if !slices.Equal(summary(got), want) {
		t.Errorf("rebuildIngress = %v, want %v", summary(got), want)
	}
	if len(conflicts) != 0 {
		t.Errorf("unexpected conflicts: %v", conflicts)
	}
}

func TestRebuildIngressKeepsTheCatchAllLastAndVerbatim(t *testing.T) {
	custom := ingressRule{"service": "http_status:503"}
	existing := []ingressRule{apiserverRule(), custom}
	desired := []ingressRule{managed("web-default."+testSuffix, "http://10.43.0.7:80")}

	got, _ := rebuildIngress(existing, desired, nil, testSuffix, nil)
	last := got[len(got)-1]
	if !last.isCatchAll() || last.service() != "http_status:503" {
		t.Errorf("last rule = %v, want the pre-existing 503 catch-all", last)
	}
	for _, r := range got[:len(got)-1] {
		if r.isCatchAll() {
			t.Errorf("a catch-all appears before the end of the list: %v", summary(got))
		}
	}
}

func TestRebuildIngressSynthesisesAMissingCatchAll(t *testing.T) {
	// An ingress list whose final entry still matches on hostname is rejected
	// by the API, so one has to be appended even when the old document had none.
	got, _ := rebuildIngress([]ingressRule{apiserverRule()}, nil, nil, testSuffix, nil)
	want := []string{"k8s.kubeflare.dev=>tcp://localhost:6443", "=>http_status:404"}
	if !slices.Equal(summary(got), want) {
		t.Errorf("rebuildIngress = %v, want %v", summary(got), want)
	}
}

func TestRebuildIngressEmptyConfig(t *testing.T) {
	got, _ := rebuildIngress(nil, nil, nil, testSuffix, nil)
	if want := []string{"=>http_status:404"}; !slices.Equal(summary(got), want) {
		t.Errorf("rebuildIngress = %v, want %v", summary(got), want)
	}
}

func TestRebuildIngressIsDeterministicAndIdempotent(t *testing.T) {
	existing := []ingressRule{apiserverRule(), catchAllRule()}
	desired := []ingressRule{
		managed("zoo-default."+testSuffix, "http://10.43.0.3:80"),
		managed("api-prod."+testSuffix, "http://10.43.0.1:80"),
		managed("api-dev."+testSuffix, "http://10.43.0.2:80"),
	}
	first, _ := rebuildIngress(existing, desired, nil, testSuffix, nil)
	want := []string{
		"k8s.kubeflare.dev=>tcp://localhost:6443",
		"api-dev.lb.kubeflare.dev=>http://10.43.0.2:80",
		"api-prod.lb.kubeflare.dev=>http://10.43.0.1:80",
		"zoo-default.lb.kubeflare.dev=>http://10.43.0.3:80",
		"=>http_status:404",
	}
	if !slices.Equal(summary(first), want) {
		t.Fatalf("rebuildIngress = %v, want %v", summary(first), want)
	}
	// Same inputs in a different order must produce the same document, and
	// feeding the result back in must be a no-op — that is what stops the
	// controller from PUTting on every pass.
	shuffled := []ingressRule{desired[1], desired[2], desired[0]}
	again, _ := rebuildIngress(first, shuffled, nil, testSuffix, nil)
	if !rulesEqual(first, again) {
		t.Errorf("not idempotent:\n first = %v\n again = %v", summary(first), summary(again))
	}
}

func TestRebuildIngressRefusesToStealAForeignHostname(t *testing.T) {
	// kubeflare.io/hostname: k8s.kubeflare.dev on some Service. Publishing it
	// would replace the apiserver rule and cut kubectl off from the cluster.
	existing := []ingressRule{apiserverRule(), catchAllRule()}
	desired := []ingressRule{managed("k8s.kubeflare.dev", "http://10.43.0.7:80")}

	got, conflicts := rebuildIngress(existing, desired, nil, testSuffix, nil)
	if !rulesEqual(got, existing) {
		t.Errorf("rebuildIngress = %v, want the document unchanged", summary(got))
	}
	if len(conflicts) != 1 || conflicts[0].hostname != "k8s.kubeflare.dev" {
		t.Fatalf("conflicts = %v, want one for k8s.kubeflare.dev", conflicts)
	}
}

func TestRebuildIngressAdoptsARuleThatIsAlreadyExactlyRight(t *testing.T) {
	// Our own rule from a previous run, at a hostname outside the suffix that
	// this process has no memory of. Reinstating it changes nothing, so it must
	// be adopted rather than reported as somebody else's.
	mine := managed("shop.kubeflare.dev", "http://10.43.0.7:80")
	existing := []ingressRule{apiserverRule(), mine, catchAllRule()}

	got, conflicts := rebuildIngress(existing, []ingressRule{managed("shop.kubeflare.dev", "http://10.43.0.7:80")}, nil, testSuffix, nil)
	if len(conflicts) != 0 {
		t.Errorf("conflicts = %v, want none for an identical rule", conflicts)
	}
	if !rulesEqual(got, existing) {
		t.Errorf("rebuildIngress = %v, want the document unchanged", summary(got))
	}
	// The same hostname pointing somewhere else is a different matter.
	_, conflicts = rebuildIngress(existing, []ingressRule{managed("shop.kubeflare.dev", "http://10.43.0.9:80")}, nil, testSuffix, nil)
	if len(conflicts) != 1 {
		t.Errorf("conflicts = %v, want one for a rule that would change", conflicts)
	}
}

func TestRebuildIngressReapsOwnedHostnamesOutsideTheSuffix(t *testing.T) {
	// A hostname set by annotation need not sit under --hostname-suffix, so the
	// only thing that makes it reapable is the controller remembering it.
	stale := managed("shop.kubeflare.dev", "http://10.43.0.4:80")
	existing := []ingressRule{apiserverRule(), stale, catchAllRule()}

	kept, _ := rebuildIngress(existing, nil, nil, testSuffix, nil)
	if !slices.Contains(summary(kept), "shop.kubeflare.dev=>http://10.43.0.4:80") {
		t.Errorf("an unrecognised rule was dropped: %v", summary(kept))
	}
	reaped, _ := rebuildIngress(existing, nil, map[string]bool{"shop.kubeflare.dev": true}, testSuffix, nil)
	if slices.Contains(summary(reaped), "shop.kubeflare.dev=>http://10.43.0.4:80") {
		t.Errorf("an owned rule survived: %v", summary(reaped))
	}
}

func TestRebuildIngressPreservesFieldsItDoesNotUnderstand(t *testing.T) {
	foreign := ingressRule{
		"hostname":      "legacy.kubeflare.dev",
		"path":          "/api/.*",
		"service":       "https://10.0.0.5:8443",
		"originRequest": map[string]any{"noTLSVerify": true, "connectTimeout": json.Number("30")},
	}
	existing := []ingressRule{foreign, catchAllRule()}
	got, _ := rebuildIngress(existing, []ingressRule{managed("web-default."+testSuffix, "http://10.43.0.7:80")}, nil, testSuffix, nil)

	before, _ := json.Marshal(foreign)
	after, _ := json.Marshal(got[0])
	if string(before) != string(after) {
		t.Errorf("foreign rule was rewritten:\n before = %s\n after  = %s", before, after)
	}
}

func TestRebuildIngressReportsAShadowingRule(t *testing.T) {
	// A rule with no hostname that is not last matches everything, so nothing
	// this controller appends would ever be reached.
	existing := []ingressRule{{"service": "http://10.0.0.9:80"}, apiserverRule(), catchAllRule()}
	got, conflicts := rebuildIngress(existing, []ingressRule{managed("web-default."+testSuffix, "http://10.43.0.7:80")}, nil, testSuffix, nil)
	if len(conflicts) != 1 || conflicts[0].hostname != "" || !strings.Contains(conflicts[0].reason, "shadow") {
		t.Fatalf("conflicts = %v, want one shadowing warning", conflicts)
	}
	if len(got) != 4 {
		t.Errorf("rebuildIngress = %v, want the shadowing rule left in place", summary(got))
	}
}

func svc(namespace, name string, mutate ...func(*corev1.Service)) *corev1.Service {
	s := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: namespace, Name: name},
		Spec: corev1.ServiceSpec{
			Type:      corev1.ServiceTypeLoadBalancer,
			ClusterIP: "10.43.0.7",
			Ports:     []corev1.ServicePort{{Name: "http", Port: 80, Protocol: corev1.ProtocolTCP}},
		},
	}
	for _, m := range mutate {
		m(s)
	}
	return s
}

func annotate(k, v string) func(*corev1.Service) {
	return func(s *corev1.Service) {
		if s.Annotations == nil {
			s.Annotations = map[string]string{}
		}
		s.Annotations[k] = v
	}
}

func TestDeriveHostname(t *testing.T) {
	tests := []struct {
		name    string
		svc     *corev1.Service
		want    string
		wantErr bool
	}{
		{"default", svc("default", "web"), "web-default." + testSuffix, false},
		{"namespaced", svc("kube-system", "metrics"), "metrics-kube-system." + testSuffix, false},
		{"annotation wins", svc("default", "web", annotate(hostnameAnnotation, "shop.kubeflare.dev")), "shop.kubeflare.dev", false},
		{"annotation normalised", svc("default", "web", annotate(hostnameAnnotation, " Shop.Kubeflare.DEV. ")), "shop.kubeflare.dev", false},
		{"annotation not an FQDN", svc("default", "web", annotate(hostnameAnnotation, "shop")), "", true},
		{"annotation wildcard", svc("default", "web", annotate(hostnameAnnotation, "*.kubeflare.dev")), "", true},
		{"annotation underscore", svc("default", "web", annotate(hostnameAnnotation, "sh_op.kubeflare.dev")), "", true},
		{"empty annotation falls back", svc("default", "web", annotate(hostnameAnnotation, "  ")), "web-default." + testSuffix, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := deriveHostname(tc.svc, testSuffix)
			if (err != nil) != tc.wantErr {
				t.Fatalf("deriveHostname error = %v, wantErr %v", err, tc.wantErr)
			}
			if !tc.wantErr && got != tc.want {
				t.Errorf("deriveHostname = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestSanitizeLabel(t *testing.T) {
	tests := []struct{ in, want string }{
		{"web-default", "web-default"},
		{"Web-Default", "web-default"},
		{"my.app-prod", "my-app-prod"},
		{"-leading-and-trailing-", "leading-and-trailing"},
		{"ünïcode-ns", "n-code-ns"}, // each non-ASCII rune becomes one hyphen, then trimmed
		{"...", ""},
	}
	for _, tc := range tests {
		if got := sanitizeLabel(tc.in); got != tc.want {
			t.Errorf("sanitizeLabel(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSanitizeLabelTruncatesWithoutColliding(t *testing.T) {
	long := strings.Repeat("a", 60)
	a := sanitizeLabel(long + "-one")
	b := sanitizeLabel(long + "-two")
	for _, got := range []string{a, b} {
		if len(got) > maxDNSLabel {
			t.Fatalf("sanitizeLabel produced %d characters: %q", len(got), got)
		}
		if !validDNSName(got + "." + testSuffix) {
			t.Fatalf("sanitizeLabel produced an invalid label: %q", got)
		}
	}
	if a == b {
		t.Errorf("two long names truncated to the same label %q", a)
	}
}

func TestOriginFor(t *testing.T) {
	twoPorts := func(s *corev1.Service) {
		s.Spec.Ports = []corev1.ServicePort{
			{Name: "metrics", Port: 9090, Protocol: corev1.ProtocolTCP},
			{Name: "http", Port: 80, Protocol: corev1.ProtocolTCP},
		}
	}
	tests := []struct {
		name    string
		svc     *corev1.Service
		want    string
		wantErr bool
	}{
		{"first port wins", svc("default", "web", twoPorts), "http://10.43.0.7:9090", false},
		{"annotation by name", svc("default", "web", twoPorts, annotate(portAnnotation, "http")), "http://10.43.0.7:80", false},
		{"annotation by number", svc("default", "web", twoPorts, annotate(portAnnotation, "80")), "http://10.43.0.7:80", false},
		{"annotation matches nothing", svc("default", "web", annotate(portAnnotation, "grpc")), "", true},
		{"headless", svc("default", "web", func(s *corev1.Service) { s.Spec.ClusterIP = corev1.ClusterIPNone }), "", true},
		{"no ClusterIP yet", svc("default", "web", func(s *corev1.Service) { s.Spec.ClusterIP = "" }), "", true},
		{"no ports", svc("default", "web", func(s *corev1.Service) { s.Spec.Ports = nil }), "", true},
		{"udp", svc("default", "dns", func(s *corev1.Service) { s.Spec.Ports[0].Protocol = corev1.ProtocolUDP }), "", true},
		{"ipv6 ClusterIP", svc("default", "web", func(s *corev1.Service) { s.Spec.ClusterIP = "fd00::1" }), "", true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := originFor(tc.svc)
			if (err != nil) != tc.wantErr {
				t.Fatalf("originFor error = %v, wantErr %v", err, tc.wantErr)
			}
			if !tc.wantErr && got != tc.want {
				t.Errorf("originFor = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestDecideDNS(t *testing.T) {
	const host = "web-default.lb.kubeflare.dev"
	const target = "6b0094c3-200b-4f19-b5e1-bc438f31c811.cfargotunnel.com"
	want := dnsRecord{Type: "CNAME", Name: host, Content: target, Proxied: ptr(true), TTL: 1}

	tests := []struct {
		name     string
		existing []dnsRecord
		wantVerb dnsVerb
		wantID   string
		wantErr  bool
	}{
		{"nothing there", nil, dnsCreate, "", false},
		{
			"another name only",
			[]dnsRecord{{ID: "a", Type: "CNAME", Name: "other.lb.kubeflare.dev", Content: target, Proxied: ptr(true)}},
			dnsCreate, "", false,
		},
		{
			"already correct",
			[]dnsRecord{{ID: "a", Type: "CNAME", Name: host, Content: target, Proxied: ptr(true), TTL: 1}},
			dnsNoop, "a", false,
		},
		{
			"ttl differs but the record is proxied, so Cloudflare owns the ttl",
			[]dnsRecord{{ID: "a", Type: "CNAME", Name: host, Content: target, Proxied: ptr(true), TTL: 300}},
			dnsNoop, "a", false,
		},
		{
			"points at another tunnel",
			[]dnsRecord{{ID: "a", Type: "CNAME", Name: host, Content: "old.cfargotunnel.com", Proxied: ptr(true)}},
			dnsUpdate, "a", false,
		},
		{
			"grey-clouded",
			[]dnsRecord{{ID: "a", Type: "CNAME", Name: host, Content: target, Proxied: ptr(false)}},
			dnsUpdate, "a", false,
		},
		{
			"proxied missing entirely",
			[]dnsRecord{{ID: "a", Type: "CNAME", Name: host, Content: target}},
			dnsUpdate, "a", false,
		},
		{
			"an A record is in the way",
			[]dnsRecord{{ID: "a", Type: "A", Name: host, Content: "203.0.113.7"}},
			dnsNoop, "", true,
		},
		{
			"two CNAMEs at the same name",
			[]dnsRecord{
				{ID: "a", Type: "CNAME", Name: host, Content: target},
				{ID: "b", Type: "CNAME", Name: host, Content: target},
			},
			dnsNoop, "", true,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			verb, id, err := decideDNS(tc.existing, want)
			if (err != nil) != tc.wantErr {
				t.Fatalf("decideDNS error = %v, wantErr %v", err, tc.wantErr)
			}
			if tc.wantErr {
				return
			}
			if verb != tc.wantVerb || id != tc.wantID {
				t.Errorf("decideDNS = (%v, %q), want (%v, %q)", verb, id, tc.wantVerb, tc.wantID)
			}
		})
	}
}

// Regression: with --hostname-suffix set to the zone apex, every hostname in
// the zone matches the suffix — including the apiserver's tunnel rule. Before
// protected hostnames existed this silently deleted it on the first pass
// (observed live: rules=2 managed=1 preserved=0). The apex suffix is not a
// misconfiguration to reject: Universal SSL only covers one label deep, so it
// is the only suffix that gets working TLS without Advanced Certificate Manager.
func TestApexSuffixStillPreservesAProtectedHostname(t *testing.T) {
	const apex = "kubeflare.dev"
	protected := map[string]bool{"k8s.kubeflare.dev": true}
	existing := []ingressRule{apiserverRule()}
	desired := []ingressRule{managed("shop-default.kubeflare.dev", "http://10.43.0.7:80")}

	got, conflicts := rebuildIngress(existing, desired, nil, apex, protected)
	if len(conflicts) != 0 {
		t.Fatalf("unexpected conflicts: %v", conflicts)
	}
	var sawAPI, sawShop bool
	for _, r := range got {
		switch r.hostname() {
		case "k8s.kubeflare.dev":
			sawAPI = true
			if svc := r.service(); svc != "tcp://localhost:6443" {
				t.Errorf("apiserver rule was rewritten: service=%q", svc)
			}
		case "shop-default.kubeflare.dev":
			sawShop = true
		}
	}
	if !sawAPI {
		t.Error("apiserver rule was dropped under an apex suffix — the live regression")
	}
	if !sawShop {
		t.Error("managed rule missing")
	}
	if last := got[len(got)-1]; last.hostname() != "" {
		t.Errorf("catch-all is not last: %v", last)
	}
}
