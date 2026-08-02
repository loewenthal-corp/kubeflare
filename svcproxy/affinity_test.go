package main

import (
	"net"
	"slices"
	"strconv"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// clientIPTable is a table with ClientIP affinity on and the given timeout.
func clientIPTable(timeout time.Duration) *affinityTable {
	a := &affinityTable{}
	a.setConfig(&affinityConfig{timeout: timeout})
	return a
}

func poolOf(eps ...string) *endpointPool {
	p := &endpointPool{}
	p.set(eps)
	return p
}

// age backdates a pin so expiry can be tested without sleeping.
func age(t *testing.T, a *affinityTable, clientIP string, by time.Duration) {
	t.Helper()
	a.mu.Lock()
	defer a.mu.Unlock()
	e, ok := a.entries[clientIP]
	if !ok {
		t.Fatalf("no pin for %s to age", clientIP)
	}
	e.lastSeen -= int64(by)
}

func TestAffinityOffIsPlainRoundRobin(t *testing.T) {
	// The sessionAffinity: None path must stay exactly endpointPool.pick:
	// one client, three backends, strict rotation, and nothing recorded.
	var a affinityTable
	p := poolOf("10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80")
	want := []string{
		"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80",
		"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80",
	}
	for i, w := range want {
		got, ok := a.pick("10.42.0.100", p)
		if !ok || got != w {
			t.Fatalf("pick %d: got %q (ok=%v), want %q", i, got, ok, w)
		}
	}
	if n := a.size(); n != 0 {
		t.Errorf("affinity off recorded %d entries, want 0", n)
	}
}

func TestAffinitySameClientPins(t *testing.T) {
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80")
	first, ok := a.pick("10.42.0.100", p)
	if !ok {
		t.Fatal("first pick found no backend")
	}
	for i := 0; i < 20; i++ {
		got, ok := a.pick("10.42.0.100", p)
		if !ok || got != first {
			t.Fatalf("pick %d: got %q (ok=%v), want the pinned %q", i, got, ok, first)
		}
	}
	if n := a.size(); n != 1 {
		t.Errorf("one client produced %d entries, want 1", n)
	}
}

func TestAffinityDifferentClientsSpread(t *testing.T) {
	a := clientIPTable(time.Hour)
	backends := []string{"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80"}
	p := poolOf(backends...)
	hits := map[string]int{}
	for i := 0; i < 30; i++ {
		got, ok := a.pick("10.42.0."+strconv.Itoa(100+i), p)
		if !ok {
			t.Fatalf("client %d got no backend", i)
		}
		hits[got]++
	}
	// New clients are pinned by round-robin, so 30 clients over 3 backends
	// must land 10 apiece.
	for _, b := range backends {
		if hits[b] != 10 {
			t.Errorf("backend %s took %d of 30 clients, want 10 (all: %v)", b, hits[b], hits)
		}
	}
	if n := a.size(); n != 30 {
		t.Errorf("30 clients produced %d entries, want 30", n)
	}
}

func TestAffinityPinSurvivesEndpointChurn(t *testing.T) {
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	pinned, _ := a.pick("10.42.0.100", p)

	// Scale up, scale down, reorder — as long as the pinned backend is still
	// Ready the client must not move.
	for _, eps := range [][]string{
		{"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80"},
		{pinned, "10.42.0.9:80"},
		{"10.42.0.9:80", "10.42.0.7:80", pinned},
	} {
		p.set(eps)
		if n := a.prune(eps); n != 0 {
			t.Fatalf("prune(%v) dropped %d pins, want 0", eps, n)
		}
		got, ok := a.pick("10.42.0.100", p)
		if !ok || got != pinned {
			t.Fatalf("after endpoints=%v: got %q (ok=%v), want the pinned %q", eps, got, ok, pinned)
		}
	}
}

func TestAffinityPinMovesWhenBackendGoesAway(t *testing.T) {
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80")
	victim, _ := a.pick("10.42.0.100", p)
	other, _ := a.pick("10.42.0.101", p)
	if victim == other {
		t.Fatalf("test needs two clients on different backends, both got %q", victim)
	}
	survivors := slices.DeleteFunc(p.snapshot(), func(e string) bool { return e == victim })
	p.set(survivors)

	// The eager prune drops exactly the pins to the dead backend.
	if n := a.prune(survivors); n != 1 {
		t.Errorf("prune dropped %d pins, want exactly 1", n)
	}
	got, ok := a.pick("10.42.0.100", p)
	if !ok || got == victim {
		t.Fatalf("re-pin: got %q (ok=%v), want any live backend from %v", got, ok, survivors)
	}
	if !slices.Contains(survivors, got) {
		t.Fatalf("re-pinned to %q, which is not ready (%v)", got, survivors)
	}
	// The unrelated client keeps its pin.
	if got, _ := a.pick("10.42.0.101", p); got != other {
		t.Errorf("unrelated client moved from %q to %q", other, got)
	}
}

func TestAffinityRepinsWithoutPrune(t *testing.T) {
	// prune is an optimisation; pick alone must never hand out a backend
	// that has dropped out of the ready set.
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	pinned, _ := a.pick("10.42.0.100", p)
	survivors := slices.DeleteFunc(p.snapshot(), func(e string) bool { return e == pinned })
	p.set(survivors) // no prune call at all
	got, ok := a.pick("10.42.0.100", p)
	if !ok || got != survivors[0] {
		t.Fatalf("got %q (ok=%v), want %q", got, ok, survivors[0])
	}
}

func TestAffinityNoReadyEndpoints(t *testing.T) {
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80")
	if _, ok := a.pick("10.42.0.100", p); !ok {
		t.Fatal("expected a backend while one is ready")
	}
	p.set(nil)
	if got, ok := a.pick("10.42.0.100", p); ok {
		t.Errorf("empty pool yielded %q, want no backend", got)
	}
}

func TestAffinityExpires(t *testing.T) {
	a := clientIPTable(10 * time.Minute)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	pinned, _ := a.pick("10.42.0.100", p)

	// Just inside the timeout: the pin holds, and using it refreshes it.
	age(t, a, "10.42.0.100", 9*time.Minute)
	if got, _ := a.pick("10.42.0.100", p); got != pinned {
		t.Fatalf("pin expired early: got %q, want %q", got, pinned)
	}
	// Past the timeout: pick itself must re-pin rather than serve it stale.
	age(t, a, "10.42.0.100", 11*time.Minute)
	if got, _ := a.pick("10.42.0.100", p); got == pinned {
		t.Fatalf("expired pin was reused: %q", got)
	}

	// And the sweeper reclaims entries nobody comes back for.
	a.pick("10.42.0.101", p)
	age(t, a, "10.42.0.101", 11*time.Minute)
	if n := a.expire(time.Now().UnixNano()); n != 1 {
		t.Errorf("expire dropped %d entries, want 1", n)
	}
	if n := a.size(); n != 1 {
		t.Errorf("table has %d entries after expiry, want 1 (the fresh one)", n)
	}
}

func TestAffinityTouchKeepsPinAlive(t *testing.T) {
	a := clientIPTable(10 * time.Minute)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	pinned, _ := a.pick("10.42.0.100", p)
	age(t, a, "10.42.0.100", 9*time.Minute)
	a.touch("10.42.0.100") // a datagram on an established UDP session
	if n := a.expire(time.Now().UnixNano()); n != 0 {
		t.Errorf("touched pin was expired (%d dropped)", n)
	}
	if got, _ := a.pick("10.42.0.100", p); got != pinned {
		t.Errorf("touched client moved from %q to %q", pinned, got)
	}
	// touch never invents a pin for a client that has none.
	a.touch("10.42.0.200")
	if n := a.size(); n != 1 {
		t.Errorf("touch created an entry: size %d, want 1", n)
	}
}

func TestAffinityForget(t *testing.T) {
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	pinned, _ := a.pick("10.42.0.100", p)

	// A stale forget — the client has already moved on — must not un-pin it.
	stale := "10.42.0.9:80"
	a.forget("10.42.0.100", stale)
	if got, _ := a.pick("10.42.0.100", p); got != pinned {
		t.Errorf("stale forget un-pinned the client: %q, want %q", got, pinned)
	}
	// Forgetting the backend it is actually on drops the pin, as after a
	// failed dial.
	a.forget("10.42.0.100", pinned)
	if n := a.size(); n != 0 {
		t.Errorf("forget left %d entries, want 0", n)
	}
}

func TestAffinityTableIsBounded(t *testing.T) {
	a := clientIPTable(time.Hour)
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	// Every client is distinct, which is the hostile shape: the table must
	// stay at the cap and evict the least recently active pin.
	for i := 0; i < affinityMaxEntries+500; i++ {
		a.pick("10.99."+strconv.Itoa(i/256)+"."+strconv.Itoa(i%256), p)
		if n := a.size(); n > affinityMaxEntries {
			t.Fatalf("table grew to %d entries at client %d, cap is %d", n, i, affinityMaxEntries)
		}
	}
	if n := a.size(); n != affinityMaxEntries {
		t.Errorf("table settled at %d entries, want the cap %d", n, affinityMaxEntries)
	}
	// The very first client is long gone; the most recent one is still here.
	a.mu.Lock()
	_, oldest := a.entries["10.99.0.0"]
	_, newest := a.entries["10.99."+strconv.Itoa((affinityMaxEntries+499)/256)+"."+strconv.Itoa((affinityMaxEntries+499)%256)]
	a.mu.Unlock()
	if oldest {
		t.Error("least recently active pin survived eviction")
	}
	if !newest {
		t.Error("most recently added pin was evicted")
	}
}

func TestAffinitySetConfig(t *testing.T) {
	var a affinityTable
	p := poolOf("10.42.0.1:80", "10.42.0.2:80")
	if a.setConfig(nil) {
		t.Error("None -> None reported a change")
	}
	cfg := &affinityConfig{timeout: time.Hour}
	if !a.setConfig(cfg) {
		t.Error("None -> ClientIP reported no change")
	}
	if a.setConfig(&affinityConfig{timeout: time.Hour}) {
		t.Error("an identical config reported a change")
	}
	if !a.setConfig(&affinityConfig{timeout: 2 * time.Hour}) {
		t.Error("a changed timeout reported no change")
	}
	// Switching affinity off must not leave hours-old pins behind to be
	// resurrected if it comes back on.
	a.pick("10.42.0.100", p)
	if !a.setConfig(nil) {
		t.Error("ClientIP -> None reported no change")
	}
	if n := a.size(); n != 0 {
		t.Errorf("disabling affinity left %d pins", n)
	}
}

func TestClientIPAffinityFromService(t *testing.T) {
	svc := func(mut func(*corev1.Service)) *corev1.Service {
		s := &corev1.Service{}
		mut(s)
		return s
	}
	tests := []struct {
		name string
		svc  *corev1.Service
		want *affinityConfig
	}{
		{"unset", svc(func(*corev1.Service) {}), nil},
		{"explicit None", svc(func(s *corev1.Service) {
			s.Spec.SessionAffinity = corev1.ServiceAffinityNone
		}), nil},
		{"ClientIP, no config block", svc(func(s *corev1.Service) {
			s.Spec.SessionAffinity = corev1.ServiceAffinityClientIP
		}), &affinityConfig{timeout: defaultAffinityTimeout}},
		{"ClientIP, empty config block", svc(func(s *corev1.Service) {
			s.Spec.SessionAffinity = corev1.ServiceAffinityClientIP
			s.Spec.SessionAffinityConfig = &corev1.SessionAffinityConfig{}
		}), &affinityConfig{timeout: defaultAffinityTimeout}},
		{"ClientIP, explicit timeout", svc(func(s *corev1.Service) {
			s.Spec.SessionAffinity = corev1.ServiceAffinityClientIP
			s.Spec.SessionAffinityConfig = &corev1.SessionAffinityConfig{
				ClientIP: &corev1.ClientIPConfig{TimeoutSeconds: ptr[int32](30)},
			}
		}), &affinityConfig{timeout: 30 * time.Second}},
		{"ClientIP, nonsense timeout falls back", svc(func(s *corev1.Service) {
			s.Spec.SessionAffinity = corev1.ServiceAffinityClientIP
			s.Spec.SessionAffinityConfig = &corev1.SessionAffinityConfig{
				ClientIP: &corev1.ClientIPConfig{TimeoutSeconds: ptr[int32](0)},
			}
		}), &affinityConfig{timeout: defaultAffinityTimeout}},
		{"None with a stale config block", svc(func(s *corev1.Service) {
			s.Spec.SessionAffinity = corev1.ServiceAffinityNone
			s.Spec.SessionAffinityConfig = &corev1.SessionAffinityConfig{
				ClientIP: &corev1.ClientIPConfig{TimeoutSeconds: ptr[int32](30)},
			}
		}), nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := clientIPAffinity(tc.svc)
			switch {
			case got == nil && tc.want == nil:
			case got == nil || tc.want == nil:
				t.Fatalf("clientIPAffinity = %v, want %v", got, tc.want)
			case *got != *tc.want:
				t.Fatalf("clientIPAffinity timeout = %v, want %v", got.timeout, tc.want.timeout)
			}
		})
	}
}

func TestClientIPKey(t *testing.T) {
	// The port must never reach the key, or every connection pins separately.
	tests := []struct {
		addr net.Addr
		want string
	}{
		{&net.TCPAddr{IP: net.ParseIP("10.42.0.7"), Port: 54321}, "10.42.0.7"},
		{&net.UDPAddr{IP: net.ParseIP("10.42.0.7"), Port: 53}, "10.42.0.7"},
		{&net.TCPAddr{IP: net.ParseIP("::1"), Port: 80}, "::1"},
		{&net.IPAddr{IP: net.ParseIP("10.0.0.1")}, "10.0.0.1"},
	}
	for _, tc := range tests {
		if got := clientIP(tc.addr); got != tc.want {
			t.Errorf("clientIP(%v) = %q, want %q", tc.addr, got, tc.want)
		}
	}
}
