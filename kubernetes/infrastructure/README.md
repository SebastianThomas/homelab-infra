# infrastructure/

Cluster-wide platform services. Applied by
[`../bootstrap.sh`](../bootstrap.sh) in dependency order.

| Component | What it is | Notes |
|---|---|---|
| `traefik/` | `HelmChartConfig` for the Traefik **bundled with K3s** | **`service.spec.type: ClusterIP`, ClusterIP pinned to `10.43.66.94`** — the host nginx is the public edge and reverse-proxies `*.homelab.sthomas.ch` to that address (the VM already runs nginx + certbot for other sites). See [`docs/nginx-edge.md`](../../docs/nginx-edge.md), incl. the flip to Traefik-as-edge. Never `disable: traefik` in the K3s config. |
| `cert-manager/` | Let's Encrypt `ClusterIssuer`s (`letsencrypt-prod`, `letsencrypt-staging`) | Installed and running, but **certs are currently issued by the host certbot** (nginx-edge mode). The `tls:` + `cert-manager.io` annotations on Ingresses are inert until the flip. HTTP-01 via Traefik; per-host (no wildcard). |
| `cloudnative-pg/` | `ClusterImageCatalog` (`postgresql-minimal-trixie`, PG 17 + 18) | Operator from pinned upstream manifest. PG 18 entry carries `postgis` / `pgvector` / `pgaudit` / `timescaledb-oss` as extension images. No backups configured. |
| `headscale/` | Headscale control server + Headplane web UI | Single `headscale` namespace, pinned to the VPS. See [`headscale/README.md`](headscale/README.md). |

### Adding a new infrastructure component

Create `infrastructure/<name>/kustomization.yaml`. If it needs an ordered apply
or a `kubectl wait`, add a step to `../bootstrap.sh`. Otherwise `bootstrap.sh`
only applies the four dirs above explicitly — a bare new dir needs a line there
(or fold it into an existing one).
