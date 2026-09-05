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
`*.homelab.sthomas.ch`, `*.ts.homelab.sthomas.ch`), issued via **DNS-01 /
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
  `_acme-challenge.y.sthomas.ch`. One-label names never need anything.
  `*.ts.homelab.sthomas.ch` (tailnet-only names, below) is such a case and is
  already on the cert. Delegate first, then deploy the cert change: a name-list
  change re-orders the whole cert, and a failing order leaves the last good one
  serving but not renewing.

## Tailnet-only routes

A route can be hidden from the internet by giving it a hostname that only exists
in the tailnet: a name under headscale's MagicDNS base domain
`ts.homelab.sthomas.ch`, backed by a static A record in
[`../kubernetes/infrastructure/headscale/files/extra-records.json`](../kubernetes/infrastructure/headscale/files/extra-records.json)
pointing at the node's tailnet IP (`100.64.0.2`). Grafana is the example:
`grafana.ts.homelab.sthomas.ch`. The `HTTPRoute` is otherwise completely
ordinary — same Gateway, same listener, same wildcard cert.

The hiding is **host-based**: Traefik still terminates :443 on the public IP and
would serve the route to anyone who sends that `Host` header. Source-IP
filtering is not an option — K3s's klipper SNATs every client to the node CNI
address, so Traefik sees one IP for tailnet and public traffic alike. Use it to
keep a service off public DNS and out of scanners, not as the only auth.
