package main

import "testing"

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
