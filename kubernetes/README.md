# kubernetes/

Everything that runs *on* the cluster. Ansible's job ends once K3s is up; from
here it's plain `kubectl` / Kustomize.

```
kubernetes/
├── bootstrap.sh          # ordered, idempotent apply of infrastructure/ + app scaffolding
├── infrastructure/       # cluster-wide platform services
│   ├── traefik/          # tunes the bundled K3s Traefik; enables the Gateway API provider
│   ├── cert-manager/     # Let's Encrypt ClusterIssuers (HTTP-01)
│   ├── cloudnative-pg/   # Postgres operator image catalog
│   └── headscale/        # Headscale control server + Headplane UI
└── apps/                 # platform side of each app (namespace/RBAC/db/HTTPRoute);
    ├── _template/        #   the Deployment+Service live in the app's own repo
    └── <name>/           # see apps/README.md
```

Node placement is a **namespace annotation**
(`scheduler.alpha.kubernetes.io/node-selector`) — the K3s server runs the
`PodNodeSelector` + `PodTolerationRestriction` admission plugins, so every pod
in a namespace (app Deployments *and* CloudNativePG) lands on the chosen node
with no per-workload config.

## Deploy

CI does this on every push to `main` that touches `kubernetes/**` (the
`deploy` workflow). Manually:

```bash
export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml
kubernetes/bootstrap.sh
```

`bootstrap.sh` applies, in order: Traefik config → cert-manager (pinned
upstream) + issuers → CloudNativePG (pinned upstream) + image catalog →
Headscale/Headplane → the platform side of every `apps/*/` (skips `apps/_*`).

Upstream operator versions are pinned at the top of `bootstrap.sh`
(`CERT_MANAGER_VERSION`, `CNPG_VERSION`) and bumped by Renovate.

## Where things go

| Kind of thing | Goes in |
|---|---|
| Gateway/Traefik tuning, TLS issuers, operators, cluster-wide policy | `infrastructure/` |
| An app's namespace / RBAC / database / `HTTPRoute` | `apps/<name>/` (this repo) |
| An app's `Deployment` / `Service` / released version | the **app's own repo** |

Apps are split across two repos so versions ship without a commit here — see
[`apps/README.md`](apps/README.md).
