package main

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
)

// roundTripFunc stands in for the network. Every test in this file drives the
// client through it, so nothing here opens a socket.
type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
}

func testClient(rt roundTripFunc) *cfClient {
	c := newCFClient("https://api.test/client/v4", "tok", "acct", "zone", "tunnel", false, discardLogger())
	c.http = &http.Client{Transport: rt}
	c.backoff = 0 // no sleeping in tests
	return c
}

func jsonResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     http.Header{"Content-Type": {"application/json"}},
	}
}

func TestTunnelConfigRoundTripPreservesUnknownKeys(t *testing.T) {
	const body = `{"success":true,"errors":[],"result":{"tunnel_id":"t","version":5,"config":{
		"ingress":[{"hostname":"k8s.kubeflare.dev","service":"tcp://localhost:6443"},{"service":"http_status:404"}],
		"warp-routing":{"enabled":true},
		"originRequest":{"connectTimeout":30}}}}`

	var sent map[string]any
	c := testClient(func(r *http.Request) (*http.Response, error) {
		if r.Method == http.MethodPut {
			if err := json.NewDecoder(r.Body).Decode(&sent); err != nil {
				t.Fatalf("decode PUT body: %v", err)
			}
			return jsonResponse(200, `{"success":true,"errors":[],"result":{}}`), nil
		}
		if got := r.Header.Get("Authorization"); got != "Bearer tok" {
			t.Errorf("Authorization = %q", got)
		}
		return jsonResponse(200, body), nil
	})

	cfg, err := c.tunnelConfig(context.Background())
	if err != nil {
		t.Fatalf("tunnelConfig: %v", err)
	}
	if len(cfg.ingress()) != 2 {
		t.Fatalf("ingress = %v, want 2 rules", cfg.ingress())
	}
	cfg.setIngress(append(cfg.ingress()[:1], ingressRule{"service": catchAllService}))
	if err := c.putTunnelConfig(context.Background(), cfg); err != nil {
		t.Fatalf("putTunnelConfig: %v", err)
	}

	config, _ := sent["config"].(map[string]any)
	if config == nil {
		t.Fatalf("PUT body = %v, want a config member", sent)
	}
	// warp-routing and originRequest are not fields this controller knows what
	// to do with, and a PUT replaces the whole document, so they have to come
	// back out exactly as they went in.
	if warp, _ := json.Marshal(config["warp-routing"]); string(warp) != `{"enabled":true}` {
		t.Errorf("warp-routing = %s, want it preserved", warp)
	}
	if origin, _ := json.Marshal(config["originRequest"]); string(origin) != `{"connectTimeout":30}` {
		t.Errorf("originRequest = %s, want it preserved verbatim", origin)
	}
}

func TestDryRunSkipsWritesButStillReads(t *testing.T) {
	reads := 0
	c := testClient(func(r *http.Request) (*http.Response, error) {
		if r.Method != http.MethodGet {
			t.Fatalf("dry-run issued a %s to %s", r.Method, r.URL.Path)
		}
		reads++
		return jsonResponse(200, `{"success":true,"errors":[],"result":[]}`), nil
	})
	c.dryRun = true

	if _, err := c.dnsRecords(context.Background(), "web-default.lb.kubeflare.dev"); err != nil {
		t.Fatalf("dnsRecords: %v", err)
	}
	if err := c.createDNS(context.Background(), dnsRecord{Type: "CNAME", Name: "x", Content: "y"}); err != nil {
		t.Fatalf("createDNS: %v", err)
	}
	if err := c.deleteDNS(context.Background(), "id"); err != nil {
		t.Fatalf("deleteDNS: %v", err)
	}
	if reads != 1 {
		t.Errorf("reads = %d, want 1", reads)
	}
}

func TestRetriesRateLimitsAndServerErrors(t *testing.T) {
	attempts := 0
	c := testClient(func(*http.Request) (*http.Response, error) {
		attempts++
		switch attempts {
		case 1:
			return jsonResponse(429, `{"success":false,"errors":[{"code":10000,"message":"rate limited"}]}`), nil
		case 2:
			return jsonResponse(502, `<html>bad gateway</html>`), nil
		default:
			return jsonResponse(200, `{"success":true,"errors":[],"result":[]}`), nil
		}
	})
	if _, err := c.dnsRecords(context.Background(), "web-default.lb.kubeflare.dev"); err != nil {
		t.Fatalf("dnsRecords: %v", err)
	}
	if attempts != 3 {
		t.Errorf("attempts = %d, want 3", attempts)
	}
}

func TestPermissionFailureIsNotRetriedAndIsRecognisable(t *testing.T) {
	attempts := 0
	c := testClient(func(*http.Request) (*http.Response, error) {
		attempts++
		return jsonResponse(403, `{"success":false,"errors":[{"code":9109,"message":"Unauthorized to access requested resource"}]}`), nil
	})
	_, err := c.dnsRecords(context.Background(), "web-default.lb.kubeflare.dev")
	if err == nil {
		t.Fatal("dnsRecords succeeded, want a permission error")
	}
	if attempts != 1 {
		t.Errorf("attempts = %d, want 1 (a 403 will not fix itself)", attempts)
	}
	if !isDenied(err) {
		t.Errorf("isDenied(%v) = false, want true", err)
	}
	if !strings.Contains(err.Error(), "9109") {
		t.Errorf("error %q does not mention the Cloudflare error code", err)
	}
}

func TestParseTunnelConfigHandlesAnUnconfiguredTunnel(t *testing.T) {
	for _, raw := range []string{"", "null", "{}"} {
		cfg, err := parseTunnelConfig(json.RawMessage(raw))
		if err != nil {
			t.Fatalf("parseTunnelConfig(%q): %v", raw, err)
		}
		if len(cfg.ingress()) != 0 {
			t.Errorf("parseTunnelConfig(%q) ingress = %v, want none", raw, cfg.ingress())
		}
		cfg.setIngress([]ingressRule{{"service": catchAllService}})
		if len(cfg.ingress()) != 1 {
			t.Errorf("setIngress on an empty config did not take")
		}
	}
}
