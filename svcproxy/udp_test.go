package main

import (
	"net"
	"testing"
	"time"
)

// udpBackend is a bound UDP socket that never answers: enough for a session
// to be dialled and pinned.
func udpBackend(t *testing.T) string {
	t.Helper()
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("udp backend listen: %v", err)
	}
	t.Cleanup(func() { pc.Close() })
	return pc.LocalAddr().String()
}

func testForwarder(t *testing.T, affinity *affinityConfig, endpoints ...string) *udpForwarder {
	t.Helper()
	pc, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("forwarder listen: %v", err)
	}
	f := &udpForwarder{
		l:        testListener(t, affinity, endpoints...),
		conn:     pc.(*net.UDPConn),
		sessions: make(map[string]*udpSession),
	}
	t.Cleanup(func() { f.closeAll(); f.conn.Close() })
	return f
}

func mustSession(t *testing.T, f *udpForwarder, ip string, port int) *udpSession {
	t.Helper()
	s, err := f.session(&net.UDPAddr{IP: net.ParseIP(ip), Port: port})
	if err != nil {
		t.Fatalf("session(%s:%d): %v", ip, port, err)
	}
	return s
}

// The two pinning mechanisms must compose: the session table stays keyed by
// ip:port so replies remain coherent, while the backend behind every one of a
// client's source ports is the same affine backend.
func TestUDPSessionsShareOneClientIPPin(t *testing.T) {
	a, b := udpBackend(t), udpBackend(t)
	f := testForwarder(t, &affinityConfig{timeout: time.Hour}, a, b)

	s1 := mustSession(t, f, "10.42.0.100", 1111)
	s2 := mustSession(t, f, "10.42.0.100", 2222)
	if s1 == s2 {
		t.Fatal("two source ports shared one session; replies would go to the wrong port")
	}
	if s1.backend != s2.backend {
		t.Errorf("same client split across backends: %s and %s", s1.backend, s2.backend)
	}
	if got := mustSession(t, f, "10.42.0.100", 1111); got != s1 {
		t.Error("an established session was replaced")
	}

	// A different client is free to land elsewhere, and with two backends and
	// round-robin pinning it does.
	s3 := mustSession(t, f, "10.42.0.101", 1111)
	if s3.backend == s1.backend {
		t.Errorf("second client pinned to the same backend %s; want the other of %s/%s", s3.backend, a, b)
	}
}

func TestUDPSessionsRoundRobinWithoutAffinity(t *testing.T) {
	a, b := udpBackend(t), udpBackend(t)
	f := testForwarder(t, nil, a, b)
	s1 := mustSession(t, f, "10.42.0.100", 1111)
	s2 := mustSession(t, f, "10.42.0.100", 2222)
	if s1.backend == s2.backend {
		t.Errorf("sessionAffinity None must still alternate; both got %s", s1.backend)
	}
}

// A datagram on an established session has to keep the client's pin alive,
// or a client whose only traffic is one long-lived flow loses it.
func TestUDPSessionTouchesAffinity(t *testing.T) {
	a := udpBackend(t)
	f := testForwarder(t, &affinityConfig{timeout: 10 * time.Minute}, a)
	mustSession(t, f, "10.42.0.100", 1111)
	age(t, &f.l.affinity, "10.42.0.100", 9*time.Minute)
	mustSession(t, f, "10.42.0.100", 1111) // same session: only touch runs
	if n := f.l.affinity.expire(time.Now().UnixNano()); n != 0 {
		t.Errorf("pin expired despite an active session (%d dropped)", n)
	}
}

// setEndpoints has to clear both tables, so neither a UDP session nor an
// affinity pin keeps pointing at a backend that stopped being Ready.
func TestSetEndpointsPrunesSessionsAndPins(t *testing.T) {
	a, b := udpBackend(t), udpBackend(t)
	f := testForwarder(t, &affinityConfig{timeout: time.Hour}, a, b)
	f.l.udp.Store(f)
	s1 := mustSession(t, f, "10.42.0.100", 1111)
	mustSession(t, f, "10.42.0.101", 1111)

	survivor := a
	if s1.backend == a {
		survivor = b
	}
	f.l.setEndpoints([]string{survivor})

	f.mu.Lock()
	sessions := len(f.sessions)
	f.mu.Unlock()
	if sessions != 1 {
		t.Errorf("%d UDP sessions survived, want 1 (the one on %s)", sessions, survivor)
	}
	if n := f.l.affinity.size(); n != 1 {
		t.Errorf("%d affinity pins survived, want 1", n)
	}
	if got := mustSession(t, f, "10.42.0.100", 1111); got.backend != survivor {
		t.Errorf("re-pinned client went to %s, want the only ready backend %s", got.backend, survivor)
	}
}
