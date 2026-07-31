package main

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	k8sfake "k8s.io/client-go/kubernetes/fake"
	corelisters "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"
)

const (
	testTunnelID = "6b0094c3-200b-4f19-b5e1-bc438f31c811"
	testTarget   = testTunnelID + ".cfargotunnel.com"
)

// fakeCF is an in-memory stand-in for the Cloudflare API. Everything it stores
// goes through JSON so the controller sees the same value shapes it would get
// from a real response (json.Number and friends) and cannot mutate the fake's
// state by holding on to a map.
type fakeCF struct {
	cfg     map[string]any
	records map[string][]dnsRecord
	seq     int

	configGets, configPuts        int
	lists, creates, updates, dels int

	getErr, putErr, listErr, writeErr error
}

func newFakeCF(rules ...ingressRule) *fakeCF {
	list := make([]any, 0, len(rules))
	for _, r := range rules {
		list = append(list, map[string]any(r))
	}
	return &fakeCF{
		cfg:     map[string]any{"ingress": list, "warp-routing": map[string]any{"enabled": true}},
		records: map[string][]dnsRecord{},
	}
}

func (f *fakeCF) tunnelConfig(context.Context) (*tunnelConfig, error) {
	f.configGets++
	if f.getErr != nil {
		return nil, f.getErr
	}
	raw, err := json.Marshal(f.cfg)
	if err != nil {
		return nil, err
	}
	return parseTunnelConfig(raw)
}

func (f *fakeCF) putTunnelConfig(_ context.Context, cfg *tunnelConfig) error {
	f.configPuts++
	if f.putErr != nil {
		return f.putErr
	}
	raw, err := json.Marshal(cfg.fields)
	if err != nil {
		return err
	}
	f.cfg = nil
	return json.Unmarshal(raw, &f.cfg)
}

func (f *fakeCF) dnsRecords(_ context.Context, name string) ([]dnsRecord, error) {
	f.lists++
	if f.listErr != nil {
		return nil, f.listErr
	}
	return slices.Clone(f.records[name]), nil
}

func (f *fakeCF) createDNS(_ context.Context, rec dnsRecord) error {
	f.creates++
	if f.writeErr != nil {
		return f.writeErr
	}
	f.seq++
	rec.ID = "rec" + string(rune('0'+f.seq))
	f.records[rec.Name] = append(f.records[rec.Name], rec)
	return nil
}

func (f *fakeCF) updateDNS(_ context.Context, id string, rec dnsRecord) error {
	f.updates++
	if f.writeErr != nil {
		return f.writeErr
	}
	for name, recs := range f.records {
		for i := range recs {
			if recs[i].ID == id {
				rec.ID = id
				f.records[name][i] = rec
				return nil
			}
		}
	}
	return errors.New("no such record")
}

func (f *fakeCF) deleteDNS(_ context.Context, id string) error {
	f.dels++
	if f.writeErr != nil {
		return f.writeErr
	}
	for name, recs := range f.records {
		f.records[name] = slices.DeleteFunc(recs, func(r dnsRecord) bool { return r.ID == id })
		if len(f.records[name]) == 0 {
			delete(f.records, name)
		}
	}
	return nil
}

// ingress reads back the rule list the controller last wrote.
func (f *fakeCF) ingress() []ingressRule {
	raw, _ := json.Marshal(f.cfg)
	cfg, _ := parseTunnelConfig(raw)
	return cfg.ingress()
}

type env struct {
	t      *testing.T
	c      *controller
	client *k8sfake.Clientset
	idx    cache.Indexer
	cf     *fakeCF
}

func newEnv(t *testing.T, cf *fakeCF, svcs ...*corev1.Service) *env {
	t.Helper()
	objs := make([]runtime.Object, 0, len(svcs))
	for _, s := range svcs {
		objs = append(objs, s)
	}
	idx := cache.NewIndexer(cache.MetaNamespaceKeyFunc,
		cache.Indexers{cache.NamespaceIndex: cache.MetaNamespaceIndexFunc})
	client := k8sfake.NewClientset(objs...)
	e := &env{
		t:      t,
		client: client,
		idx:    idx,
		cf:     cf,
		c: &controller{
			svcs:          corelisters.NewServiceLister(idx),
			client:        client,
			cf:            cf,
			log:           discardLogger(),
			suffix:        testSuffix,
			tunnelTarget:  testTarget,
			kick:          make(chan struct{}, 1),
			writeInterval: 0, // no rate limiting in tests
			owned:         map[string]bool{},
			published:     map[string]string{},
			orphans:       map[string]int{},
			cleanupTries:  map[string]int{},
			issues:        map[string]string{},
		},
	}
	e.sync()
	return e
}

