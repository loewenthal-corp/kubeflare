package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	corelisters "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/retry"
)

const (
	// settleDelay coalesces informer event bursts into one reconcile pass. It
	// is longer than svcproxy's because the work behind it is a handful of
	// HTTPS round-trips rather than a bind(), and because the ingress document
	// is global: ten Services changing together must produce one PUT.
	settleDelay = 500 * time.Millisecond
	// minWriteInterval is a floor between two Cloudflare writes, so a pathological
	// event loop cannot turn into an API rate-limit problem.
	minWriteInterval = 2 * time.Second

	minRetryBackoff = 2 * time.Second
	maxRetryBackoff = 60 * time.Second

	// resyncPeriod re-runs the reconcile even when the cluster has not changed,
	// which is what heals a tunnel config or a DNS record edited by hand in the
	// Cloudflare dashboard. Nothing is written when nothing differs.
	resyncPeriod = 10 * time.Minute

	// maxCleanupTries bounds how long a finalizer may hold up a Service
	// deletion. See finishCleanup.
	maxCleanupTries = 10
)

// controller watches LoadBalancer Services and keeps three things in sync with
// them: the tunnel's ingress list, one proxied CNAME per hostname, and
// .status.loadBalancer on the Service itself.
type controller struct {
	svcs   corelisters.ServiceLister
	client kubernetes.Interface
	cf     cfAPI
	synced []cache.InformerSynced
	log    *slog.Logger

	suffix       string
	tunnelTarget string // <tunnel-id>.cfargotunnel.com
	dryRun       bool

	kick chan struct{} // coalesced change notifications

	// Everything below is owned by the run goroutine; no locking needed.
	writeInterval time.Duration
	lastWrite     time.Time
	// owned holds every hostname this process has published. A rule can only be
	// reaped if it can be recognised as ours, and a hostname set by annotation
	// need not sit under --hostname-suffix, so the suffix alone is not enough.
	owned map[string]bool
	// published maps a Service to the hostname last written for it, so that
	// editing the hostname annotation withdraws the old name instead of
	// stranding it.
	published map[string]string
	// orphans are hostnames that are ours but belong to nothing any more: left
	// by a forced finalizer release or by a hostname change. Their DNS records
	// are deleted on a best-effort basis; the value counts failed attempts.
	orphans map[string]int
	// cleanupTries counts consecutive failed cleanup passes per Service.
	cleanupTries map[string]int
	// issues remembers the last configuration error logged per Service so a
	// permanently broken Service does not reprint it on every pass.
	issues map[string]string
}

func newController(factory informers.SharedInformerFactory, client kubernetes.Interface, cf cfAPI,
	suffix, tunnelID string, dryRun bool, log *slog.Logger) (*controller, error) {
	svcInf := factory.Core().V1().Services()
	c := &controller{
		svcs:          svcInf.Lister(),
		client:        client,
		cf:            cf,
		log:           log,
		suffix:        suffix,
		tunnelTarget:  tunnelID + ".cfargotunnel.com",
		dryRun:        dryRun,
		kick:          make(chan struct{}, 1),
		writeInterval: minWriteInterval,
		owned:         make(map[string]bool),
		published:     make(map[string]string),
		orphans:       make(map[string]int),
		cleanupTries:  make(map[string]int),
		issues:        make(map[string]string),
	}
	h := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { c.poke() },
		UpdateFunc: func(any, any) { c.poke() },
		DeleteFunc: func(any) { c.poke() },
	}
	if _, err := svcInf.Informer().AddEventHandler(h); err != nil {
		return nil, err
	}
	c.synced = []cache.InformerSynced{svcInf.Informer().HasSynced}
	return c, nil
}

func (c *controller) poke() {
	select {
	case c.kick <- struct{}{}:
	default:
	}
}

