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
  K3S_TOKEN?: string;
  K3S_NODE_PASSWORD?: string;
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
    // ?token= is also accepted so the dashboard opens in a browser.
    const presented = bearer || url.searchParams.get("token") || "";
    if (!tokensMatch(presented, guard)) {
      return new Response("forbidden\n", { status: 403 });
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
