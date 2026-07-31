// kubeflare-lbcontroller implements `type: LoadBalancer` on a cluster that has
// no cloud provider behind it. Every LoadBalancer Service is given a public
// hostname on the cluster's own Cloudflare Tunnel — an ingress rule plus a
// proxied CNAME — and the hostname is written back into
// .status.loadBalancer.ingress so `kubectl get svc` stops printing <pending>.
//
// It is a sibling of svcproxy and leans on it: cloudflared runs as a host
// process in the same network namespace as svcproxy's ClusterIP listeners, so
// an ingress rule can point straight at http://<clusterIP>:<port> and get
// userspace load balancing across ready endpoints for free.
//
// The hazard this binary exists to manage carefully is that the tunnel's
// ingress list is one document shared with the apiserver rule that carries all
// kubectl traffic, and the API replaces it wholesale on every write. See
// rebuildIngress.
//
// TODO: expose Prometheus metrics (published hostnames, Cloudflare API errors).
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
)

// tokenEnv is where the Cloudflare API token is read from. It is never a flag:
// on kubeflare it arrives as a Worker secret and a token on a command line
// would be visible in every ps listing inside the container.
const tokenEnv = "CLOUDFLARE_TUNNEL_API_TOKEN"

type options struct {
	kubeconfig string
	accountID  string
	zoneID     string
	tunnelID   string
	suffix     string
	dryRun     bool
	token      string
}

func main() {
	var o options
	flag.StringVar(&o.kubeconfig, "kubeconfig", "/etc/rancher/k3s/k3s.yaml", "kubeconfig with read/write access to Services and Service status")
	flag.StringVar(&o.accountID, "account-id", "", "Cloudflare account ID that owns the tunnel (required)")
	flag.StringVar(&o.zoneID, "zone-id", "", "Cloudflare zone ID the hostnames live in (required)")
	flag.StringVar(&o.tunnelID, "tunnel-id", "", "Cloudflare Tunnel ID to publish ingress rules on (required)")
	flag.StringVar(&o.suffix, "hostname-suffix", "lb.kubeflare.dev", "suffix for derived hostnames, <service>-<namespace>.<suffix>")
	flag.BoolVar(&o.dryRun, "dry-run", false, "compute and log everything, change nothing in Cloudflare or the cluster")
	verbose := flag.Bool("v", false, "verbose (debug) logging")
	flag.Parse()

	level := slog.LevelInfo
	if *verbose {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(log)

	o.token = os.Getenv(tokenEnv)
	if err := o.validate(); err != nil {
		log.Error("cannot start", "error", err)
		os.Exit(1)
	}
	if err := run(o, log); err != nil {
		log.Error("fatal", "error", err)
		os.Exit(1)
	}
}

// validate reports every missing or unusable input in one line, so a
// half-configured entrypoint does not have to be fixed one restart at a time.
// Configuration is the only fatal class of error in this binary; everything
// that happens after startup is retried.
func (o *options) validate() error {
	var missing []string
	if o.token == "" {
		missing = append(missing, "$"+tokenEnv)
	}
	for _, f := range []struct{ flag, value string }{
		{"--account-id", o.accountID},
		{"--zone-id", o.zoneID},
		{"--tunnel-id", o.tunnelID},
		{"--hostname-suffix", o.suffix},
	} {
		if strings.TrimSpace(f.value) == "" {
			missing = append(missing, f.flag)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("missing required configuration: %s", strings.Join(missing, ", "))
	}
	o.suffix = strings.ToLower(strings.Trim(strings.TrimSpace(o.suffix), "."))
	if !validDNSName(o.suffix) {
		return fmt.Errorf("--hostname-suffix %q is not a valid DNS name", o.suffix)
	}
	return nil
}

func run(o options, log *slog.Logger) error {
	// An unusable kubeconfig is the only fatal condition past startup checks.
	cfg, err := clientcmd.BuildConfigFromFlags("", o.kubeconfig)
	if err != nil {
		return fmt.Errorf("load kubeconfig %s: %w", o.kubeconfig, err)
	}
	cfg.UserAgent = "kubeflare-lbcontroller"
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return fmt.Errorf("build client from %s: %w", o.kubeconfig, err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	cf := newCFClient(defaultAPIBase, o.token, o.accountID, o.zoneID, o.tunnelID, o.dryRun, log)
	factory := informers.NewSharedInformerFactory(client, resyncPeriod)
	ctrl, err := newController(factory, client, cf, o.suffix, o.tunnelID, o.dryRun, log)
	if err != nil {
		return err
	}
	factory.Start(ctx.Done())
	log.Info("waiting for informer caches to sync")
	if !cache.WaitForCacheSync(ctx.Done(), ctrl.synced...) {
		return nil // interrupted by a signal during startup: clean shutdown
	}
	if o.dryRun {
		log.Warn("dry-run: no Cloudflare or cluster writes will be made")
	}
	log.Info("caches synced, reconciling LoadBalancer services",
		"tunnel", o.tunnelID, "zone", o.zoneID, "hostname_suffix", o.suffix)
	ctrl.run(ctx) // blocks until a signal
	log.Info("shutdown complete")
	return nil
}
