// kubeflare-svcproxy is a userspace ClusterIP service proxy: a kube-proxy
// replacement for kernels that cannot run any kube-proxy mode (missing
// xt_statistic/xt_nfacct for iptables mode, missing nft numgen/reject for
// nftables mode, no IPVS, no BTF for CO-RE eBPF).
//
// It relies on the kernel's AnyIP trick — a route of type "local" for the
// service CIDR on lo — which makes every ClusterIP bindable with a plain
// bind(). One listener is kept per ClusterIP x service port x protocol, and
// bytes are proxied in userspace to ready pod endpoints.
//
// TODO: expose Prometheus metrics (listener count, UDP sessions, dial failures).
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

func main() {
	kubeconfig := flag.String("kubeconfig", "/etc/rancher/k3s/k3s.yaml", "kubeconfig with read access to Services and EndpointSlices")
	serviceCIDR := flag.String("service-cidr", "10.43.0.0/16", "service CIDR to install as an AnyIP local route on lo")
	setupRoute := flag.Bool("setup-route", true, "run 'ip route replace local <service-cidr> dev lo' at startup")
	resync := flag.Duration("resync", 0, "informer resync period (0: rely on watches)")
	verbose := flag.Bool("v", false, "verbose (debug) logging")
	flag.Parse()

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(log)

	if err := run(*kubeconfig, *serviceCIDR, *setupRoute, *resync, log); err != nil {
		log.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run(kubeconfig, serviceCIDR string, setupRoute bool, resync time.Duration, log *slog.Logger) error {
	prefix, err := netip.ParsePrefix(serviceCIDR)
	if err != nil {
		return fmt.Errorf("invalid --service-cidr %q: %w", serviceCIDR, err)
	}
	if setupRoute {
		// Deliberately not fatal: listeners retry binding every 15s, so a
		// route that shows up later (or was installed by hand) heals on its own.
		if err := installAnyIPRoute(prefix.String()); err != nil {
			log.Error("AnyIP route setup failed; ClusterIP binds will keep retrying",
				"cidr", prefix.String(), "error", err)
		} else {
			log.Info("AnyIP local route installed", "cidr", prefix.String(), "dev", "lo")
		}
	}

	// An unusable kubeconfig is the only fatal condition.
	cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return fmt.Errorf("load kubeconfig %s: %w", kubeconfig, err)
	}
	cfg.UserAgent = "kubeflare-svcproxy"
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return fmt.Errorf("build client from %s: %w", kubeconfig, err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	factory := informers.NewSharedInformerFactory(client, resync)
	ctrl, err := newController(factory, log)
	if err != nil {
		return err
	}
	factory.Start(ctx.Done())
	log.Info("waiting for informer caches to sync")
	if !cache.WaitForCacheSync(ctx.Done(), ctrl.synced...) {
		return nil // interrupted by a signal during startup: clean shutdown
	}
	log.Info("caches synced, reconciling service listeners", "service_cidr", prefix.String())
	ctrl.run(ctx) // blocks until a signal, then stops every listener
	log.Info("shutdown complete")
	return nil
}

// installAnyIPRoute makes every address in the service CIDR locally bindable:
// a route of type "local" on lo tells the kernel to treat the whole prefix as
// host-local, so plain bind() works for any ClusterIP without configuring
// individual addresses. Shells out to `ip` on purpose — no netlink dependency.
func installAnyIPRoute(cidr string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ip", "route", "replace", "local", cidr, "dev", "lo").CombinedOutput()
	if err != nil {
		if msg := strings.TrimSpace(string(out)); msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
		return err
	}
	return nil
}
