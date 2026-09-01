# infrastructure/

Cluster-wide platform services. Applied by
[`../bootstrap.sh`](../bootstrap.sh) in dependency order.

| Component | What it is | Notes |
|---|---|---|
| `traefik/` | `HelmChartConfig` for the Traefik **bundled with K3s** | Turns on the **Gateway API** provider (chart creates `GatewayClass traefik` + `Gateway traefik-gateway`); routes are `HTTPRoute`s — see [`docs/gateway-api.md`](../../docs/gateway-api.md). Also **`service.spec.type: ClusterIP`, ClusterIP pinned to `10.43.66.94`**: the host nginx is the public edge and reverse-proxies `*.homelab.sthomas.ch` there (the VM already runs nginx + certbot for other sites) — [`docs/nginx-edge.md`](../../docs/nginx-edge.md), incl. the flip to Traefik-as-edge. Never `disable: traefik` in the K3s config. |
| `cert-manager/` | Let's Encrypt `ClusterIssuer`s (`letsencrypt-prod`, `letsencrypt-staging`) | Installed and running, but **currently inert** — the host certbot issues the public certs (nginx-edge mode). Live at the flip. HTTP-01 solver uses a temporary Ingress (Traefik keeps its Ingress provider on for this); per-host (no wildcard). |
| `cloudnative-pg/` | `ClusterImageCatalog` (`postgresql-minimal-trixie`, PG 17 + 18) | Operator from pinned upstream manifest. PG 18 entry carries `postgis` / `pgvector` / `pgaudit` / `timescaledb-oss` as extension images. No backups configured. |
| `headscale/` | Headscale control server + Headplane web UI | Single `headscale` namespace, pinned to the VPS. See [`headscale/README.md`](headscale/README.md). |
| `monitoring/` | VictoriaMetrics + VictoriaLogs + Grafana | The lightweight kube-prometheus-stack equivalent, installed via two K3s `HelmChart` CRs (helm-controller, no `helm` CLI). Grafana at `grafana.homelab.sthomas.ch`. See [`monitoring/README.md`](monitoring/README.md). |

### Adding a new infrastructure component

Create `infrastructure/<name>/kustomization.yaml`. If it needs an ordered apply
or a `kubectl wait`, add a step to `../bootstrap.sh`. Otherwise `bootstrap.sh`
only applies the dirs above explicitly — a bare new dir needs a line there
(or fold it into an existing one).

Expose it over HTTP with an `HTTPRoute` (`parentRefs` → `traefik-gateway` in
`kube-system`), like `headscale/httproute.yaml`.
