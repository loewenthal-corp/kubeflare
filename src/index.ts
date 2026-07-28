import { Container, getContainer } from "@cloudflare/containers";

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
    // The original Request object is forwarded untouched: building a new one
    // would drop the Upgrade handling that exec/attach/port-forward need. The
    // container runs `kubectl proxy --api-prefix=/k8s/` so no path rewrite is
    // required here.
    if (url.pathname === "/k8s" || url.pathname.startsWith("/k8s/")) {
      return container.containerFetch(request, KUBE_PROXY_PORT);
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