// run reconciles on every change notification until ctx is cancelled. A failed
// pass is retried with exponential backoff; nothing short of a cancelled
// context stops the loop.
func (c *controller) run(ctx context.Context) {
	backoff := minRetryBackoff
	var retryAfter <-chan time.Time
	c.poke() // reconcile at least once, even if no event fired since cache sync
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.kick:
		case <-retryAfter:
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(settleDelay):
		}
		select { // drain anything that arrived while settling
		case <-c.kick:
		default:
		}
		if err := c.reconcile(ctx); err != nil {
			if ctx.Err() != nil {
				return
			}
			c.log.Error("reconcile failed, will retry", "error", err, "retry_after", backoff)
			retryAfter = time.After(backoff)
			if backoff *= 2; backoff > maxRetryBackoff {
				backoff = maxRetryBackoff
			}
			continue
		}
		retryAfter = nil
		backoff = minRetryBackoff
	}
}

// reconcile runs one full pass. It is deliberately whole-world rather than
// per-Service: the ingress list is a single document, so it has to be computed
// from every Service at once and written once.
func (c *controller) reconcile(ctx context.Context) error {
	services, err := c.svcs.List(labels.Everything())
	if err != nil {
		return fmt.Errorf("list services: %w", err) // cannot happen for an in-memory lister
	}
	live, cleanup := c.plan(services)

	var errs []error
	for _, t := range live {
		if err := c.ensureFinalizer(ctx, t); err != nil {
			errs = append(errs, fmt.Errorf("%s: add finalizer: %w", t.key(), err))
		}
	}

	conflicted, ingressErr := c.reconcileIngress(ctx, live, cleanup)
	if ingressErr != nil {
		errs = append(errs, ingressErr)
	} else {
		// DNS is only touched once the ingress document is known good. Without
		// a successful read there is no way to tell whether a hostname belongs
		// to something else in this tunnel, and a CNAME with no matching
		// ingress rule only ever serves the catch-all anyway.
		for _, t := range live {
			if conflicted[t.hostname] {
				continue
			}
			if err := c.ensureDNS(ctx, t); err != nil {
				errs = append(errs, fmt.Errorf("%s: dns %s: %w", t.key(), t.hostname, err))
				continue
			}
			if err := c.ensureStatus(ctx, t); err != nil {
				errs = append(errs, fmt.Errorf("%s: write status: %w", t.key(), err))
			}
		}
	}

	for _, t := range cleanup {
		if err := c.finishCleanup(ctx, t, ingressErr == nil); err != nil {
			errs = append(errs, fmt.Errorf("%s: cleanup: %w", t.key(), err))
		}
	}
	c.reapOrphans(ctx)
	return errors.Join(errs...)
}

