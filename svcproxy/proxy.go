package main

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const (
	dialTimeout   = 5 * time.Second
	dialAttempts  = 3
	bindRetryWait = 15 * time.Second
)

// proxyKey identifies one listener: ClusterIP x service port x protocol.
type proxyKey struct {
	ip    string
	port  int32
	proto string // "TCP" or "UDP"
}

// addr is what gets passed to Listen. An empty ip yields ":30080", which Go
// binds on every address — that is how NodePort listeners are expressed.
func (k proxyKey) addr() string { return net.JoinHostPort(k.ip, strconv.Itoa(int(k.port))) }

func (k proxyKey) String() string {
	if k.ip == "" {
		return "*:" + strconv.Itoa(int(k.port)) + "/" + k.proto + " (nodePort)"
	}
	return k.addr() + "/" + k.proto
}

// endpointPool is an atomically swappable snapshot of ready backends, handed
// out round-robin. Accept loops read it lock-free; the controller swaps it on
// endpoint changes without disturbing the listener socket.
type endpointPool struct {
	eps atomic.Pointer[[]string]
	ctr atomic.Uint64
}

func (p *endpointPool) set(eps []string) { p.eps.Store(&eps) }

func (p *endpointPool) snapshot() []string {
	if v := p.eps.Load(); v != nil {
		return *v
	}
	return nil
}

// pick returns the next backend in round-robin order, false when none are ready.
func (p *endpointPool) pick() (string, bool) {
	eps := p.snapshot()
	if len(eps) == 0 {
		return "", false
	}
	return eps[(p.ctr.Add(1)-1)%uint64(len(eps))], true
}

// proxyListener serves one ClusterIP:port for one protocol. It retries
// binding forever: the bind can race the AnyIP route setup or collide with a
// host process on the same address, and neither may take the process down.
type proxyListener struct {
	key     proxyKey
	service string // namespace/name
	pool    endpointPool
	log     *slog.Logger
	udp     atomic.Pointer[udpForwarder] // set while a UDP socket is bound

	cancel context.CancelFunc
	done   chan struct{}
}

func startListener(ctx context.Context, key proxyKey, service string, endpoints []string, log *slog.Logger) *proxyListener {
	ctx, cancel := context.WithCancel(ctx)
	l := &proxyListener{
		key:     key,
		service: service,
		log:     log.With("service", service, "listener", key.String()),
		cancel:  cancel,
		done:    make(chan struct{}),
	}
	l.pool.set(endpoints)
	go l.run(ctx)
	return l
}

// stop shuts the listener down and waits for its serve loop to exit.
// Established TCP connections are left to drain on their own.
func (l *proxyListener) stop() {
	l.cancel()
	<-l.done
}

// setEndpoints atomically swaps the backend set without restarting the
// listener. UDP sessions pinned to a vanished backend are dropped so clients
// re-resolve to a live one instead of blackholing until idle expiry.
func (l *proxyListener) setEndpoints(eps []string) {
	l.pool.set(eps)
	if f := l.udp.Load(); f != nil {
		f.prune(eps)
	}
}

func (l *proxyListener) run(ctx context.Context) {
	defer close(l.done)
	defer l.log.Info("listener stopped")
	for {
		var err error
		if l.key.proto == "UDP" {
			err = l.serveUDP(ctx)
		} else {
			err = l.serveTCP(ctx)
		}
		if ctx.Err() != nil {
			return
		}
		l.log.Warn("listener error, will retry", "error", err, "retry_after", bindRetryWait)
		select {
		case <-ctx.Done():
			return
		case <-time.After(bindRetryWait):
		}
	}
}

func (l *proxyListener) serveTCP(ctx context.Context) error {
	var lc net.ListenConfig
	ln, err := lc.Listen(ctx, "tcp4", l.key.addr())
	if err != nil {
		return fmt.Errorf("bind: %w", err)
	}
	defer ln.Close()
	defer context.AfterFunc(ctx, func() { ln.Close() })()
	l.log.Info("listener started")
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("accept: %w", err)
		}
		go l.proxyTCP(conn.(*net.TCPConn))
	}
}

// proxyTCP splices one accepted connection to a ready backend with proper
// half-close propagation: a FIN from either side becomes CloseWrite on the
// other, and a mid-stream error tears both directions down.
func (l *proxyListener) proxyTCP(client *net.TCPConn) {
	defer client.Close()
	upstream := l.dialUpstream()
	if upstream == nil {
		return
	}
	defer upstream.Close()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); halfProxy(upstream, client) }()
	go func() { defer wg.Done(); halfProxy(client, upstream) }()
	wg.Wait()
}

func halfProxy(dst, src *net.TCPConn) {
	if _, err := io.Copy(dst, src); err != nil {
		// Read or write failed mid-stream: close both conns to unblock the
		// sibling copy. Double-close on the other path is harmless.
		src.Close()
		dst.Close()
		return
	}
	dst.CloseWrite() // clean EOF from src: propagate the half-close
}

// dialUpstream tries ready backends in round-robin order, moving to the next
// on dial failure, up to dialAttempts in total.
func (l *proxyListener) dialUpstream() *net.TCPConn {
	for i := 0; i < dialAttempts; i++ {
		backend, ok := l.pool.pick()
		if !ok {
			l.log.Debug("no ready endpoints, dropping connection")
			return nil
		}
		conn, err := net.DialTimeout("tcp4", backend, dialTimeout)
		if err != nil {
			l.log.Debug("backend dial failed", "backend", backend, "error", err)
			continue
		}
		return conn.(*net.TCPConn)
	}
	l.log.Warn("all backend dials failed, dropping connection", "attempts", dialAttempts)
	return nil
}
