# infrastructure/

Cluster-wide platform services. Applied by
[`../bootstrap.sh`](../bootstrap.sh) in dependency order.

| Component | What it is | Notes |
|---|---|---|
| `traefik/` | `HelmChartConfig` that tunes the Traefik **bundled with K3s** | Disables the HTTPS responding-timeouts (Headscale's control stream is long-lived); best-effort real client IP. Do **not** `disable: traefik` in the K3s config. |
| `cert-manager/` | Let's Encrypt `ClusterIssuer`s (`letsencrypt-prod`, `letsencrypt-staging`) | HTTP-01 via Traefik. The operator itself is installed from its pinned upstream manifest by `bootstrap.sh`. Per-host certs (no wildcard — Strato has no ACME DNS API). |
| `cloudnative-pg/` | `ClusterImageCatalog` (`postgresql-minimal-trixie`, PG 17 + 18) | Operator from pinned upstream manifest. PG 18 entry carries `postgis` / `pgvector` / `pgaudit` / `timescaledb-oss` as extension images. No backups configured. |
| `headscale/` | Headscale control server + Headplane web UI | Single `headscale` namespace, pinned to the VPS. See [`headscale/README.md`](headscale/README.md). |

### Adding a new infrastructure component

Create `infrastructure/<name>/kustomization.yaml`. If it needs an ordered apply
or a `kubectl wait`, add a step to `../bootstrap.sh`. Otherwise `bootstrap.sh`
only applies the four dirs above explicitly — a bare new dir needs a line there
(or fold it into an existing one).