// plan turns the informer cache into the two lists the pass works from: the
// Services to publish, and the ones whose Cloudflare state has to be withdrawn.
func (c *controller) plan(services []*corev1.Service) (live, cleanup []lbTarget) {
	// Oldest first, so that a hostname collision is resolved the same way on
	// every pass and in favour of the Service that already has it.
	ordered := slices.Clone(services)
	slices.SortFunc(ordered, func(a, b *corev1.Service) int {
		if n := a.CreationTimestamp.Time.Compare(b.CreationTimestamp.Time); n != 0 {
			return n
		}
		return cmpKeys(a, b)
	})

	claimed := make(map[string]string, len(ordered)) // hostname -> owning service
	seen := make(map[string]bool, len(ordered))
	for _, svc := range ordered {
		key := svc.Namespace + "/" + svc.Name
		// .status.loadBalancer is the only durable record of what this
		// controller published, and unlike the in-memory maps it survives a
		// restart. Without seeding from it, a hostname set by annotation —
		// which need not sit under --hostname-suffix — would look like
		// somebody else's rule after every restart.
		if c.published[key] == "" {
			if in := svc.Status.LoadBalancer.Ingress; len(in) == 1 && in[0].Hostname != "" {
				c.published[key] = in[0].Hostname
			}
		}
		isLB := svc.Spec.Type == corev1.ServiceTypeLoadBalancer && svc.DeletionTimestamp == nil
		if !isLB {
			// A Service that is going away, or that was downgraded from
			// LoadBalancer to something else, still has to have its rule and
			// record withdrawn — and its finalizer released, or it can never
			// be deleted.
			if hasFinalizer(svc) {
				cleanup = append(cleanup, lbTarget{
					namespace: svc.Namespace, name: svc.Name, hostname: c.cleanupHostname(svc),
				})
				seen[key] = true
			}
			continue
		}
		seen[key] = true
		host, err := deriveHostname(svc, c.suffix)
		if err != nil {
			c.problem(key, err)
			continue
		}
		if owner, dup := claimed[host]; dup {
			c.problem(key, fmt.Errorf("hostname %s is already claimed by the older Service %s", host, owner))
			continue
		}
		origin, err := originFor(svc)
		if err != nil {
			c.problem(key, err)
			continue
		}
		claimed[host] = key
		c.resolved(key)
		// A hostname this Service used to be published under is now nobody's.
		if old := c.published[key]; old != "" && old != host {
			c.log.Info("hostname changed, withdrawing the old one", "service", key, "from", old, "to", host)
			c.orphans[old] = 0
		}
		live = append(live, lbTarget{
			namespace: svc.Namespace, name: svc.Name, hostname: host, origin: origin,
		})
	}

	for key := range c.issues {
		if !seen[key] {
			delete(c.issues, key)
		}
	}
	for key := range c.published {
		if !seen[key] {
			delete(c.published, key)
		}
	}
	return live, cleanup
}

// cleanupHostname is the name to withdraw for a Service that is no longer
// publishable. What this process actually published wins over what the current
// spec would derive, because the annotation may have been edited on the way out.
func (c *controller) cleanupHostname(svc *corev1.Service) string {
	if h := c.published[svc.Namespace+"/"+svc.Name]; h != "" {
		return h
	}
	h, err := deriveHostname(svc, c.suffix)
	if err != nil {
		return "" // nothing was ever published under a name we can reconstruct
	}
	return h
}

// reconcileIngress rebuilds the whole ingress document and writes it back, at
// most once per pass. It returns the hostnames that could not be published.
func (c *controller) reconcileIngress(ctx context.Context, live, cleanup []lbTarget) (map[string]bool, error) {
	cfg, err := c.cf.tunnelConfig(ctx)
	if err != nil {
		if isDenied(err) {
			c.log.Error("the API token cannot read the tunnel configuration; it needs Account > Cloudflare Tunnel > Edit", "error", err)
		}
		return nil, fmt.Errorf("read tunnel configuration: %w", err)
	}

	desired := make([]ingressRule, 0, len(live))
	for _, t := range live {
		desired = append(desired, ingressRule{"hostname": t.hostname, "service": t.origin})
		// A hostname becomes ours by being published, not by being wanted. If
		// merely wanting it were enough, an annotation naming a hostname that
		// something else already serves — the apiserver rule, say — would
		// quietly evict it instead of being refused.
		if prev := c.published[t.key()]; prev != "" {
			c.owned[prev] = true
		}
	}
	for _, t := range cleanup {
		if t.hostname != "" {
			c.owned[t.hostname] = true
		}
	}
	for h := range c.orphans {
		c.owned[h] = true
	}

	current := cfg.ingress()
	rules, conflicts := rebuildIngress(current, desired, c.owned, c.suffix)
	conflicted := make(map[string]bool, len(conflicts))
	for _, cf := range conflicts {
		if cf.hostname != "" {
			conflicted[cf.hostname] = true
			c.log.Error("refusing to publish hostname", "hostname", cf.hostname, "reason", cf.reason)
			continue
		}
		c.log.Warn("tunnel ingress list looks wrong", "reason", cf.reason)
	}

	if rulesEqual(current, rules) {
		c.log.Debug("tunnel ingress already up to date", "rules", len(rules), "managed", len(desired))
		c.settle(live, rules)
		return conflicted, nil
	}
	cfg.setIngress(rules)
	c.waitWriteSlot(ctx)
	if err := c.cf.putTunnelConfig(ctx, cfg); err != nil {
		if isDenied(err) {
			c.log.Error("the API token cannot write the tunnel configuration; it needs Account > Cloudflare Tunnel > Edit", "error", err)
		}
		return conflicted, fmt.Errorf("write tunnel configuration: %w", err)
	}
	c.log.Info("tunnel ingress updated", "rules", len(rules), "managed", len(desired), "preserved", len(rules)-len(desired)-1)
	c.settle(live, rules)
	return conflicted, nil
}

