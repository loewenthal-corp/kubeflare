import { Container, getContainer, switchPort } from "@cloudflare/containers";

/**
 * Durable Object that owns the single kubeflare container instance.
 *
 * sleepAfter is deliberately long. The container disk is ephemeral, so an
 * instance that sleeps takes the whole cluster with it and has to rebuild
 * (~90s) on the next request.
 */
export class KubeFlare extends Container<Env> {
  defaultPort = 8080;
  sleepAfter = "2h";
  enableInternet = true;

  envVars = {
    TUNNEL_TOKEN: this.env.TUNNEL_TOKEN ?? "",
    TUNNEL_HOSTNAME: this.env.TUNNEL_HOSTNAME ?? "",
    FLANNEL_BACKEND: this.env.FLANNEL_BACKEND ?? "host-gw",
    KUBE_PROXY_MODE: this.env.KUBE_PROXY_MODE ?? "nftables",
    // Durable state (litestream → R2). All-or-nothing: the entrypoint enables
    // replication only when every one of these is non-empty; otherwise the
    // cluster stays ephemeral. See scripts/deploy.sh for how they get set.
    LITESTREAM_ACCESS_KEY_ID: this.env.LITESTREAM_ACCESS_KEY_ID ?? "",
    LITESTREAM_SECRET_ACCESS_KEY: this.env.LITESTREAM_SECRET_ACCESS_KEY ?? "",
    R2_ENDPOINT: this.env.R2_ENDPOINT ?? "",
    R2_BUCKET: this.env.R2_BUCKET ?? "",
    K3S_TOKEN: this.env.K3S_TOKEN ?? "",
    K3S_NODE_PASSWORD: this.env.K3S_NODE_PASSWORD ?? "",
    // R2-backed pull-through image cache (the separate kubeflare-registry
    // Worker). Optional: without it containerd pulls straight from Docker Hub.
    REGISTRY_MIRROR_URL: this.env.REGISTRY_MIRROR_URL ?? "",
    REGISTRY_MIRROR_USERNAME: this.env.REGISTRY_MIRROR_USERNAME ?? "",
    REGISTRY_MIRROR_PASSWORD: this.env.REGISTRY_MIRROR_PASSWORD ?? "",
    // type: LoadBalancer via Cloudflare Tunnel hostnames. All-or-nothing: the
    // entrypoint starts lbcontroller only when the token and both ids are set.
    CLOUDFLARE_TUNNEL_API_TOKEN: this.env.CLOUDFLARE_TUNNEL_API_TOKEN ?? "",
    CF_ACCOUNT_ID: this.env.CF_ACCOUNT_ID ?? "",
    CF_ZONE_ID: this.env.CF_ZONE_ID ?? "",
    CF_TUNNEL_ID: this.env.CF_TUNNEL_ID ?? "",
    LB_HOSTNAME_SUFFIX: this.env.LB_HOSTNAME_SUFFIX ?? "",
    // R2-backed PersistentVolumes (JuiceFS → the juicefs-r2 StorageClass). Rides
    // on the credentials and endpoint above; this is just the data bucket, so it
    // is a plain var. Blank turns the feature off, and it is off anyway unless
    // durable state is on — the filesystem's metadata is a SQLite DB that only
    // litestream keeps alive across the ephemeral disk.
    R2_BUCKET_JFS: this.env.R2_BUCKET_JFS ?? "",
  };

  override onStart() {
    console.log("kubeflare container started");
  }
  override onStop(params: unknown) {
    console.log("kubeflare container stopped:", JSON.stringify(params));
  }
  override onError(error: unknown) {
    console.log("kubeflare container error:", String(error));
  }
}

