#!/usr/bin/env python3
"""Status/dashboard server for the kubeflare container.

Binds :8080 immediately and stays up regardless of what k3s is doing — a failing
kubectl call must never take the port down, because Cloudflare uses defaultPort
readiness to decide whether the container is healthy.
"""
import html
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote

LOG_DIR = "/var/log/kubeflare"
K3S = "/usr/local/bin/k3s"
ENV = {**os.environ, "KUBECONFIG": "/etc/rancher/k3s/k3s.yaml"}


def redact(text: str) -> str:
    """Strip anything secret-shaped before it reaches a response body.

    The process table shows cloudflared's full argv, which contains the tunnel
    token. This endpoint is reachable from the internet through the Worker, so
    nothing secret may pass through here.

    JuiceFS adds no new secret names — it reuses the litestream credentials — but
    /logs/juicefs echoes the volume's bucket URL, which is R2_ENDPOINT plus a
    bucket name. R2_ENDPOINT being in this list is what keeps the account id out
    of that.
    """
    for var in (
        "TUNNEL_TOKEN",
        "KUBE_GUARD",
        "K3S_TOKEN",
        "K3S_NODE_PASSWORD",
        "LITESTREAM_ACCESS_KEY_ID",
        "LITESTREAM_SECRET_ACCESS_KEY",
        "R2_ENDPOINT",
    ):
        val = os.environ.get(var)
        if val and len(val) > 6:
            text = text.replace(val, f"<{var}:REDACTED>")
    # Belt and braces: catch the token even if it reached us some other way.
    text = re.sub(r"--token[= ]\S+", "--token <REDACTED>", text)
    return text


def run(cmd, timeout=20):
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout, env=ENV)
        return redact((p.stdout + p.stderr).strip()) or "(no output)"
    except subprocess.TimeoutExpired:
        return f"(timed out after {timeout}s)"
    except Exception as exc:  # noqa: BLE001 - surface anything to the dashboard
        return f"(error: {exc})"


def tail(path, n=200):
    try:
        with open(path, errors="replace") as fh:
            return "".join(fh.readlines()[-n:]) or "(empty)"
    except FileNotFoundError:
        return "(no such file)"