// settle records what is now published and forgets hostnames that the document
// no longer mentions, which is what keeps owned from growing forever.
func (c *controller) settle(live []lbTarget, rules []ingressRule) {
	present := make(map[string]bool, len(rules))
	for _, r := range rules {
		present[r.hostname()] = true
	}
	for _, t := range live {
		if !present[t.hostname] {
			continue // refused; it never became ours
		}
		c.published[t.key()] = t.hostname
		c.owned[t.hostname] = true
	}
	for h := range c.owned {
		// Orphans stay owned until their DNS record is gone: the rule is
		// already withdrawn, but the hostname is still ours to clean up.
		if !present[h] {
			if _, pending := c.orphans[h]; !pending {
				delete(c.owned, h)
			}
		}
	}
}

// ensureDNS makes the hostname a proxied CNAME to the tunnel.
func (c *controller) ensureDNS(ctx context.Context, t lbTarget) error {
	recs, err := c.cf.dnsRecords(ctx, t.hostname)
	if err != nil {
		c.denyHint(err)
		return err
	}
	want := dnsRecord{
		Type:    "CNAME",
		Name:    t.hostname,
		Content: c.tunnelTarget,
		Proxied: ptr(true),
		TTL:     1, // required for proxied records; Cloudflare rejects anything else
		Comment: "kubeflare-lbcontroller: Service " + t.key(),
	}
	verb, id, err := decideDNS(recs, want)
	if err != nil {
		c.problem(t.key(), err)
		return nil // an operator has to resolve this; retrying will not
	}
	switch verb {
	case dnsNoop:
		c.log.Debug("dns record up to date", "hostname", t.hostname)
		return nil
	case dnsCreate:
		c.waitWriteSlot(ctx)
		if err := c.cf.createDNS(ctx, want); err != nil {
			c.denyHint(err)
			return err
		}
	case dnsUpdate:
		c.waitWriteSlot(ctx)
		if err := c.cf.updateDNS(ctx, id, want); err != nil {
			c.denyHint(err)
			return err
		}
	}
	c.log.Info("dns record "+verb.String()+"d", "hostname", t.hostname, "content", want.Content, "service", t.key())
	return nil
}

// deleteDNS withdraws the CNAME for a hostname, and only if it still points at
// this tunnel — a record somebody has repointed since is not ours to delete.
func (c *controller) deleteDNS(ctx context.Context, hostname string) error {
	if hostname == "" {
		return nil
	}
	recs, err := c.cf.dnsRecords(ctx, hostname)
	if err != nil {
		c.denyHint(err)
		return err
	}
	for _, r := range recs {
		if !strings.EqualFold(strings.TrimSuffix(r.Name, "."), hostname) ||
			!strings.EqualFold(r.Type, "CNAME") ||
			!strings.EqualFold(strings.TrimSuffix(r.Content, "."), c.tunnelTarget) {
			continue
		}
		if c.dryRun {
			c.log.Info("dry-run: would delete dns record", "hostname", hostname, "id", r.ID)
			return nil
		}
		c.waitWriteSlot(ctx)
		if err := c.cf.deleteDNS(ctx, r.ID); err != nil {
			c.denyHint(err)
			return err
		}
		c.log.Info("dns record deleted", "hostname", hostname)
		return nil
	}
	c.log.Debug("no dns record of ours at hostname, nothing to delete", "hostname", hostname)
	return nil
}

