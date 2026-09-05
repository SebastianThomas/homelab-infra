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

## Access — tailnet only, enforced

**`https://grafana.ts.homelab.sthomas.ch` — only from a machine on the Headscale
tailnet.** Not "hidden": there is no public route to Grafana and no port on the
VPS that leads to it.

`grafana.ts.homelab.sthomas.ch` is not a DNS record. The `grafana-tailnet` pod
([`tailnet-ingress.yaml`](tailnet-ingress.yaml)) **is a Tailscale node**: it
registers with Headscale as `grafana`, MagicDNS answers with that node's own
`100.64.0.0/10` address, and traffic to it is WireGuard, decrypted inside the
pod. Two containers:

| Container | Job |
|---|---|
| `tailscale` | joins the tailnet (pre-auth key + a 128Mi state PVC), DNATs everything arriving on its tailnet IP to `$POD_IP` |
| `tls` | nginx: terminates `*.ts.homelab.sthomas.ch` ([`tailnet-certificate.yaml`](tailnet-certificate.yaml)), proxies to the chart's Grafana Service, keeps the WebSocket upgrade for Grafana Live |

The pod has **no Service, no hostPort and no HTTPRoute** — the tailnet IP is its
only address. Grafana's own `root_url` matches, so alert and share links point
at the same name.

### Why not Traefik + an allowlist?

Three dead ends, each fatal on its own — the reasoning is in
[`docs/gateway-api.md`](../../../docs/gateway-api.md#tailnet-only-services):

1. **A tailnet hostname on the shared Gateway is obscurity, not access
   control.** Traefik terminates :443 on the public IP; anyone who knows the
   name can send it as a `Host` header. (And Let's Encrypt publishes every
   issued name to the CT logs, so the name is not a secret.)
2. **A source-IP allowlist cannot work.** K3s's klipper SNATs every client to
   the node CNI address before Traefik sees it, so tailnet and public traffic
   arrive from the same IP.
3. **A listener bound to the tailnet IP cannot be built here.** The Traefik
   chart threads `ports.*.hostIP` into the entrypoint's *bind* address (it ends
   up on the pod's loopback), and a `hostPort` on `100.64.0.2:443` is
   unschedulable regardless — klipper's svclb already holds `0.0.0.0:443`, which
   the scheduler counts as a conflict with every IP on that port.

Giving the workload its own tailnet IP sidesteps all three.

### First run

The pod needs a Headscale pre-auth key in `monitoring/grafana-tailnet-authkey`
(see [`grafana-tailnet-authkey.example.yaml`](grafana-tailnet-authkey.example.yaml)).
`deploy` writes it from the `TS_AUTHKEY_GRAFANA` Environment secret; locally,
create it before applying. Issue it for the **`services`** user, not your own —
in-cluster nodes are kept in their own headscale user
([`../headscale/README.md`](../headscale/README.md#users-people-vs-service-nodes)).
**Reusable, not ephemeral**: an ephemeral node is deleted from headscale once it
disconnects.

```bash
kubectl -n headscale exec -i deploy/headscale -- headscale users create services
```

```bash
kubectl -n headscale exec -i deploy/headscale -- headscale preauthkeys create --user <ID> --reusable --expiration 8760h
```

The key is read **only at first registration**; afterwards the node key on the
`grafana-tailnet-state` PVC is what reconnects, so the key may expire or rotate
freely. cert-manager needs a minute or two for `grafana-ts-tls` on a fresh
cluster — until it exists the `tls` container restarts in a loop.

### When it doesn't resolve

```bash
kubectl -n monitoring logs deploy/grafana-tailnet -c tailscale
kubectl -n headscale exec -i deploy/headscale -- headscale nodes list
```

- `tailscale status` on your machine — are you on the homelab profile?
  (`tailscale debug prefs | grep -i controlurl`)
- A node named **`grafana-1`** in `headscale nodes list` means it re-registered
  while the old record still existed (state PVC wiped, or an ephemeral key was
  used). MagicDNS follows the new name — delete the stale node and restart the
  pod.
- Node present in `headscale nodes list` but connections hang: the DNAT rule is
  missing. `kubectl -n monitoring exec deploy/grafana-tailnet -c tailscale --
  iptables -t nat -S PREROUTING` should show a rule to the pod IP. If the logs
  mention userspace networking, tailscaled did not get `/dev/net/tun` and
  `TS_DEST_IP` is inert — check the hostPath mount.
- Off the tailnet entirely, there is no back door by design:
  `kubectl -n monitoring port-forward svc/victoria-metrics-k8s-stack-grafana 3000:80`.

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

- every component has explicit `resources` (whole stack ≈ 1–1.4 GiB working set,
  plus ~60 MiB for the `grafana-tailnet` pod);
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
