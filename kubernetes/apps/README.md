# apps/

An app is split across **two repos**:

| Side | Lives in | Owns | Changes |
|---|---|---|---|
| **Platform** | `homelab-infra/kubernetes/apps/<name>/` | namespace, node placement, RBAC (a `deployer` ServiceAccount), database, ingress | rarely — only when the app's *surroundings* change |
| **Workload** | the app's **own repo** (e.g. `SebastianThomas/<name>`) | `Deployment`, `Service`, app `ConfigMap`s | every release — the app repo deploys itself, pinning whatever version it wants |

So `homelab-infra` is **not** the source of truth for what version is running.
Bumping an app version is a release in the app repo — **zero commits here**.

> Was this possible before this split? No. The old layout pinned the image tag
> in `homelab-infra/kubernetes/apps/<name>/deployment.yaml`, so a new version
> meant editing + committing + pushing *this* repo.

## Platform side — one-time setup per app

```bash
cp -r kubernetes/apps/_template kubernetes/apps/myapp
grep -rl myapp kubernetes/apps/myapp | xargs sed -i '' 's/myapp/<name>/g'   # (Linux: sed -i)
# edit database.yaml (or delete it + its kustomization line)
```

The ingress host is `<name>.homelab.sthomas.ch` — already covered by the
`*.homelab.sthomas.ch` wildcard, so no DNS change (add a CNAME per app only if
you don't run a wildcard).

Commit + push → the `deploy` workflow applies the namespace, RBAC, DB and
ingress. Then hand the app repo its credentials (GitHub Environment / repo
secrets on the **app** repo):

```bash
export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml
kubectl -n <name> get secret deployer-token -o jsonpath='{.data.token}'  | base64 -d   # -> KUBE_TOKEN
kubectl -n <name> get secret deployer-token -o jsonpath='{.data.ca\.crt}'              # -> KUBE_CA
# KUBE_API = https://homelab.sthomas.ch:6443   (public :6443 open)
#   or, once :6443 is firewalled to the tailnet:
#     KUBE_API = https://kube-cp-01.ts.homelab.sthomas.ch:6443
#   + pass tailscale-authkey / headscale-url to deploy-to-k8s (see below)
```

The `deployer` SA is scoped to that one namespace.

## Workload side — in the app repo

```
<app-repo>/
├── deploy/
│   ├── deployment.yaml     # image: ${APP_IMAGE}   (placeholder, substituted at deploy time)
│   └── service.yaml        # name + selector must match; port 80
└── .github/workflows/release.yml
```

`deploy/deployment.yaml` — **no** nodeSelector/tolerations needed (the namespace
annotation pins it). Wire the DB from the operator-generated secret:

```yaml
        env:
          - name: DATABASE_URL
            valueFrom:
              secretKeyRef: { name: <name>-db-app, key: uri }
```

`.github/workflows/release.yml`:

```yaml
name: release
on:
  push:
    tags: ["v*"]          # deploy v1.2.3 by pushing tag v1.2.3
  workflow_dispatch:       # or redeploy any existing tag by hand (rollback)
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      # ... build + push ghcr.io/OWNER/<name>:${{ github.ref_name }} ...
      - uses: SebastianThomas/homelab-infra/.github/actions/deploy-to-k8s@main
        with:
          app: <name>
          image: ghcr.io/OWNER/<name>:${{ github.ref_name }}
          kube-api: ${{ secrets.KUBE_API }}
          kube-ca: ${{ secrets.KUBE_CA }}
          kube-token: ${{ secrets.KUBE_TOKEN }}
```

(For the composite action to be reachable from a **private** app repo, enable it
under `homelab-infra` → Settings → Actions → "Accessible from repositories owned
by the user". Public repos need nothing.)

## Versioning & rollback

- **Deploy a version:** push tag `v1.2.3` in the app repo → its `release`
  workflow applies `deploy/` with `APP_IMAGE=…:v1.2.3` and waits for the rollout.
- **Deploy the next version:** push `v1.2.4`. Nothing in `homelab-infra` changes.
- **Roll back:** run the app repo's `release` workflow (`workflow_dispatch`)
  against the old tag, or `kubectl -n <name> rollout undo deployment/<name>`.
- **What if `homelab-infra`'s `deploy` runs?** It only re-applies the platform
  scaffold (namespace/RBAC/DB/ingress). It never touches the Deployment, so it
  can't revert a version.
