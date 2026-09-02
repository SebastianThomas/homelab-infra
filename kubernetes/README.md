# kubernetes/

Everything that runs *on* the cluster. Ansible's job ends once K3s is up; from
here it's plain `kubectl` / Kustomize.

```
kubernetes/
├── bootstrap.sh          # ordered, idempotent apply of infrastructure/
├── infrastructure/       # cluster-wide platform services
│   ├── traefik/          # tunes the bundled K3s Traefik; enables the Gateway API provider
│   ├── cert-manager/     # Let's Encrypt ClusterIssuers + the DNS-01 wildcard cert
│   ├── cloudnative-pg/   # Postgres operator image catalog
│   ├── headscale/        # Headscale control server + Headplane UI
│   ├── monitoring/       # VictoriaMetrics + VictoriaLogs + Grafana
│   └── app-deployer/     # shared SA + ClusterRole every app repo deploys with
└── apps/
    └── _template/        # copy-paste source for an app repo's deploy/ - NOT applied here
```

Namespaces are **not pinned to a node**. Pods schedule wherever the cluster has
room, so adding a node lets it pick up work without editing every app repo.

Two things still constrain placement without any annotation:

- The Pi (`kube-worker-01`) carries `homelab.sthomas.ch/edge=true:NoSchedule`.
  Nothing tolerates it by default, so "unpinned" never means "might land on the
  Pi" — it has to be opted into explicitly.
- Anything with a `local-path` PVC is fixed to one node anyway: the PV carries
  `nodeAffinity` to whichever node first bound it.

To deliberately place a namespace **on** the Pi, set *both*
`scheduler.alpha.kubernetes.io/node-selector` and
`scheduler.alpha.kubernetes.io/defaultTolerations` (the K3s server runs the
`PodNodeSelector` + `PodTolerationRestriction` admission plugins). With only the
selector, pods stay `Pending` — see the root README, "Running a workload on the
Pi". Note the selector is enforced, not merged: a pod whose own `nodeSelector`
contradicts the namespace annotation is **rejected**, not just left unscheduled.

## Deploy

CI does this on every push to `main` that touches `kubernetes/**` (the
`deploy` workflow). Manually:

```bash
export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml
kubernetes/bootstrap.sh
```

`bootstrap.sh` applies, in order: Traefik config → cert-manager (pinned
upstream) + issuers → CloudNativePG (pinned upstream) + image catalog →
Headscale/Headplane → monitoring (VictoriaMetrics/Logs + Grafana) → the shared
app-deployer identity. It does **not** deploy apps - each app repo does that.

Upstream versions are pinned: operator manifests at the top of `bootstrap.sh`
(`CERT_MANAGER_VERSION`, `CNPG_VERSION`), Helm charts as `# renovate: chart=…`
comments in `infrastructure/monitoring/`. All bumped by Renovate.

## Where things go

| Kind of thing | Goes in |
|---|---|
| Gateway/Traefik tuning, TLS issuers, operators, cluster-wide policy | `infrastructure/` |
| **Anything** for a specific app (namespace, Deployment, Service, HTTPRoute, DB) | the **app's own repo** under `deploy/` |

homelab-infra knows nothing about individual apps — see
[`apps/README.md`](apps/README.md).