// finishCleanup withdraws a Service's Cloudflare state and then releases the
// finalizer.
//
// The finalizer is the dangerous part of this controller: a Service that can
// never be cleaned up would otherwise sit in Terminating forever, and a stuck
// Terminating Service blocks namespace deletion too. So cleanup is bounded. If
// it has failed maxCleanupTries times in a row — several minutes, given the
// caller's backoff — the finalizer comes off anyway, loudly, and the hostname
// moves to the orphan list for best-effort DNS cleanup. Leaking a DNS record is
// recoverable by hand; a Service nobody can delete is not.
func (c *controller) finishCleanup(ctx context.Context, t lbTarget, ingressOK bool) error {
	err := errors.New("tunnel ingress list was not updated this pass")
	if ingressOK {
		err = c.deleteDNS(ctx, t.hostname)
	}
	if err == nil {
		delete(c.cleanupTries, t.key())
		delete(c.published, t.key())
		delete(c.owned, t.hostname)
		return c.removeFinalizer(ctx, t)
	}

	c.cleanupTries[t.key()]++
	if n := c.cleanupTries[t.key()]; n < maxCleanupTries {
		c.log.Warn("cleanup failed, will retry before releasing the finalizer",
			"service", t.key(), "hostname", t.hostname, "attempt", n, "of", maxCleanupTries, "error", err)
		return err
	}
	c.log.Error("giving up on Cloudflare cleanup and releasing the finalizer to let the Service delete; "+
		"check for a leftover DNS record by hand",
		"service", t.key(), "hostname", t.hostname, "attempts", maxCleanupTries, "error", err)
	delete(c.cleanupTries, t.key())
	delete(c.published, t.key())
	if t.hostname != "" {
		c.orphans[t.hostname] = 0
	}
	return c.removeFinalizer(ctx, t)
}

// reapOrphans keeps trying to delete DNS records for hostnames that no longer
// belong to a Service. Unlike cleanup this blocks nothing, so it is pure
// best-effort — but it is still bounded, because a record the token is not
// allowed to delete would otherwise be retried until the process dies.
func (c *controller) reapOrphans(ctx context.Context) {
	for h, tries := range c.orphans {
		if err := c.deleteDNS(ctx, h); err != nil {
			c.orphans[h] = tries + 1
			if tries+1 >= maxCleanupTries {
				c.log.Error("abandoning an orphaned DNS record; delete it by hand",
					"hostname", h, "content", c.tunnelTarget, "error", err)
				delete(c.orphans, h)
				delete(c.owned, h)
			}
			continue
		}
		delete(c.orphans, h)
		delete(c.owned, h)
	}
}

// ensureStatus writes the hostname into .status.loadBalancer so that
// `kubectl get svc` stops printing <pending>.
func (c *controller) ensureStatus(ctx context.Context, t lbTarget) error {
	cur, err := c.svcs.Services(t.namespace).Get(t.name)
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		return err
	}
	// Skipping the no-op write matters: every status write comes back as an
	// informer update, so writing unconditionally would be a self-sustaining
	// reconcile loop.
	if in := cur.Status.LoadBalancer.Ingress; len(in) == 1 && in[0].Hostname == t.hostname && in[0].IP == "" {
		return nil
	}
	if c.dryRun {
		c.log.Info("dry-run: would set status.loadBalancer.ingress", "service", t.key(), "hostname", t.hostname)
		return nil
	}
	err = retry.RetryOnConflict(retry.DefaultRetry, func() error {
		svc, err := c.client.CoreV1().Services(t.namespace).Get(ctx, t.name, metav1.GetOptions{})
		if err != nil {
			return err
		}
		svc.Status.LoadBalancer.Ingress = []corev1.LoadBalancerIngress{{Hostname: t.hostname}}
		_, err = c.client.CoreV1().Services(svc.Namespace).UpdateStatus(ctx, svc, metav1.UpdateOptions{})
		return err
	})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		return err
	}
	c.log.Info("status published", "service", t.key(), "hostname", t.hostname)
	return nil
}

