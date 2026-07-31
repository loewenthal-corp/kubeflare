package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	defaultAPIBase = "https://api.cloudflare.com/client/v4"
	httpTimeout    = 30 * time.Second
	apiAttempts    = 4
	apiBackoff     = time.Second
	maxAPIBackoff  = 15 * time.Second
)

// cfAPI is the slice of the Cloudflare API this controller uses. It exists so
// the controller can be tested without a network, and so every call site is
// visible in one place — this is the whole blast radius of a bad token.
type cfAPI interface {
	tunnelConfig(ctx context.Context) (*tunnelConfig, error)
	putTunnelConfig(ctx context.Context, cfg *tunnelConfig) error
	dnsRecords(ctx context.Context, name string) ([]dnsRecord, error)
	createDNS(ctx context.Context, rec dnsRecord) error
	updateDNS(ctx context.Context, id string, rec dnsRecord) error
	deleteDNS(ctx context.Context, id string) error
}

// tunnelConfig is the tunnel's whole "config" document, held as decoded JSON
// for the same reason ingressRule is: a PUT replaces the document, so keys this
// controller knows nothing about have to survive untouched. warp-routing is the
// one that matters today (the cluster's tunnel has it enabled), but the same
// applies to originRequest and to anything Cloudflare adds later.
type tunnelConfig struct {
	fields map[string]any
}

func (c *tunnelConfig) ingress() []ingressRule {
	raw, _ := c.fields["ingress"].([]any)
	out := make([]ingressRule, 0, len(raw))
	for _, r := range raw {
		if m, ok := r.(map[string]any); ok {
			out = append(out, ingressRule(m))
		}
	}
	return out
}

func (c *tunnelConfig) setIngress(rules []ingressRule) {
	list := make([]any, 0, len(rules))
	for _, r := range rules {
		list = append(list, map[string]any(r))
	}
	c.fields["ingress"] = list
}

// parseTunnelConfig decodes the "config" object. UseNumber keeps numeric fields
// as their original literals so that re-marshalling a rule this controller only
// passes through cannot turn 30 into 3e+01 and count as a change.
func parseTunnelConfig(raw json.RawMessage) (*tunnelConfig, error) {
	cfg := &tunnelConfig{fields: map[string]any{}}
	if len(raw) == 0 || string(raw) == "null" {
		return cfg, nil // tunnel exists but has never been configured
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&cfg.fields); err != nil {
		return nil, fmt.Errorf("decode tunnel config: %w", err)
	}
	if cfg.fields == nil {
		cfg.fields = map[string]any{}
	}
	return cfg, nil
}

// dnsRecord is the subset of a Cloudflare DNS record this controller reads or
// writes. Proxied is a pointer because the API omits it for record types that
// cannot be proxied, and "absent" must not read as "explicitly grey-clouded".
type dnsRecord struct {
	ID      string `json:"id,omitempty"`
	Type    string `json:"type"`
	Name    string `json:"name"`
	Content string `json:"content"`
	Proxied *bool  `json:"proxied,omitempty"`
	TTL     int    `json:"ttl,omitempty"`
	Comment string `json:"comment,omitempty"`
}

func (r dnsRecord) proxied() bool { return r.Proxied != nil && *r.Proxied }

// apiError carries the Cloudflare error envelope, numeric error codes and all.
// The status matters: a 403 means the token is missing a permission and no
// amount of retrying will fix it, which is a different log line from a
// transient 502.
type apiError struct {
	method, path string
	status       int
	message      string
}

func (e *apiError) Error() string {
	if e.message == "" {
		return fmt.Sprintf("%s %s: HTTP %d", e.method, e.path, e.status)
	}
	return fmt.Sprintf("%s %s: HTTP %d: %s", e.method, e.path, e.status, e.message)
}

// denied reports an authentication or authorisation failure, i.e. a token
// problem the operator has to fix.
func (e *apiError) denied() bool {
	return e.status == http.StatusUnauthorized || e.status == http.StatusForbidden
}

func isDenied(err error) bool {
	var ae *apiError
	return errors.As(err, &ae) && ae.denied()
}

type cfClient struct {
	http      *http.Client
	base      string
	token     string
	accountID string
	zoneID    string
	tunnelID  string
	dryRun    bool
	backoff   time.Duration // first retry wait; a field so tests need not sleep
	log       *slog.Logger
}

func newCFClient(base, token, accountID, zoneID, tunnelID string, dryRun bool, log *slog.Logger) *cfClient {
	if base == "" {
		base = defaultAPIBase
	}
	return &cfClient{
		http:      &http.Client{Timeout: httpTimeout},
		base:      strings.TrimSuffix(base, "/"),
		token:     token,
		accountID: accountID,
		zoneID:    zoneID,
		tunnelID:  tunnelID,
		dryRun:    dryRun,
		backoff:   apiBackoff,
		log:       log,
	}
}

