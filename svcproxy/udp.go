package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

const (
	udpIdleTimeout = 30 * time.Second // DNS flows must comfortably fit inside this
	udpMaxSessions = 4096
	udpBufSize     = 64 * 1024 // larger than any IPv4 UDP payload, so never truncates
	udpSweepEvery  = 5 * time.Second
)

var errNoEndpoints = errors.New("no ready endpoints")

// udpForwarder proxies datagrams for one ClusterIP:port. Each client address
// is pinned to one backend via a connected UDP socket so request/response
// flows (DNS above all) stay coherent. Sessions expire after 30s idle, and
// the table is capped, evicting the least-recently-active session when full.
type udpForwarder struct {
	l    *proxyListener
	conn *net.UDPConn // the ClusterIP-bound socket; replies are written from it

	mu       sync.Mutex
	sessions map[string]*udpSession
}

type udpSession struct {
	key      string // client ip:port
	client   *net.UDPAddr
	backend  string
	upstream *net.UDPConn
	lastSeen atomic.Int64 // unix nanos
}

func (l *proxyListener) serveUDP(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var lc net.ListenConfig
	pc, err := lc.ListenPacket(ctx, "udp4", l.key.addr())
	if err != nil {
		return fmt.Errorf("bind: %w", err)
	}
	f := &udpForwarder{l: l, conn: pc.(*net.UDPConn), sessions: make(map[string]*udpSession)}
	l.udp.Store(f)
	defer l.udp.Store(nil)
	defer f.closeAll()
	defer f.conn.Close()
	defer context.AfterFunc(ctx, func() { f.conn.Close() })()
	go f.sweep(ctx)

	l.log.Info("listener started")
	buf := make([]byte, udpBufSize)
	for {
		n, caddr, err := f.conn.ReadFromUDP(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return fmt.Errorf("read: %w", err)
		}
		f.forward(buf[:n], caddr)
	}
}

func (f *udpForwarder) forward(pkt []byte, caddr *net.UDPAddr) {
	s, err := f.session(caddr)
	if err != nil {
		f.l.log.Debug("dropping datagram", "client", caddr.String(), "error", err)
		return
	}
	s.lastSeen.Store(time.Now().UnixNano())
	if _, err := s.upstream.Write(pkt); err != nil {
		f.drop(s) // the client's retransmit re-picks a backend
	}
}

// session returns the client's existing session or creates one pinned to the
// next round-robin backend.
func (f *udpForwarder) session(caddr *net.UDPAddr) (*udpSession, error) {
	key := caddr.String()
	f.mu.Lock()
	defer f.mu.Unlock()
	if s, ok := f.sessions[key]; ok {
		return s, nil
	}
	backend, ok := f.l.pool.pick()
	if !ok {
		return nil, errNoEndpoints
	}
	raddr, err := net.ResolveUDPAddr("udp4", backend)
	if err != nil {
		return nil, err
	}
	upstream, err := net.DialUDP("udp4", nil, raddr)
	if err != nil {
		return nil, err
	}
	if len(f.sessions) >= udpMaxSessions {
		f.evictOldestLocked()
	}
	s := &udpSession{key: key, client: caddr, backend: backend, upstream: upstream}
	s.lastSeen.Store(time.Now().UnixNano())
	f.sessions[key] = s
	go f.reply(s)
	return s, nil
}

// reply pumps backend responses back to the client. Replies are written from
// the ClusterIP-bound socket, so their source address is the service address.
func (f *udpForwarder) reply(s *udpSession) {
	buf := make([]byte, udpBufSize)
	for {
		n, err := s.upstream.Read(buf)
		if err != nil {
			f.drop(s) // idle sweep, prune, eviction, and socket errors all land here
			return
		}
		s.lastSeen.Store(time.Now().UnixNano())
		if _, err := f.conn.WriteToUDP(buf[:n], s.client); err != nil {
			f.drop(s)
			return
		}
	}
}

// drop removes and closes a session; safe to call more than once.
func (f *udpForwarder) drop(s *udpSession) {
	f.mu.Lock()
	if cur, ok := f.sessions[s.key]; ok && cur == s {
		delete(f.sessions, s.key)
	}
	f.mu.Unlock()
	s.upstream.Close()
}

func (f *udpForwarder) evictOldestLocked() {
	var oldest *udpSession
	for _, s := range f.sessions {
		if oldest == nil || s.lastSeen.Load() < oldest.lastSeen.Load() {
			oldest = s
		}
	}
	if oldest != nil {
		delete(f.sessions, oldest.key)
		oldest.upstream.Close()
	}
}

// sweep expires idle sessions.
func (f *udpForwarder) sweep(ctx context.Context) {
	tick := time.NewTicker(udpSweepEvery)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
		cutoff := time.Now().Add(-udpIdleTimeout).UnixNano()
		for _, s := range f.collect(func(s *udpSession) bool { return s.lastSeen.Load() < cutoff }) {
			s.upstream.Close()
		}
	}
}

// prune drops sessions pinned to backends that are no longer ready.
func (f *udpForwarder) prune(backends []string) {
	keep := make(map[string]bool, len(backends))
	for _, b := range backends {
		keep[b] = true
	}
	dropped := f.collect(func(s *udpSession) bool { return !keep[s.backend] })
	for _, s := range dropped {
		s.upstream.Close()
	}
	if len(dropped) > 0 {
		f.l.log.Debug("dropped UDP sessions to removed backends", "count", len(dropped))
	}
}

func (f *udpForwarder) closeAll() {
	for _, s := range f.collect(func(*udpSession) bool { return true }) {
		s.upstream.Close()
	}
}

// collect removes and returns all sessions matching the predicate.
func (f *udpForwarder) collect(match func(*udpSession) bool) []*udpSession {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []*udpSession
	for k, s := range f.sessions {
		if match(s) {
			delete(f.sessions, k)
			out = append(out, s)
		}
	}
	return out
}