func (c *controller) ensureFinalizer(ctx context.Context, t lbTarget) error {
	return c.setFinalizer(ctx, t, true)
}

func (c *controller) removeFinalizer(ctx context.Context, t lbTarget) error {
	return c.setFinalizer(ctx, t, false)
}

// setFinalizer adds or removes the controller's finalizer. The object is
// re-read inside the retry because a Service under active reconciliation
// collects conflicting writes (status, annotations, endpoints controllers), and
// a lost update here would either strand a deletion or drop the guard that
// makes cleanup possible.
func (c *controller) setFinalizer(ctx context.Context, t lbTarget, want bool) error {
	if c.dryRun {
		c.log.Info("dry-run: would change finalizer", "service", t.key(), "finalizer", finalizerName, "present", want)
		return nil
	}
	changed := false
	err := retry.RetryOnConflict(retry.DefaultRetry, func() error {
		svc, err := c.client.CoreV1().Services(t.namespace).Get(ctx, t.name, metav1.GetOptions{})
		if err != nil {
			return err
		}
		switch {
		case want && hasFinalizer(svc):
			return nil
		case want && svc.DeletionTimestamp != nil:
			return nil // never re-arm a guard on an object already going away
		case want:
			svc.Finalizers = append(svc.Finalizers, finalizerName)
		case !hasFinalizer(svc):
			return nil
		default:
			svc.Finalizers = slices.DeleteFunc(svc.Finalizers, func(f string) bool { return f == finalizerName })
		}
		_, err = c.client.CoreV1().Services(svc.Namespace).Update(ctx, svc, metav1.UpdateOptions{})
		changed = err == nil
		return err
	})
	if apierrors.IsNotFound(err) {
		return nil // deleted underneath us: nothing left to guard
	}
	if err != nil {
		return err
	}
	if changed && !want {
		c.log.Info("finalizer released", "service", t.key(), "hostname", t.hostname)
	}
	return nil
}

// waitWriteSlot spaces Cloudflare writes out. Passes are already coalesced, so
// this only ever bites when many Services churn at once.
func (c *controller) waitWriteSlot(ctx context.Context) {
	if d := c.writeInterval - time.Since(c.lastWrite); d > 0 {
		select {
		case <-ctx.Done():
		case <-time.After(d):
		}
	}
	c.lastWrite = time.Now()
}

// problem logs a per-Service configuration error once. Reconciles are frequent
// (every informer event, plus the resync), and a Service that is permanently
// misconfigured must not fill the log with the same line forever.
func (c *controller) problem(key string, err error) {
	msg := err.Error()
	if c.issues[key] == msg {
		return
	}
	c.issues[key] = msg
	c.log.Error("service cannot be published", "service", key, "error", msg)
}

func (c *controller) resolved(key string) { delete(c.issues, key) }

// denyHint turns the one failure an operator is most likely to hit — a token
// without DNS:Edit on the zone — into a line that says what to do about it.
func (c *controller) denyHint(err error) {
	if isDenied(err) {
		c.log.Error("the API token was refused for a DNS call; it needs Zone > DNS > Edit on the kubeflare zone", "error", err)
	}
}

func hasFinalizer(svc *corev1.Service) bool { return slices.Contains(svc.Finalizers, finalizerName) }

func cmpKeys(a, b *corev1.Service) int {
	if n := strings.Compare(a.Namespace, b.Namespace); n != 0 {
		return n
	}
	return strings.Compare(a.Name, b.Name)
}