func (c *cfClient) tunnelConfig(ctx context.Context) (*tunnelConfig, error) {
	raw, err := c.do(ctx, http.MethodGet, c.tunnelPath(), nil)
	if err != nil {
		return nil, err
	}
	var result struct {
		Config json.RawMessage `json:"config"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("decode tunnel configuration response: %w", err)
	}
	return parseTunnelConfig(result.Config)
}

func (c *cfClient) putTunnelConfig(ctx context.Context, cfg *tunnelConfig) error {
	_, err := c.do(ctx, http.MethodPut, c.tunnelPath(), map[string]any{"config": cfg.fields})
	return err
}

func (c *cfClient) tunnelPath() string {
	return "/accounts/" + c.accountID + "/cfd_tunnel/" + c.tunnelID + "/configurations"
}

func (c *cfClient) dnsRecords(ctx context.Context, name string) ([]dnsRecord, error) {
	q := url.Values{"name": {name}, "per_page": {"100"}}
	raw, err := c.do(ctx, http.MethodGet, "/zones/"+c.zoneID+"/dns_records?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	var recs []dnsRecord
	if err := json.Unmarshal(raw, &recs); err != nil {
		return nil, fmt.Errorf("decode dns_records response: %w", err)
	}
	return recs, nil
}

func (c *cfClient) createDNS(ctx context.Context, rec dnsRecord) error {
	_, err := c.do(ctx, http.MethodPost, "/zones/"+c.zoneID+"/dns_records", rec)
	return err
}

func (c *cfClient) updateDNS(ctx context.Context, id string, rec dnsRecord) error {
	rec.ID = ""
	_, err := c.do(ctx, http.MethodPatch, "/zones/"+c.zoneID+"/dns_records/"+id, rec)
	return err
}

func (c *cfClient) deleteDNS(ctx context.Context, id string) error {
	_, err := c.do(ctx, http.MethodDelete, "/zones/"+c.zoneID+"/dns_records/"+id, nil)
	return err
}

// do performs one API call and returns the "result" member of the envelope.
//
// Writes are skipped under --dry-run, after logging the exact body that would
// have been sent: the point of the flag is to see the document that would
// replace the live tunnel configuration before anything replaces it.
//
// 429 and 5xx are retried with exponential backoff and jitter (honouring
// Retry-After when Cloudflare sends one). 4xx is not: a rejected document or a
// token without a permission will be rejected just as fast the second time, and
// the caller's own backoff will bring it round again later anyway.
func (c *cfClient) do(ctx context.Context, method, path string, body any) (json.RawMessage, error) {
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return nil, fmt.Errorf("encode %s %s body: %w", method, path, err)
		}
	}
	if c.dryRun && method != http.MethodGet {
		c.log.Info("dry-run: skipping Cloudflare write", "method", method, "path", path, "body", string(payload))
		return nil, nil
	}

	backoff := c.backoff
	var lastErr error
	for attempt := 1; attempt <= apiAttempts; attempt++ {
		if attempt > 1 {
			// Half the backoff plus jitter: several Services rarely change at
			// once here, but a retry storm against a rate limit must not stay
			// in lockstep.
			wait := backoff/2 + time.Duration(rand.Int64N(max(int64(backoff), 1)))
			c.log.Debug("retrying Cloudflare call", "method", method, "path", path,
				"attempt", attempt, "wait", wait, "error", lastErr)
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(wait):
			}
			if backoff *= 2; backoff > maxAPIBackoff {
				backoff = maxAPIBackoff
			}
		}
		result, retryAfter, err := c.attempt(ctx, method, path, payload)
		if err == nil {
			return result, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			return nil, err
		}
		var ae *apiError
		if errors.As(err, &ae) && !retryableStatus(ae.status) {
			return nil, err
		}
		if retryAfter > 0 && retryAfter < maxAPIBackoff {
			backoff = retryAfter
		}
	}
	return nil, fmt.Errorf("after %d attempts: %w", apiAttempts, lastErr)
}

func retryableStatus(status int) bool {
	return status == http.StatusTooManyRequests || status >= 500
}

func (c *cfClient) attempt(ctx context.Context, method, path string, payload []byte) (json.RawMessage, time.Duration, error) {
	var rdr io.Reader
	if payload != nil {
		rdr = bytes.NewReader(payload)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, rdr)
	if err != nil {
		return nil, 0, fmt.Errorf("build %s %s: %w", method, path, err)
	}
	req.Header.Set("Authorization", "Bearer "+c.token)
	req.Header.Set("Accept", "application/json")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		// A transport error has no status; report it as a 503 so the retry
		// logic treats a dropped connection like a transient server failure.
		return nil, 0, &apiError{method: method, path: path, status: http.StatusServiceUnavailable, message: err.Error()}
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if err != nil {
		return nil, 0, &apiError{method: method, path: path, status: http.StatusServiceUnavailable, message: "read body: " + err.Error()}
	}
	retryAfter := parseRetryAfter(resp.Header.Get("Retry-After"))

	var env struct {
		Success bool `json:"success"`
		Errors  []struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"errors"`
		Result json.RawMessage `json:"result"`
	}
	// A non-JSON body (an edge error page, say) still has to produce a usable
	// error rather than a decode failure that hides the status.
	decoded := json.Unmarshal(raw, &env) == nil

	if resp.StatusCode >= 400 || !decoded || !env.Success {
		ae := &apiError{method: method, path: path, status: resp.StatusCode}
		if ae.status < 400 {
			ae.status = http.StatusBadGateway
		}
		var parts []string
		for _, e := range env.Errors {
			parts = append(parts, fmt.Sprintf("%d %s", e.Code, e.Message))
		}
		if len(parts) == 0 {
			parts = append(parts, strings.TrimSpace(truncate(string(raw), 300)))
		}
		ae.message = strings.Join(parts, "; ")
		return nil, retryAfter, ae
	}
	return env.Result, retryAfter, nil
}

func parseRetryAfter(v string) time.Duration {
	if v == "" {
		return 0
	}
	if secs, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && secs > 0 {
		return time.Duration(secs) * time.Second
	}
	return 0
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}