// sync refreshes the lister from the API, which is what a real informer does
// after every write the controller makes.
func (e *env) sync() {
	e.t.Helper()
	list, err := e.client.CoreV1().Services("").List(context.Background(), metav1.ListOptions{})
	if err != nil {
		e.t.Fatalf("list services: %v", err)
	}
	objs := make([]any, 0, len(list.Items))
	for i := range list.Items {
		objs = append(objs, &list.Items[i])
	}
	if err := e.idx.Replace(objs, ""); err != nil {
		e.t.Fatalf("refresh lister: %v", err)
	}
}

func (e *env) reconcile() error {
	e.t.Helper()
	e.sync()
	return e.c.reconcile(context.Background())
}

func (e *env) service(namespace, name string) *corev1.Service {
	e.t.Helper()
	svc, err := e.client.CoreV1().Services(namespace).Get(context.Background(), name, metav1.GetOptions{})
	if err != nil {
		e.t.Fatalf("get %s/%s: %v", namespace, name, err)
	}
	return svc
}

func TestReconcilePublishesEveryLoadBalancerInOnePut(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf,
		svc("default", "web"),
		svc("shop", "api", func(s *corev1.Service) { s.Spec.ClusterIP = "10.43.0.8" }),
		svc("default", "internal", func(s *corev1.Service) { s.Spec.Type = corev1.ServiceTypeClusterIP }),
	)
	if err := e.reconcile(); err != nil {
		t.Fatalf("reconcile: %v", err)
	}

	// One PUT for the whole cluster, not one per Service: the ingress list is a
	// single document.
	if cf.configPuts != 1 {
		t.Errorf("configPuts = %d, want 1", cf.configPuts)
	}
	want := []string{
		"k8s.kubeflare.dev=>tcp://localhost:6443",
		"api-shop.lb.kubeflare.dev=>http://10.43.0.8:80",
		"web-default.lb.kubeflare.dev=>http://10.43.0.7:80",
		"=>http_status:404",
	}
	if got := summary(cf.ingress()); !slices.Equal(got, want) {
		t.Errorf("ingress = %v, want %v", got, want)
	}
	if cf.creates != 2 {
		t.Errorf("dns creates = %d, want 2", cf.creates)
	}
	for _, host := range []string{"web-default." + testSuffix, "api-shop." + testSuffix} {
		recs := cf.records[host]
		if len(recs) != 1 || recs[0].Content != testTarget || !recs[0].proxied() || recs[0].TTL != 1 {
			t.Errorf("dns for %s = %+v, want one proxied CNAME to the tunnel", host, recs)
		}
	}

	for _, ref := range [][2]string{{"default", "web"}, {"shop", "api"}} {
		got := e.service(ref[0], ref[1])
		if !hasFinalizer(got) {
			t.Errorf("%s/%s has no finalizer", ref[0], ref[1])
		}
		in := got.Status.LoadBalancer.Ingress
		if len(in) != 1 || in[0].Hostname == "" {
			t.Errorf("%s/%s status.loadBalancer.ingress = %v, want a hostname", ref[0], ref[1], in)
		}
	}
	if in := e.service("default", "internal").Status.LoadBalancer.Ingress; len(in) != 0 {
		t.Errorf("a ClusterIP Service was given an external address: %v", in)
	}
}

func TestReconcileWritesNothingWhenNothingChanged(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	before := *cf
	if err := e.reconcile(); err != nil {
		t.Fatalf("second reconcile: %v", err)
	}
	if cf.configPuts != before.configPuts {
		t.Errorf("configPuts = %d, want it unchanged at %d", cf.configPuts, before.configPuts)
	}
	if cf.creates != before.creates || cf.updates != before.updates || cf.dels != before.dels {
		t.Errorf("dns writes changed on a no-op pass: creates %d->%d updates %d->%d deletes %d->%d",
			before.creates, cf.creates, before.updates, cf.updates, before.dels, cf.dels)
	}
}

func TestReconcileReactsToASpecChange(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	updated := e.service("default", "web")
	updated.Spec.Ports[0].Port = 8080
	if _, err := e.client.CoreV1().Services("default").Update(context.Background(), updated, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("update service: %v", err)
	}
	if err := e.reconcile(); err != nil {
		t.Fatalf("second reconcile: %v", err)
	}
	if cf.configPuts != 2 {
		t.Errorf("configPuts = %d, want 2", cf.configPuts)
	}
	if got := summary(cf.ingress())[1]; got != "web-default.lb.kubeflare.dev=>http://10.43.0.7:8080" {
		t.Errorf("ingress rule = %q, want the new port", got)
	}
}

