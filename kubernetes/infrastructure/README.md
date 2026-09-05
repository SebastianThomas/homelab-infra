# infrastructure/

Cluster-wide platform services. Applied by
[`../bootstrap.sh`](../bootstrap.sh) in dependency order.

| Component | What it is | Notes |
|---|---|---|
| `traefik/` | `HelmChartConfig` for the Traefik **bundled with K3s** | Turns on the **Gateway API** provider, Ingress provider off (chart creates `GatewayClass traefik` + `Gateway traefik-gateway`); routes are `HTTPRoute`s — see [`docs/gateway-api.md`](../../docs/gateway-api.md). **`service.spec.type: LoadBalancer`** → klipper binds the host's `:80`/`:443`: Traefik is the public edge, HTTP→HTTPS at the entrypoint. Never `disable: traefik` in the K3s config. |
| `cert-manager/` | Let's Encrypt `ClusterIssuer`s (`letsencrypt-prod` + `-staging`, both **DNS-01 via acme-dns**) + `gateway-certs.yaml` | Issues one **wildcard** `Certificate` (`gateway-tls`, `*.sthomas.ch` + `*.homelab.sthomas.ch`) that the Traefik `websecure` listener references. Every app hostname is one label deep, so a new app is covered with no cert work. `bootstrap.sh` installs cert-manager from pinned upstream, waits for the webhook, then applies this. |
| `cloudnative-pg/` | `ClusterImageCatalog` (`postgresql-minimal-trixie`, PG 17 + 18) | Operator from pinned upstream manifest. PG 18 entry carries `postgis` / `pgvector` / `pgaudit` / `timescaledb-oss` as extension images. No backups configured. |
| `headscale/` | Headscale control server + Headplane web UI | Single `headscale` namespace, pinned to the VPS. See [`headscale/README.md`](headscale/README.md). |
| `monitoring/` | VictoriaMetrics + VictoriaLogs + Grafana | The lightweight kube-prometheus-stack equivalent, installed via two K3s `HelmChart` CRs (helm-controller, no `helm` CLI). Grafana at `grafana.ts.homelab.sthomas.ch` — **tailnet-only**, a MagicDNS name with no public DNS record. See [`monitoring/README.md`](monitoring/README.md). |
| `app-deployer/` | one `app-deployer` SA + `ClusterRole` (namespace `ci`) | The shared identity every app repo deploys itself with — its token is `KUBE_TOKEN` for all of them. Scoped to app resources (Deployments/Services/HTTPRoutes/CNPG `Cluster`s/namespaced RBAC), not the platform. See [`../apps/README.md`](../apps/README.md). |

### Adding a new infrastructure component

Create `infrastructure/<name>/kustomization.yaml`. If it needs an ordered apply
or a `kubectl wait`, add a step to `../bootstrap.sh`. Otherwise `bootstrap.sh`
only applies the dirs above explicitly — a bare new dir needs a line there
(or fold it into an existing one).

Expose it over HTTP with an `HTTPRoute` (`parentRefs` → `traefik-gateway` in
`kube-system`), like `headscale/httproute.yaml`.
