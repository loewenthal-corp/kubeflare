package main

import (
	"context"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
)

const (
	// The API server defaults sessionAffinityConfig.clientIP.timeoutSeconds to
	// 10800 (3h) and writes it out explicitly, so this fallback only covers
	// objects that carry affinity with no config block at all.
	defaultAffinityTimeout = 3 * time.Hour
	// Bound the table the way udp.go bounds its session table: one entry per
	// distinct client IP is a memory leak with a hostile-client shape, since
	// nothing stops a client from arriving under thousands of source
	// addresses. Full table evicts the least recently active pin.
	affinityMaxEntries = 4096
	// Pins idle out after the service's own timeout, which defaults to 3h, so
	// sweeping frequently buys nothing: this bounds how long an expired pin
	// keeps its memory, not when it stops being honoured. pick rechecks
	// expiry itself and never hands out a stale backend.
	affinitySweepEvery = time.Minute
)

// affinityConfig is the ClientIP session affinity of one service port. A nil
// *affinityConfig means sessionAffinity: None.
type affinityConfig struct {
	timeout time.Duration
}

// clientIPAffinity reads a service's ClientIP affinity, or nil when it has
// none.
func clientIPAffinity(svc *corev1.Service) *affinityConfig {
	if svc.Spec.SessionAffinity != corev1.ServiceAffinityClientIP {
		return nil
	}
	cfg := &affinityConfig{timeout: defaultAffinityTimeout}
	if c := svc.Spec.SessionAffinityConfig; c != nil && c.ClientIP != nil &&
		c.ClientIP.TimeoutSeconds != nil && *c.ClientIP.TimeoutSeconds > 0 {
		cfg.timeout = time.Duration(*c.ClientIP.TimeoutSeconds) * time.Second
	}
	return cfg
}

// affinityTable implements sessionAffinity: ClientIP for one listener. It
// pins a client IP — deliberately not the ip:port, which would pin every
// connection separately and so pin nothing at all — to the backend that
// client was last sent to.
//
// The endpoint set moves underneath it, so a pin is never trusted on its own:
// every lookup revalidates it against the live ready set. A client whose
// backend went away re-pins immediately; every other client keeps its pin.
//
// The zero value is a working table with affinity off, in which state it
// stays empty and every lookup is exactly endpointPool.pick.
type affinityTable struct {
	cfg atomic.Pointer[affinityConfig] // nil: affinity off

	mu      sync.Mutex
	entries map[string]*affinityEntry // client IP -> pin
}

type affinityEntry struct {
	backend  string
	lastSeen int64 // unix nanos, guarded by mu
}

// setConfig swaps the affinity configuration, reporting whether it changed.
// Turning affinity off drops every pin: keeping them would silently resurrect
// hours-old pinning if the service turned affinity back on later.
func (a *affinityTable) setConfig(cfg *affinityConfig) bool {
	old := a.cfg.Load()
	switch {
	case old == nil && cfg == nil:
		return false
	case old != nil && cfg != nil && *old == *cfg:
		return false
	}
	a.cfg.Store(cfg)
	if cfg == nil {
		a.mu.Lock()
		clear(a.entries)
		a.mu.Unlock()
	}
	return true
}

// pick returns the backend this client is pinned to, pinning it to a fresh
// round-robin choice when it has no usable pin. With affinity off it is
// endpointPool.pick and nothing else — the common path must not regress.
// False means no backend is ready.
func (a *affinityTable) pick(clientIP string, pool *endpointPool) (string, bool) {
	cfg := a.cfg.Load()
	if cfg == nil {
		return pool.pick()
	}
	ready := pool.snapshot()
	if len(ready) == 0 {
		return "", false
	}
	now := time.Now().UnixNano()

	a.mu.Lock()
	defer a.mu.Unlock()
	if e, ok := a.entries[clientIP]; ok {
		// A pin holds only while it is fresh and its backend is still Ready.
		// Either check failing re-pins this one client and leaves the rest of
		// the table alone.
		if now-e.lastSeen < int64(cfg.timeout) && slices.Contains(ready, e.backend) {
			e.lastSeen = now
			return e.backend, true
		}
		delete(a.entries, clientIP)
	}
	backend, ok := pool.pick() // unpinned clients still spread round-robin
	if !ok {
		return "", false
	}
	if a.entries == nil {
		a.entries = make(map[string]*affinityEntry)
	}
	if len(a.entries) >= affinityMaxEntries {
		a.evictOldestLocked()
	}
	a.entries[clientIP] = &affinityEntry{backend: backend, lastSeen: now}
	return backend, true
}

// touch refreshes an existing pin without creating one. UDP calls it for
// datagrams on an already-established session: those never reach pick again,
// and without a refresh a single long-lived flow would let its own pin idle
// out, sending the next flow from that client somewhere else.
func (a *affinityTable) touch(clientIP string) {
	if a.cfg.Load() == nil {
		return
	}
	a.mu.Lock()
	if e, ok := a.entries[clientIP]; ok {
		e.lastSeen = time.Now().UnixNano()
	}
	a.mu.Unlock()
}

// forget drops a pin after a failed dial, but only while the client is still
// pinned to the backend that failed: a concurrent connection may already have
// moved it somewhere live, and clobbering that would un-pin a working client.
func (a *affinityTable) forget(clientIP, backend string) {
	if a.cfg.Load() == nil {
		return
	}
	a.mu.Lock()
	if e, ok := a.entries[clientIP]; ok && e.backend == backend {
		delete(a.entries, clientIP)
	}
	a.mu.Unlock()
}

// prune drops pins to backends that are no longer ready, mirroring
// udpForwarder.prune. pick would catch these lazily too; dropping them
// eagerly stops a dead backend's pins from occupying the table until every
// one of those clients happens to come back.
func (a *affinityTable) prune(backends []string) int {
	if a.cfg.Load() == nil {
		return 0
	}
	keep := make(map[string]bool, len(backends))
	for _, b := range backends {
		keep[b] = true
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for ip, e := range a.entries {
		if !keep[e.backend] {
			delete(a.entries, ip)
			n++
		}
	}
	return n
}

// expire drops pins idle for longer than the configured timeout.
func (a *affinityTable) expire(now int64) int {
	cfg := a.cfg.Load()
	if cfg == nil {
		return 0
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	n := 0
	for ip, e := range a.entries {
		if now-e.lastSeen >= int64(cfg.timeout) {
			delete(a.entries, ip)
			n++
		}
	}
	return n
}

func (a *affinityTable) evictOldestLocked() {
	var oldestIP string
	var oldest *affinityEntry
	for ip, e := range a.entries {
		if oldest == nil || e.lastSeen < oldest.lastSeen {
			oldestIP, oldest = ip, e
		}
	}
	if oldest != nil {
		delete(a.entries, oldestIP)
	}
}

// sweep expires idle pins for the listener's whole life. It also runs while
// affinity is off, when the table is empty and the tick costs one wakeup.
func (a *affinityTable) sweep(ctx context.Context) {
	tick := time.NewTicker(affinitySweepEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		a.expire(time.Now().UnixNano())
	}
}

func (a *affinityTable) size() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	return len(a.entries)
}
