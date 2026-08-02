package main

import (
	"context"
	"log/slog"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/client-go/informers"
	corelisters "k8s.io/client-go/listers/core/v1"
	discoverylisters "k8s.io/client-go/listers/discovery/v1"
	"k8s.io/client-go/tools/cache"
)

// settleDelay coalesces informer event bursts (initial sync, rollouts) into
// one reconcile pass.
const settleDelay = 100 * time.Millisecond

// controller watches Services and EndpointSlices and keeps the running
// listener set in sync: one listener per ClusterIP x service port x protocol.
type controller struct {
	svcs   corelisters.ServiceLister
	eps    discoverylisters.EndpointSliceLister
	synced []cache.InformerSynced
	log    *slog.Logger

	kick chan struct{} // coalesced change notifications

	// Owned by the run goroutine; no locking needed.
	running    map[proxyKey]*proxyListener
	warnedSCTP map[string]bool // service:port -> warned about SCTP
}

// listenerSpec is the desired state of one listener.
type listenerSpec struct {
	service   string          // namespace/name, for logs
	endpoints []string        // sorted ready "ip:port" backends
	affinity  *affinityConfig // nil for sessionAffinity: None
}

func newController(factory informers.SharedInformerFactory, log *slog.Logger) (*controller, error) {
	svcInf := factory.Core().V1().Services()
	epsInf := factory.Discovery().V1().EndpointSlices()
	c := &controller{
		svcs:       svcInf.Lister(),
		eps:        epsInf.Lister(),
		log:        log,
		kick:       make(chan struct{}, 1),
		running:    make(map[proxyKey]*proxyListener),
		warnedSCTP: make(map[string]bool),
	}
	h := cache.ResourceEventHandlerFuncs{
		AddFunc:    func(any) { c.poke() },
		UpdateFunc: func(any, any) { c.poke() },
		DeleteFunc: func(any) { c.poke() },
	}
	if _, err := svcInf.Informer().AddEventHandler(h); err != nil {
		return nil, err
	}
	if _, err := epsInf.Informer().AddEventHandler(h); err != nil {
		return nil, err
	}
	c.synced = []cache.InformerSynced{svcInf.Informer().HasSynced, epsInf.Informer().HasSynced}
	return c, nil
}

func (c *controller) poke() {
	select {
	case c.kick <- struct{}{}:
	default:
	}
}

// run reconciles on every change notification until ctx is cancelled, then
// stops all listeners.
func (c *controller) run(ctx context.Context) {
	defer c.stopAll()
	c.poke() // reconcile at least once, even if no event fired since cache sync
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.kick:
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
		c.reconcile(ctx)
	}
}

func (c *controller) reconcile(ctx context.Context) {
	desired := c.desiredState()
	if desired == nil {
		return
	}
	current := make(map[proxyKey][]string, len(c.running))
	for k, l := range c.running {
		current[k] = l.pool.snapshot()
	}
	des := make(map[proxyKey][]string, len(desired))
	for k, s := range desired {
		des[k] = s.endpoints
	}
	start, stop, update := diffListeners(current, des)
	for _, k := range stop {
		l := c.running[k]
		delete(c.running, k)
		l.stop()
	}
	for _, k := range update {
		s := desired[k]
		c.running[k].setEndpoints(s.endpoints)
		c.log.Debug("endpoints changed", "service", s.service, "listener", k.String(), "endpoints", s.endpoints)
	}
	for _, k := range start {
		s := desired[k]
		c.running[k] = startListener(ctx, k, s, c.log)
		c.log.Debug("endpoints set", "service", s.service, "listener", k.String(), "endpoints", s.endpoints)
	}
	// Affinity is not part of the listener diff: changing it never needs a
	// restart and never invalidates the socket, so it is simply reapplied
	// everywhere each pass. setAffinity is a no-op unless it actually moved.
	for k, s := range desired {
		if l, ok := c.running[k]; ok {
			l.setAffinity(s.affinity)
		}
	}
	if len(start)+len(stop)+len(update) > 0 {
		c.log.Debug("reconciled", "started", len(start), "stopped", len(stop), "updated", len(update), "listeners", len(c.running))
	}
}

func (c *controller) stopAll() {
	for k, l := range c.running {
		delete(c.running, k)
		l.stop()
	}
}

// diffListeners computes the transitions from running to desired. Keys in
// both with differing endpoint sets go to update — those listeners must swap
// endpoints in place, never restart. A changed ClusterIP, port, or protocol
// is a different key and therefore lands in stop+start. Results are sorted
// for determinism.
func diffListeners(running, desired map[proxyKey][]string) (start, stop, update []proxyKey) {
	for k := range running {
		if _, ok := desired[k]; !ok {
			stop = append(stop, k)
		}
	}
	for k, eps := range desired {
		cur, ok := running[k]
		switch {
		case !ok:
			start = append(start, k)
		case !slices.Equal(cur, eps):
			update = append(update, k)
		}
	}
	for _, s := range [][]proxyKey{start, stop, update} {
		slices.SortFunc(s, func(a, b proxyKey) int { return strings.Compare(a.String(), b.String()) })
	}
	return start, stop, update
}

