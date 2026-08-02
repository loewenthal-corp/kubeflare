package main

import (
	"io"
	"log/slog"
	"net"
	"testing"
	"time"
)

func TestEndpointPoolRoundRobin(t *testing.T) {
	var p endpointPool
	if _, ok := p.pick(); ok {
		t.Fatal("empty pool must not yield an endpoint")
	}
	p.set([]string{"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80"})
	want := []string{
		"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80",
		"10.42.0.1:80", "10.42.0.2:80", "10.42.0.3:80",
		"10.42.0.1:80",
	}
	for i, w := range want {
		got, ok := p.pick()
		if !ok || got != w {
			t.Fatalf("pick %d: got %q (ok=%v), want %q", i, got, ok, w)
		}
	}
}

func TestEndpointPoolSwap(t *testing.T) {
	var p endpointPool
	p.set([]string{"10.42.0.1:80", "10.42.0.2:80"})
	if _, ok := p.pick(); !ok {
		t.Fatal("expected a pick before swap")
	}
	p.set([]string{"10.42.0.9:80"})
	for i := 0; i < 3; i++ {
		got, ok := p.pick()
		if !ok || got != "10.42.0.9:80" {
			t.Fatalf("pick %d after swap: got %q (ok=%v), want 10.42.0.9:80", i, got, ok)
		}
	}
	p.set(nil)
	if _, ok := p.pick(); ok {
		t.Fatal("cleared pool must not yield an endpoint")
	}
}

// echoBackend is a TCP listener that echoes its own address back, so a test
// can tell which backend a connection reached.
func echoBackend(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("backend listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			io.WriteString(c, ln.Addr().String())
			c.Close()
		}
	}()
	return ln.Addr().String()
}

// deadBackend is an address nothing is listening on, so dials to it fail.
func deadBackend(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("dead backend listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	return addr
}

// testListener is a listener with no sockets and no goroutines: enough to
// exercise backend selection and dialling.
func testListener(t *testing.T, affinity *affinityConfig, endpoints ...string) *proxyListener {
	t.Helper()
	l := &proxyListener{
		key:     proxyKey{ip: "10.43.0.7", port: 80, proto: "TCP"},
		service: "default/test",
		log:     slog.New(slog.DiscardHandler),
	}
	l.pool.set(endpoints)
	l.setAffinity(affinity)
	return l
}

func dialedBackend(t *testing.T, l *proxyListener, client string) string {
	t.Helper()
	c := l.dialUpstream(client)
	if c == nil {
		t.Fatalf("dialUpstream(%s) found no backend", client)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, err := io.ReadAll(c)
	if err != nil {
		t.Fatalf("read from backend: %v", err)
	}
	return string(got)
}

func TestDialUpstreamAffinityPinsOneClient(t *testing.T) {
	a, b := echoBackend(t), echoBackend(t)
	l := testListener(t, &affinityConfig{timeout: time.Hour}, a, b)
	first := dialedBackend(t, l, "10.42.0.100")
	for i := 0; i < 8; i++ {
		if got := dialedBackend(t, l, "10.42.0.100"); got != first {
			t.Fatalf("connection %d landed on %s, want the pinned %s", i, got, first)
		}
	}
	// sessionAffinity: None over the same backends still alternates.
	l = testListener(t, nil, a, b)
	seen := map[string]int{}
	for i := 0; i < 8; i++ {
		seen[dialedBackend(t, l, "10.42.0.100")]++
	}
	if seen[a] != 4 || seen[b] != 4 {
		t.Errorf("affinity off: distribution %v, want 4/4 across %s and %s", seen, a, b)
	}
}

func TestDialUpstreamAffinityAbandonsDeadBackend(t *testing.T) {
	live, dead := echoBackend(t), deadBackend(t)
	l := testListener(t, &affinityConfig{timeout: time.Hour}, dead, live)
	// Pin the client to the backend that will refuse the connection, as if
	// it had been Ready when the pin was made.
	l.affinity.mu.Lock()
	l.affinity.entries = map[string]*affinityEntry{
		"10.42.0.100": {backend: dead, lastSeen: time.Now().UnixNano()},
	}
	l.affinity.mu.Unlock()

	if got := dialedBackend(t, l, "10.42.0.100"); got != live {
		t.Fatalf("dialled %s, want the live backend %s", got, live)
	}
	// The failed dial must have moved the pin, not left it on the dead one.
	l.affinity.mu.Lock()
	pinned := l.affinity.entries["10.42.0.100"]
	l.affinity.mu.Unlock()
	if pinned == nil || pinned.backend != live {
		t.Fatalf("pin after failover = %v, want %s", pinned, live)
	}
}

func TestDialUpstreamNoEndpoints(t *testing.T) {
	for _, cfg := range []*affinityConfig{nil, {timeout: time.Hour}} {
		l := testListener(t, cfg)
		if c := l.dialUpstream("10.42.0.100"); c != nil {
			c.Close()
			t.Errorf("affinity=%v: dialled a backend with an empty pool", cfg)
		}
	}
}