func TestDeletionWithdrawsEverythingAndReleasesTheFinalizer(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}

	deleting := e.service("default", "web")
	deleting.DeletionTimestamp = ptr(metav1.NewTime(time.Now()))
	if _, err := e.client.CoreV1().Services("default").Update(context.Background(), deleting, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("mark for deletion: %v", err)
	}
	if err := e.reconcile(); err != nil {
		t.Fatalf("cleanup reconcile: %v", err)
	}

	want := []string{"k8s.kubeflare.dev=>tcp://localhost:6443", "=>http_status:404"}
	if got := summary(cf.ingress()); !slices.Equal(got, want) {
		t.Errorf("ingress = %v, want %v", got, want)
	}
	if len(cf.records) != 0 {
		t.Errorf("dns records left behind: %v", cf.records)
	}
	if got := e.service("default", "web"); hasFinalizer(got) {
		t.Errorf("finalizer %s was not released", finalizerName)
	}
}

func TestDowngradeFromLoadBalancerIsCleanedUpToo(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	downgraded := e.service("default", "web")
	downgraded.Spec.Type = corev1.ServiceTypeClusterIP
	if _, err := e.client.CoreV1().Services("default").Update(context.Background(), downgraded, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("downgrade service: %v", err)
	}
	if err := e.reconcile(); err != nil {
		t.Fatalf("second reconcile: %v", err)
	}
	if len(cf.ingress()) != 2 {
		t.Errorf("ingress = %v, want the rule withdrawn", summary(cf.ingress()))
	}
	if len(cf.records) != 0 {
		t.Errorf("dns records left behind: %v", cf.records)
	}
	if hasFinalizer(e.service("default", "web")) {
		t.Errorf("finalizer left on a Service that is no longer a LoadBalancer")
	}
}

func TestFinalizerIsReleasedWhenCleanupKeepsFailing(t *testing.T) {
	// The wedge this guards against: a Service that can never be cleaned up
	// would otherwise sit in Terminating forever and block its namespace too.
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}

	deleting := e.service("default", "web")
	deleting.DeletionTimestamp = ptr(metav1.NewTime(time.Now()))
	if _, err := e.client.CoreV1().Services("default").Update(context.Background(), deleting, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("mark for deletion: %v", err)
	}
	cf.listErr = errors.New("token has no DNS permission")

	for i := 1; i < maxCleanupTries; i++ {
		if err := e.reconcile(); err == nil {
			t.Fatalf("pass %d succeeded, want the cleanup failure reported", i)
		}
		if !hasFinalizer(e.service("default", "web")) {
			t.Fatalf("finalizer released after only %d failed attempts", i)
		}
	}
	// The last attempt gives up and lets the object go.
	_ = e.reconcile()
	if hasFinalizer(e.service("default", "web")) {
		t.Errorf("finalizer still held after %d failed cleanups", maxCleanupTries)
	}
	if _, orphaned := e.c.orphans["web-default."+testSuffix]; !orphaned {
		t.Errorf("orphans = %v, want the abandoned hostname recorded for later cleanup", e.c.orphans)
	}
}

func TestAnnotatedHostnameCollidingWithTheAPIServerIsRefused(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web", annotate(hostnameAnnotation, "k8s.kubeflare.dev")))
	if err := e.reconcile(); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	want := []string{"k8s.kubeflare.dev=>tcp://localhost:6443", "=>http_status:404"}
	if got := summary(cf.ingress()); !slices.Equal(got, want) {
		t.Fatalf("ingress = %v, want the apiserver rule untouched", got)
	}
	if cf.creates != 0 {
		t.Errorf("dns creates = %d, want none for a refused hostname", cf.creates)
	}
	if in := e.service("default", "web").Status.LoadBalancer.Ingress; len(in) != 0 {
		t.Errorf("status = %v, want it left <pending> for a refused hostname", in)
	}
}

func TestChangingTheHostnameWithdrawsTheOldOne(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	renamed := e.service("default", "web")
	renamed.Annotations = map[string]string{hostnameAnnotation: "shop.kubeflare.dev"}
	if _, err := e.client.CoreV1().Services("default").Update(context.Background(), renamed, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("annotate service: %v", err)
	}
	if err := e.reconcile(); err != nil {
		t.Fatalf("second reconcile: %v", err)
	}
	want := []string{"k8s.kubeflare.dev=>tcp://localhost:6443", "shop.kubeflare.dev=>http://10.43.0.7:80", "=>http_status:404"}
	if got := summary(cf.ingress()); !slices.Equal(got, want) {
		t.Errorf("ingress = %v, want %v", got, want)
	}
	if _, stale := cf.records["web-default."+testSuffix]; stale {
		t.Errorf("the old DNS record survived a hostname change: %v", cf.records)
	}
}