// desiredState computes the full desired listener set from the informer
// caches. Returns nil when listing fails (it cannot for in-memory listers,
// but nil must mean "skip this pass", never "tear everything down").
func (c *controller) desiredState() map[proxyKey]listenerSpec {
	services, err := c.svcs.List(labels.Everything())
	if err != nil {
		c.log.Error("list services", "error", err)
		return nil
	}
	epSlices, err := c.eps.List(labels.Everything())
	if err != nil {
		c.log.Error("list endpointslices", "error", err)
		return nil
	}
	slicesByService := make(map[string][]*discoveryv1.EndpointSlice)
	for _, s := range epSlices {
		if owner := s.Labels[discoveryv1.LabelServiceName]; owner != "" {
			key := s.Namespace + "/" + owner
			slicesByService[key] = append(slicesByService[key], s)
		}
	}

	desired := make(map[proxyKey]listenerSpec)
	sctpNow := make(map[string]bool)
	for _, svc := range services {
		// Headless and ExternalName services have no ClusterIP to serve.
		if svc.Spec.Type == corev1.ServiceTypeExternalName ||
			svc.Spec.ClusterIP == "" || svc.Spec.ClusterIP == corev1.ClusterIPNone {
			continue
		}
		name := svc.Namespace + "/" + svc.Name
		// One config shared by every listener of this service, but each
		// listener keeps its own pin table (see svcproxy/README.md).
		affinity := clientIPAffinity(svc)
		ips := svc.Spec.ClusterIPs
		if len(ips) == 0 {
			ips = []string{svc.Spec.ClusterIP}
		}
		for _, port := range svc.Spec.Ports {
			proto := port.Protocol
			if proto == "" {
				proto = corev1.ProtocolTCP
			}
			if proto == corev1.ProtocolSCTP {
				pk := name + ":" + strconv.Itoa(int(port.Port))
				sctpNow[pk] = true
				if !c.warnedSCTP[pk] {
					c.warnedSCTP[pk] = true
					c.log.Warn("SCTP is not supported, skipping port", "service", name, "port", port.Port)
				}
				continue
			}
			if port.Port <= 0 {
				continue
			}
			endpoints := readyEndpoints(slicesByService[name], port.Name, proto)
			for _, ip := range ips {
				addr, err := netip.ParseAddr(ip)
				if err != nil || !addr.Is4() {
					continue // IPv4 only in v1
				}
				desired[proxyKey{ip: ip, port: port.Port, proto: string(proto)}] =
					listenerSpec{service: name, endpoints: endpoints, affinity: affinity}
			}

			// NodePort. Bound on the wildcard address rather than a specific one,
			// which is both what upstream NodePort means ("every node address")
			// and what makes it reachable from the Worker — the container's
			// externally-facing address is not contractual, so guessing one
			// wrong would make the port unreachable from outside.
			//
			// Node ports live in 30000-32767 and so cannot collide with the
			// host's own 0.0.0.0 listeners on 8001/8080 (see entrypoint.sh).
			if port.NodePort != 0 &&
				(svc.Spec.Type == corev1.ServiceTypeNodePort || svc.Spec.Type == corev1.ServiceTypeLoadBalancer) {
				desired[proxyKey{ip: "", port: port.NodePort, proto: string(proto)}] =
					listenerSpec{service: name, endpoints: endpoints, affinity: affinity}
			}
		}
	}
	// Forget warn suppressions for conditions that no longer hold, so they
	// warn again if they come back and the map cannot grow without bound.
	for k := range c.warnedSCTP {
		if !sctpNow[k] {
			delete(c.warnedSCTP, k)
		}
	}
	return desired
}

// readyEndpoints resolves the concrete "ip:port" backends for one service
// port. EndpointSlice ports carry the resolved targetPort numbers under the
// same name as the service port (empty name when the single port is unnamed),
// so no targetPort arithmetic happens here — this handles the default
// kubernetes service (host IP:6443) through the same path as everything else.
// A nil Ready condition counts as ready, per API convention.
func readyEndpoints(sls []*discoveryv1.EndpointSlice, portName string, proto corev1.Protocol) []string {
	set := make(map[string]struct{})
	for _, s := range sls {
		if s.AddressType != discoveryv1.AddressTypeIPv4 {
			continue
		}
		var targetPort int32 = -1
		for _, p := range s.Ports {
			name := ""
			if p.Name != nil {
				name = *p.Name
			}
			pproto := corev1.ProtocolTCP
			if p.Protocol != nil {
				pproto = *p.Protocol
			}
			if name == portName && pproto == proto && p.Port != nil {
				targetPort = *p.Port
				break
			}
		}
		if targetPort < 0 {
			continue
		}
		for _, ep := range s.Endpoints {
			if ep.Conditions.Ready != nil && !*ep.Conditions.Ready {
				continue
			}
			if len(ep.Addresses) == 0 {
				continue
			}
			set[net.JoinHostPort(ep.Addresses[0], strconv.Itoa(int(targetPort)))] = struct{}{}
		}
	}
	out := make([]string, 0, len(set))
	for e := range set {
		out = append(out, e)
	}
	slices.Sort(out)
	return out
}
