# Cluster routing: Gateway API

App and infra routes are **Gateway API** objects (`HTTPRoute`), served by the
Traefik that K3s bundles. Traefik v3 is a native Gateway controller — no extra
component.

```
Internet :80/:443 ─klipper─▶ Traefik (LoadBalancer, the public edge)
                                 ▲
HTTPRoute (app namespace) ─parentRef─▶ Gateway "traefik-gateway" (kube-system)
                                         listener "web"       HTTP  :8000 → redirects to
                                         listener "websecure" HTTPS :8443 (wildcard cert)
                                 ▼
                              Service ──▶ Pods
```

## What provides what

| Piece | Source | Notes |
|---|---|---|
| Gateway API CRDs (`v1.5.1`, standard channel) | **K3s** — its `traefik-crd` Helm release | `helm.sh/resource-policy: keep`, version-locked to the bundled Traefik. We don't install or pin them. |
| `GatewayClass` `traefik` | Traefik chart | controller `traefik.io/gateway-controller`; created because `gatewayClass.enabled` + `providers.kubernetesGateway.enabled` |
| `Gateway` `traefik-gateway` in `kube-system` | Traefik chart | listeners `web` (HTTP `:8000`, redirects to HTTPS) + `websecure` (HTTPS `:8443`, wildcard `certificateRefs`), both `allowedRoutes.namespaces.from: All` |
| `HTTPRoute`s | this repo | `infrastructure/headscale/httproute.yaml`, `apps/<name>/httproute.yaml` |

All of the Traefik config is in
[`../kubernetes/infrastructure/traefik/helmchartconfig.yaml`](../kubernetes/infrastructure/traefik/helmchartconfig.yaml).

Standard channel = `HTTPRoute`, `GRPCRoute`, `ReferenceGrant`, `BackendTLSPolicy`.
**No `TCPRoute`/`UDPRoute`** (experimental channel — not installed). Headscale is
HTTP, so this is not a limitation today; if a raw-TCP service ever needs it,
install the experimental CRD set separately and add a `tcp`/matching entrypoint.

## Writing an HTTPRoute

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: myapp
  namespace: myapp
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: kube-system      # the Gateway is cluster-shared, in kube-system
  hostnames:
    - myapp.homelab.sthomas.ch
  rules:
    - backendRefs:
        - name: myapp              # Service in the same namespace as the route
          port: 80
```

- **Cross-namespace:** the route lives in the app namespace and points at the
  `kube-system` Gateway. The listener's `from: All` permits it. `backendRefs` in
  the *same* namespace as the route need no `ReferenceGrant`.
- **Path routing:** add `matches: [{ path: { type: PathPrefix, value: /admin } }]`.
  A more specific path wins regardless of rule order (see the headscale route).
- **Headers / rewrites / redirects:** `filters:` on a rule (Gateway API native).
  Traefik-specific knobs go on a `Middleware` referenced via an
  `ExtensionRef` filter.
- No `ingressClassName`, no `cert-manager.io` annotation, no `tls:` block on the
  route — TLS is a *listener* concern (below).

Check it attached:

```bash
kubectl -n myapp get httproute myapp \
  -o jsonpath='{.status.parents[0].conditions[*].type}={.status.parents[0].conditions[*].status}{"\n"}'
# Accepted=True ResolvedRefs=True
```

## TLS

**Nothing per app.** The `websecure` listener serves one cert-manager
**wildcard** cert (`gateway-tls`: `sthomas.ch`, `*.sthomas.ch`,
`*.homelab.sthomas.ch`, plus a `*.<zone>` line per app that needs a two-label
name — the current list is in `gateway-certs.yaml`), issued via **DNS-01 /
acme-dns**. Any new `HTTPRoute` hostname under a covered zone is already valid —
no cert edit, no listener change.

- Traefik's Gateway API provider is `certificateRefs`-only (no per-route ACME,
  no entrypoint `certResolver` — the router's `tls` section from the listener
  overrides it). So the wildcard on the shared listener is how every route gets
  TLS.
- DNS-01 (not HTTP-01) because only DNS-01 can issue `*.example.com`. `sthomas.ch`
  DNS stays at wint.global; just the `_acme-challenge.<zone>` names are
  CNAME-delegated to per-zone accounts on `auth.acme-dns.io`. Config:
  [`../kubernetes/infrastructure/cert-manager/`](../kubernetes/infrastructure/cert-manager/).
- A future app that needs a **two-label** subdomain (`x.y.sthomas.ch`) needs a
  `*.y.sthomas.ch` line in `gateway-certs.yaml` + one acme-dns delegation for
  `_acme-challenge.y.sthomas.ch`. One-label names never need anything. Delegate
  first, then deploy the cert change: a name-list change re-orders the whole
  cert, and a failing order leaves the last good one serving but not renewing.
- Tailnet-only names are **not** on this cert — they are served off the public
  edge entirely (below).

## Tailnet-only services

Some things should not be on the public edge at all — Grafana is the first.
**They do not get an `HTTPRoute`.** The workload's pod runs a `tailscale`
container and joins the tailnet as its own node, so MagicDNS
(`<name>.ts.homelab.sthomas.ch`) resolves to *that pod's* `100.64.0.0/10`
address and the only way in is a WireGuard session. Nothing is published on
:80/:443, and the pod terminates its own TLS (its own cert-manager cert for
`*.ts.homelab.sthomas.ch`, not `gateway-tls`). Worked example:
[`../kubernetes/infrastructure/monitoring/tailnet-ingress.yaml`](../kubernetes/infrastructure/monitoring/tailnet-ingress.yaml).

Three Traefik-side approaches look easier and all of them fail:

| Approach | Why it fails |
|---|---|
| An `HTTPRoute` on a tailnet-only hostname | Obscurity only. Traefik terminates :443 on the public IP and matches on `Host`; anyone who knows the name reaches it. The name is not even secret — Let's Encrypt publishes every issued name to the CT logs. |
| A source-IP allowlist (`ipAllowList` middleware) | Traefik cannot tell the two apart. K3s's klipper (ServiceLB) SNATs every client to the node CNI address before the request reaches Traefik, so tailnet and public traffic share one source IP. |
| A listener bound to the node's tailnet IP | Two independent blockers: the Traefik chart threads `ports.*.hostIP` into the entrypoint's **bind** address (Traefik would listen on the pod's loopback and nothing reaches it), and a `hostPort` on `100.64.0.2:443` is unschedulable anyway — klipper's svclb holds `0.0.0.0:443`, which the scheduler treats as conflicting with every IP on that port. |

The node's own tailnet IP is not a way out of this: klipper's DNAT for `:443`
matches on port regardless of destination address, so even a host process bound
to `100.64.0.2:443` never sees the packets. A separate tailnet IP — one per
workload — is what makes the split real.