// restart throws away every in-memory map, leaving only what is durable: the
// tunnel configuration, the DNS zone, and the Service objects.
func (e *env) restart() {
	prev := e.c
	e.c = &controller{
		svcs: prev.svcs, client: prev.client, cf: prev.cf, log: prev.log,
		suffix: prev.suffix, tunnelTarget: prev.tunnelTarget,
		kick:      make(chan struct{}, 1),
		owned:     map[string]bool{},
		published: map[string]string{},
		orphans:   map[string]int{},

		cleanupTries: map[string]int{},
		issues:       map[string]string{},
	}
}

func TestOwnershipOfAnAnnotatedHostnameSurvivesARestart(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web", annotate(hostnameAnnotation, "shop.kubeflare.dev")))
	if err := e.reconcile(); err != nil {
		t.Fatalf("first reconcile: %v", err)
	}
	if got := e.service("default", "web").Status.LoadBalancer.Ingress; len(got) != 1 || got[0].Hostname != "shop.kubeflare.dev" {
		t.Fatalf("status = %v, want shop.kubeflare.dev", got)
	}

	// A fresh process has no memory of shop.kubeflare.dev; only the Service
	// status says it was ever ours. Re-point the Service and the old hostname
	// still has to be withdrawn.
	e.restart()
	renamed := e.service("default", "web")
	renamed.Annotations[hostnameAnnotation] = "store.kubeflare.dev"
	if _, err := e.client.CoreV1().Services("default").Update(context.Background(), renamed, metav1.UpdateOptions{}); err != nil {
		t.Fatalf("re-annotate service: %v", err)
	}
	if err := e.reconcile(); err != nil {
		t.Fatalf("reconcile after restart: %v", err)
	}
	want := []string{"k8s.kubeflare.dev=>tcp://localhost:6443", "store.kubeflare.dev=>http://10.43.0.7:80", "=>http_status:404"}
	if got := summary(cf.ingress()); !slices.Equal(got, want) {
		t.Errorf("ingress = %v, want %v", got, want)
	}
	if _, stale := cf.records["shop.kubeflare.dev"]; stale {
		t.Errorf("the hostname from before the restart was not withdrawn: %v", cf.records)
	}
}

func TestHostnameCollisionKeepsTheOlderService(t *testing.T) {
	// "a-b" in namespace "c" and "a" in namespace "b-c" derive the same label.
	older := svc("c", "a-b", func(s *corev1.Service) {
		s.CreationTimestamp = metav1.NewTime(time.Now().Add(-time.Hour))
	})
	newer := svc("b-c", "a", func(s *corev1.Service) {
		s.CreationTimestamp = metav1.NewTime(time.Now())
		s.Spec.ClusterIP = "10.43.0.8"
	})
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, newer, older)
	if err := e.reconcile(); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	want := []string{"k8s.kubeflare.dev=>tcp://localhost:6443", "a-b-c.lb.kubeflare.dev=>http://10.43.0.7:80", "=>http_status:404"}
	if got := summary(cf.ingress()); !slices.Equal(got, want) {
		t.Errorf("ingress = %v, want only the older Service published (%v)", got, want)
	}
	if in := e.service("b-c", "a").Status.LoadBalancer.Ingress; len(in) != 0 {
		t.Errorf("the loser of a hostname collision was given an address: %v", in)
	}
}

func TestDryRunTouchesNothingInTheCluster(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	e := newEnv(t, cf, svc("default", "web"))
	e.c.dryRun = true
	if err := e.reconcile(); err != nil {
		t.Fatalf("reconcile: %v", err)
	}
	got := e.service("default", "web")
	if hasFinalizer(got) {
		t.Errorf("dry-run added a finalizer")
	}
	if in := got.Status.LoadBalancer.Ingress; len(in) != 0 {
		t.Errorf("dry-run wrote status %v", in)
	}
}

func TestATunnelAPIFailureDoesNotTouchDNS(t *testing.T) {
	cf := newFakeCF(apiserverRule(), catchAllRule())
	cf.getErr = errors.New("cloudflare is having a day")
	e := newEnv(t, cf, svc("default", "web"))
	if err := e.reconcile(); err == nil {
		t.Fatal("reconcile succeeded, want the tunnel read failure reported")
	}
	if cf.lists != 0 || cf.creates != 0 {
		t.Errorf("dns was touched without a good ingress document: lists=%d creates=%d", cf.lists, cf.creates)
	}
}
