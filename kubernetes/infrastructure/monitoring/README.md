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

`https://grafana.homelab.sthomas.ch` — the `grafana` `HTTPRoute` attaches to
`traefik-gateway` in `kube-system`; Traefik is the public edge. DNS is the
`*.homelab.sthomas.ch` wildcard, TLS is the cluster wildcard cert
(`gateway-tls`). Nothing per-app.

## Grafana admin login

Grafana keeps a **persistent DB** (`persistence: true`, a `local-path` PVC) so
anything created in the UI — dashboards, folders, service-account tokens,
annotations — survives restarts. Grafana bakes the admin login into that DB on
its **first** start and never re-reads it, so:

- **First ever start:** the admin login comes from the `grafana-admin` Secret
  (`admin-user` / `admin-password`).
- **Password change afterwards:** set `GRAFANA_ADMIN_PASSWORD` in the
  `production` GitHub Environment and run `deploy`. The workflow compares the
  Secret to the desired value and, **only if it changed**, updates the Secret
  and runs `grafana cli admin reset-admin-password` in the running pod — an
  in-place reset, no restart, nothing else touched. No change → the workflow
  does nothing to Grafana.
- **Local / no GH secret:** `bootstrap.sh` generates a random password once.
  Read it back:

  ```bash
  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

  To change it locally: recreate the Secret, then
  `kubectl -n monitoring exec deploy/victoria-metrics-k8s-stack-grafana -c grafana --
   grafana cli --homepath /usr/share/grafana admin reset-admin-password '<new>'`.

> Grafana locks an account for ~5 min after 5 failed logins
> (`too many consecutive incorrect login attempts`) — the lock lives in the DB,
> so wait it out (a restart won't clear it).

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
