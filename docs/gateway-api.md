# Cluster routing: Gateway API

App and infra routes are **Gateway API** objects (`HTTPRoute`), served by the
Traefik that K3s bundles. Traefik v3 is a native Gateway controller — no extra
component.

```
HTTPRoute (app namespace)  ──parentRef──▶  Gateway "traefik-gateway" (kube-system)
                                              │  listener "web"  HTTP :8000
                                              ▼
                                           Traefik  ──▶  Service ──▶ Pods
```

## What provides what

| Piece | Source | Notes |
|---|---|---|
| Gateway API CRDs (`v1.5.1`, standard channel) | **K3s** — its `traefik-crd` Helm release | `helm.sh/resource-policy: keep`, version-locked to the bundled Traefik. We don't install or pin them. |
| `GatewayClass` `traefik` | Traefik chart | controller `traefik.io/gateway-controller`; created because `gatewayClass.enabled` + `providers.kubernetesGateway.enabled` |
| `Gateway` `traefik-gateway` in `kube-system` | Traefik chart | one HTTP listener on `:8000` (the `web` entrypoint), `allowedRoutes.namespaces.from: All` |
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

**Today (nginx-edge):** the host nginx terminates TLS and proxies plain HTTP to
Traefik. Nothing TLS-related in the cluster. See [`nginx-edge.md`](nginx-edge.md).

### TLS at the flip

When the cluster becomes the public edge, add an HTTPS listener to the Gateway
via the chart values:

```yaml
gateway:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  listeners:
    web:
      port: 8000
      protocol: HTTP
      namespacePolicy: { from: All }
    websecure:
      port: 8443                    # the `websecure` entrypoint
      protocol: HTTPS
      namespacePolicy: { from: All }
      certificateRefs:
        - name: homelab-gateway-tls  # cert-manager creates/fills this Secret
```

cert-manager (with the Gateway annotation) provisions the cert into that Secret.
Its HTTP-01 solver still creates a temporary **Ingress**, which Traefik's Ingress
provider serves — that provider stays enabled for exactly this reason, so the
`ClusterIssuer` solver config in
[`../kubernetes/infrastructure/cert-manager/cluster-issuer.yaml`](../kubernetes/infrastructure/cert-manager/cluster-issuer.yaml)
needs no change.

Per-host certs instead of one SAN cert: give each `HTTPRoute` host its own
listener + `certificateRefs`, or attach a `Certificate` resource per host.