PANELS = [
    ("readyz", f"{K3S} kubectl get --raw /readyz"),
    ("nodes", f"{K3S} kubectl get nodes -o wide"),
    ("pods (all namespaces)", f"{K3S} kubectl get pods -A -o wide"),
    ("deployments", f"{K3S} kubectl get deploy -A"),
    # juicefs-r2 appears here only when the JuiceFS mount came up; see
    # /manifests-optional in entrypoint.sh.
    ("storage", f"{K3S} kubectl get storageclass; {K3S} kubectl get pvc -A"),
    ("k3s version", f"{K3S} --version"),
    ("processes", "ps -eo pid,comm,args --sort=pid | head -40"),
    ("uname", "uname -a"),
    ("capabilities", "grep CapEff /proc/self/status"),
    ("cgroup controllers", "cat /sys/fs/cgroup/cgroup.controllers"),
    ("memory", "free -m"),
    ("disk", "df -h /"),
]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, body: bytes, ctype="text/plain; charset=utf-8", code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802 - stdlib API
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path == "/healthz":
            return self._send(b"ok\n")

        if path.startswith("/logs"):
            name = path[len("/logs"):].lstrip("/") or "k3s"
            safe = os.path.basename(name)
            if not safe.endswith(".log"):
                safe += ".log"
            return self._send(tail(os.path.join(LOG_DIR, safe), 400).encode())

        if path == "/diag":
            # Fixed battery — no user input reaches the shell.
            checks = [
                ("bridge sysctls", "sysctl net.bridge 2>&1 | head -20"),
                ("br_netfilter in kernel", "grep -c bridge /proc/modules; ls /sys/module/ | grep -i br_netfilter"),
                ("ip addr", "ip -br addr"),
                ("ip route", "ip route"),
                ("cni0 bridge", "ip -d link show cni0 2>&1"),
                ("nat table (KUBE-SERVICES)", "iptables -t nat -S 2>&1 | grep -i kube-services | head -20"),
                ("nat table counts", "iptables -t nat -S 2>&1 | wc -l"),
                ("filter FORWARD policy", "iptables -S FORWARD 2>&1 | head -10"),
                ("conntrack max", "cat /proc/sys/net/netfilter/nf_conntrack_max 2>&1"),
                ("iptables-restore failure (full)",
                 f"grep -A30 'Failed to execute iptables-restore' {LOG_DIR}/k3s.log | head -45"),
                ("iptables backend", "iptables --version; update-alternatives --display iptables 2>&1 | head -5"),
                ("k3s bundled net bins",
                 "ls /var/lib/rancher/k3s/data/*/bin/ 2>/dev/null | grep -iE 'iptables|nft|ipset' | sort -u | head -20"),
                ("system nft", "command -v nft; nft --version"),
                ("nft inet family works", "nft add table inet probetest 2>&1 && echo INET_TABLE_OK && nft delete table inet probetest"),
                ("nft kube-proxy table", "nft list table inet kube-proxy 2>&1 | head -5"),
                ("k3s PATH", "tr '\\0' '\\n' < /proc/24/environ 2>/dev/null | grep -E '^PATH=' | head -2"),
                ("nft ruleset size", "nft list ruleset 2>&1 | wc -l"),
                ("nat table full", "iptables -t nat -S 2>&1 | head -30"),
                # `juicefs status` is deliberately absent: it opens the metadata
                # URL, and the SQLite driver CREATES the file if it is missing —
                # an empty DB there would make the next boot skip both the
                # litestream restore and the format and come up with no
                # filesystem at all. Never point a juicefs subcommand at
                # sqlite3:///var/lib/kubeflare/jfs-meta.db by hand either.
                ("juicefs mount", "grep fuse /proc/self/mounts 2>&1 | head -5"),
                ("juicefs free space", "df -h /mnt/juicefs 2>&1"),
                ("juicefs metadata db", "ls -la /var/lib/kubeflare/ 2>&1 | head -10"),
                ("local kubectl exec (server-side)",
                 f"POD=$({K3S} kubectl get pod -l app=nginx -o jsonpath='{{.items[0].metadata.name}}'); "
                 f"{K3S} kubectl exec $POD -- sh -c 'hostname; echo SERVER_SIDE_EXEC_OK'"),
            ]
            out = []
            for title, cmd in checks:
                out.append(f"===== {title} =====\n{run(cmd, 30)}\n")
            return self._send("\n".join(out).encode())

        if path == "/kubeconfig":
            # The cluster's own kubeconfig, with the real client certificates and
            # the server rewritten to 127.0.0.1 for use behind `cloudflared access
            # tcp` (see docs/TUNNEL.md). This is cluster-admin, but reaching this
            # endpoint already requires the guard token, which grants the same via
            # /k8s — so it confers no additional privilege.
            # k3s already writes it pointing at https://127.0.0.1:6443, which is
            # exactly where the local end of the tunnel listens.
            cfg = run("cat /etc/rancher/k3s/k3s.yaml", 10)
            return self._send(cfg.encode(), "application/yaml; charset=utf-8")

        if path == "/nodes":
            return self._send(run(f"{K3S} kubectl get nodes -o wide").encode())
        if path == "/pods":
            return self._send(run(f"{K3S} kubectl get pods -A -o wide").encode())
        if path == "/readyz":
            return self._send(run(f"{K3S} kubectl get --raw /readyz").encode())

        # Default: the whole dashboard.
        #
        # Every nav link has to carry ?token= forward. The Worker gates all of
        # these paths, and a browser sends no Authorization header — so a bare
        # href like /logs/k3s arrives unauthenticated and gets a 403.
        token = ""
        if "?" in self.path:
            token = parse_qs(self.path.split("?", 1)[1]).get("token", [""])[0]
        q = f"?token={quote(token)}" if token else ""

        def nav(href: str, label: str) -> str:
            return f"<a href='{html.escape(href + q, quote=True)}'>{html.escape(label)}</a>"

        links = " &middot; ".join([
            nav("/logs/k3s", "k3s log"),
            nav("/logs/entrypoint", "entrypoint log"),
            nav("/logs/kubectl-proxy", "kubectl proxy log"),
            nav("/logs/cloudflared", "cloudflared log"),
            nav("/logs/manifests", "manifests log"),
            nav("/logs/juicefs", "juicefs log"),
            nav("/diag", "diagnostics"),
            nav("/nodes", "nodes"),
            nav("/pods", "pods"),
        ])

        parts = [
            "<!doctype html><meta charset=utf-8>",
            "<title>kubeflare</title>",
            "<style>body{font:13px ui-monospace,Menlo,monospace;margin:2rem;"
            "background:#0b0d10;color:#d6deeb}h1{font-size:1.1rem}"
            "h2{font-size:.85rem;color:#7fdbca;margin:1.4rem 0 .3rem;"
            "text-transform:uppercase;letter-spacing:.08em}"
            "pre{background:#11151a;padding:.7rem .9rem;border-radius:6px;"
            "overflow-x:auto;border:1px solid #1d2530}"
            "a{color:#82aaff}</style>",
            "<h1>Kubernetes on Cloudflare Containers "
            "<span style='color:#637777'>&mdash; kubeflare</span></h1>",
            f"<p>{links}</p>",
        ]
        for title, cmd in PANELS:
            parts.append(f"<h2>{html.escape(title)}</h2>")
            parts.append(f"<pre>{html.escape(run(cmd))}</pre>")
        return self._send("\n".join(parts).encode(), "text/html; charset=utf-8")

    def log_message(self, *_args):  # silence per-request stderr spam
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
