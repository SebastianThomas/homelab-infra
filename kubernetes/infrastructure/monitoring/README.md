# monitoring/

Metrics, logs and dashboards for the cluster, on the **VictoriaMetrics** stack
(the lightweight, drop-in alternative to kube-prometheus-stack).

| Piece | What | Notes |
|---|---|---|
| VM operator | `victoria-metrics-operator` | manages the CRs below; ships the `VM*` / `VL*` CRDs |
| `vmsingle` | metrics TSDB (Prometheus-compatible) | 15d retention, 15Gi local-path PVC |
| `vmagent` | scraper | discovers targets via `VMServiceScrape` / `VMNodeScrape` |
| `vmalert` + `vmalertmanager` | recording + alerting rules | Alertmanager runs with a **blackhole** receiver — alerts are visible in Grafana, nothing is paged. Add a receiver under `alertmanager.config` to change that. |
| `vlsingle` | **VictoriaLogs** — logs store | 15d retention, 15Gi local-path PVC |
| `victoria-logs-collector` | per-node log DaemonSet | tails container logs off `/var/log`, ships to `vlsingle` |
| kube-state-metrics, node-exporter | standard exporters | |
| Grafana | dashboards + explore | ~40 default dashboards; `VictoriaMetrics` (default), `VictoriaMetrics (DS)`, `VictoriaLogs (DS)` and `Alertmanager` datasources are pre-wired |

Both charts are installed through **K3s's in-cluster helm-controller** (the same
mechanism as the bundled Traefik) via the two `HelmChart` resources here — no
`helm` CLI in the pipeline. Chart versions are pinned and Renovate-tracked
(`# renovate: chart=…`).

## Access

`https://grafana.homelab.sthomas.ch` — the `grafana` `HTTPRoute` →
`traefik-gateway` → host nginx's `*.homelab.sthomas.ch` wildcard vhost
(nginx-edge mode). DNS is covered by the wildcard. The only per-app host step is
growing the shared cert:

```bash
sudo certbot certonly --nginx --cert-name homelab-cluster --expand \
  -d grafana.homelab.sthomas.ch   # + every other *.homelab name already on it
```

Full picture: [`../../../docs/nginx-edge.md`](../../../docs/nginx-edge.md).

## Grafana admin login

The `grafana-admin` Secret (`admin-user` / `admin-password`).

- **CI:** set `GRAFANA_ADMIN_PASSWORD` (and optionally `GRAFANA_ADMIN_USER`) in
  the `production` GitHub Environment. `deploy` creates the Secret before the
  chart runs.
- **Otherwise:** `bootstrap.sh` generates a random password once. Read it back:

  ```bash
  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

To set a specific password later: recreate the Secret and roll Grafana.

```bash
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password='...' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring rollout restart deploy/victoria-metrics-k8s-stack-grafana
```

## This is a small, shared node

`kube-cp-01` also runs ~13 legacy docker-compose sites (see
[`docs/…`](../../../README.md)); RAM is the tight resource. So:

- every component has explicit `resources` (whole stack ≈ 1–1.4 GiB working set);
- `vmsingle` / `vlsingle` retention is **15d**; bump in the `HelmChart` values if
  you have headroom;
- `vmsingle` runs with `-memory.allowedPercent=50` and
  `-search.maxConcurrentRequests=4`.

If Grafana or vmsingle get OOMKilled, raise their `limits.memory` in
[`helmchart-victoria-metrics.yaml`](helmchart-victoria-metrics.yaml).

## K3s specifics

`kube-controller-manager`, `kube-scheduler`, `kube-proxy` run inside the single
k3s process and aren't scrapable the standard way; there's no etcd (SQLite
datastore). Their scrapes **and** matching alert rules are disabled in the
values, so there are no permanently-down targets. `kubelet`, `cadvisor`,
`kube-apiserver` and CoreDNS are scraped normally.

## Debugging the install

```bash
kubectl -n monitoring get helmchart
kubectl -n monitoring logs job/helm-install-victoria-metrics-k8s-stack
kubectl -n monitoring get vmsingle,vlsingle,vmagent,vmalert,vmalertmanager
kubectl -n monitoring get vmservicescrape,vmnodescrape
```

vmagent's target health: `kubectl -n monitoring port-forward svc/vmagent-victoria-metrics-k8s-stack 8429` → `http://localhost:8429/targets`.

**Stuck helm release** (`helm-install-…` job loops on `cannot reuse a name that
is still in use`): a failed upgrade left a revision in `uninstalling`. The
workload keeps serving on the last good revision. Find and delete the stuck one:

```bash
kubectl -n monitoring get secret -l owner=helm,name=victoria-metrics-k8s-stack \
  -L status                                   # note the vN with status=uninstalling
kubectl -n monitoring delete secret sh.helm.release.v1.victoria-metrics-k8s-stack.vN
kubectl apply -k kubernetes/infrastructure/monitoring   # helm-controller re-runs, clean
```

## RPi worker (phase 2)

`node-exporter` and `victoria-logs-collector` are DaemonSets and will extend to
the Pi automatically (the `monitoring` namespace is intentionally not
node-pinned). `vmsingle` / `vlsingle` / Grafana stay on `kube-cp-01` (their
local-path PVCs are bound there).