interface Env {
  KUBEFLARE: DurableObjectNamespace<KubeFlare>;
  TUNNEL_TOKEN?: string;
  TUNNEL_HOSTNAME?: string;
  FLANNEL_BACKEND?: string;
  KUBE_PROXY_MODE?: string;
  KUBE_GUARD?: string;
  LITESTREAM_ACCESS_KEY_ID?: string;
  LITESTREAM_SECRET_ACCESS_KEY?: string;
  R2_ENDPOINT?: string;
  R2_BUCKET?: string;
  R2_BUCKET_JFS?: string;
  K3S_TOKEN?: string;
  K3S_NODE_PASSWORD?: string;
  REGISTRY_MIRROR_URL?: string;
  REGISTRY_MIRROR_USERNAME?: string;
  REGISTRY_MIRROR_PASSWORD?: string;
  CLOUDFLARE_TUNNEL_API_TOKEN?: string;
  CF_ACCOUNT_ID?: string;
  CF_ZONE_ID?: string;
  CF_TUNNEL_ID?: string;
  LB_HOSTNAME_SUFFIX?: string;
}

const INSTANCE = "main";
const STATUS_PORT = 8080;
const KUBE_PROXY_PORT = 8001;

/** Length-independent compare so the guard token is not probeable by timing. */
function tokensMatch(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Per-isolate auth-failure rate limiter. Not shared across Worker instances,
// but effective against any single isolate being hammered.
const AUTH_FAIL_WINDOW_MS = 5 * 60 * 1000; // 5 minutes
const AUTH_FAIL_LIMIT = 10;
const authFailures = new Map<string, { count: number; firstAttempt: number }>();

function checkRateLimit(ip: string): boolean {
  const now = Date.now();
  const entry = authFailures.get(ip);
  if (!entry || now - entry.firstAttempt > AUTH_FAIL_WINDOW_MS) {
    authFailures.set(ip, { count: 1, firstAttempt: now });
    return false;
  }
  entry.count += 1;
  return entry.count > AUTH_FAIL_LIMIT;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const container = getContainer(env.KUBEFLARE, INSTANCE);

    // Unauthenticated on purpose: reveals nothing, and it is how you wake a
    // sleeping instance before running kubectl.
    if (url.pathname === "/healthz" || url.pathname === "/_keepalive") {
      await container.startAndWaitForPorts({ ports: [STATUS_PORT] });
      return new Response("awake\n", { headers: { "content-type": "text/plain" } });
    }

    const guard = env.KUBE_GUARD;
    if (!guard) {
      return new Response(
        "KUBE_GUARD secret is not set. Run ./scripts/deploy.sh, or:\n" +
          "  openssl rand -hex 32 | npx wrangler secret put KUBE_GUARD\n",
        { status: 503, headers: { "content-type": "text/plain" } },
      );
    }

    const header = request.headers.get("Authorization") ?? "";
    const bearer = header.startsWith("Bearer ") ? header.slice(7) : "";
    // ?token= is only accepted for the dashboard root; browsers can't send
    // Authorization headers. All other paths require the Bearer header.
    const tokenParam = url.pathname === "/" ? url.searchParams.get("token") : null;
    const presented = bearer || tokenParam || "";
    if (!tokensMatch(presented, guard)) {
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      console.log(`auth failed: ${request.method} ${url.pathname}`);
      if (checkRateLimit(ip)) {
        return new Response("too many requests\n", { status: 429 });
      }
      return new Response("forbidden\n", { status: 403 });
    }

    // Expose a NodePort Service to the internet: /np/<nodePort>/<path...>
    //
    // NodePort is otherwise only half-implemented here. svcproxy binds the
    // allocated node port inside the container, which makes it correct for
    // in-cluster and host-local callers, but the platform accepts no inbound
    // TCP — so without this route nothing outside can ever reach it. Here the
    // Worker is the missing inbound path.
    //
    // The prefix is stripped, so the backend sees the path it expects. That
    // means building a new Request, which is exactly what drops connection
    // upgrade semantics — so this carries ordinary HTTP, not WebSockets. The
    // /k8s route deliberately avoids the rewrite for that reason.
    const np = url.pathname.match(/^\/np\/(\d+)(\/.*)?$/);
    if (np) {
      const port = Number(np[1]);
      // Only the NodePort range. Without this the route would be a generic
      // "reach any port in the container" primitive, which includes the
      // unauthenticated admin proxy on 8001.
      if (port < 30000 || port > 32767) {
        return new Response(
          `port ${port} is outside the NodePort range 30000-32767\n`,
          { status: 400, headers: { "content-type": "text/plain" } },
        );
      }
      const target = new URL(request.url);
      target.pathname = np[2] ?? "/";
      try {
        return await container.fetch(
          switchPort(new Request(target, request), port),
        );
      } catch (err) {
        console.log("nodeport passthrough error:", String(err));
        return new Response(
          `kubeflare: nothing is serving nodePort ${port}\n\n${String(err)}\n`,
          { status: 502, headers: { "content-type": "text/plain" } },
        );
      }
    }

    // Restart the container instance. Needed because envVars are read once, at
    // container start: changing a Worker secret (R2 credentials, tunnel token)
    // does NOT reach a running container, and a secret-only change does not
    // alter the image, so `wrangler deploy` triggers no container rollout
    // either. This is the supported way to pick up new secrets.
    //
    // Destroys the cluster unless durable state is on, so it is POST-only.
    if (url.pathname === "/admin/restart") {
      if (request.method !== "POST") {
        return new Response("POST required — this restarts the cluster\n", { status: 405 });
      }
      await container.destroy();
      return new Response(
        "container destroyed; it restarts on the next request (~90s to a ready cluster)\n",
        { headers: { "content-type": "text/plain" } },
      );
    }

    // Kubernetes API passthrough. kubectl points at <worker>/k8s and
    // authenticates with --token=$KUBE_GUARD; we forward to the container's
    // `kubectl proxy`, which holds the real cluster credentials.
    //
    // MUST go through the DO's fetch boundary (container.fetch + switchPort),
    // NOT containerFetch: containerFetch is a JSRPC method, and a Response
    // carrying a WebSocket cannot cross the RPC boundary — it throws
    // DataCloneError, which is exactly how kubectl exec/attach/port-forward
    // (WebSocket transport, default since kubectl 1.31) used to die here.
    // kubectl then silently falls back to SPDY, which the edge 400s, so the
    // real error never surfaced. switchPort only adds a header; the URL is
    // untouched, which `kubectl proxy --api-prefix=/k8s/` relies on.
    if (url.pathname === "/k8s" || url.pathname.startsWith("/k8s/")) {
      try {
        // Do NOT rebuild this Request. Rebuilding drops the connection-upgrade
        // semantics exec/attach/port-forward need — measured: kubectl exec
        // started returning HTML the moment this became
        // `new Request(request.url, request)`. The /np route can rebuild
        // because it only ever carries ordinary HTTP.
        //
        // If every API call suddenly returns the status dashboard, the cause is
        // NOT here: it is `kubectl proxy` having wedged inside the container, at
        // which point the DO falls back to defaultPort (8080). The entrypoint
        // now health-checks and restarts it.
        return await container.fetch(switchPort(request, KUBE_PROXY_PORT));
      } catch (err) {
        // Surface real errors instead of an opaque Cloudflare 1101 page.
        const e = err as Error;
        console.log("k8s passthrough error:", String(err), e?.stack ?? "");
        return new Response(`kubeflare: /k8s passthrough failed\n\n${String(err)}\n`, {
          status: 502,
          headers: { "content-type": "text/plain" },
        });
      }
    }

    try {
      return await container.fetch(request);
    } catch (err) {
      return new Response(
        `kubeflare: container unreachable\n\n${String(err)}\n\n` +
          `It may still be booting — the cluster takes ~90s from cold.\n` +
          `Retry, or hit /healthz to force a start.\n`,
        { status: 503, headers: { "content-type": "text/plain" } },
      );
    }
  },
};
