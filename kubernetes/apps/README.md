# apps/

An app is split across **two repos**:

| Side | Lives in | Owns | Changes |
|---|---|---|---|
| **Platform** | `homelab-infra/kubernetes/apps/<name>/` | namespace, node placement, RBAC (a `deployer` ServiceAccount), database, `HTTPRoute` | rarely — only when the app's *surroundings* change |
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

The route host is `<name>.homelab.sthomas.ch` — already covered by the
`*.homelab.sthomas.ch` wildcard, so no DNS change (add a CNAME per app only if
you don't run a wildcard). The `HTTPRoute` attaches to the shared
`traefik-gateway`; see [`docs/gateway-api.md`](../../docs/gateway-api.md).

In nginx-edge mode you also add the hostname to the host nginx vhost + cert —
[`docs/nginx-edge.md`](../../docs/nginx-edge.md).

Commit + push → the `deploy` workflow applies the namespace, RBAC, DB and
route. Then set these secrets in the **app repo**'s `production` GitHub
Environment (the `deployer` SA is scoped to that one namespace). The `kubectl`
below needs `export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml`:

| Secret | Value |
|---|---|
| `KUBE_API` | `https://kube-cp-01.ts.homelab.sthomas.ch:6443` (public `:6443` is firewalled to the tailnet) |
| `KUBE_CA` | `kubectl -n <name> get secret deployer-token -o jsonpath='{.data.ca\.crt}'` (already base64) |
| `KUBE_TOKEN` | `kubectl -n <name> get secret deployer-token -o jsonpath='{.data.token}' \| base64 -d` |
| `HEADSCALE_URL` | `https://headscale.homelab.sthomas.ch` |
| `TS_AUTHKEY` | `headscale preauthkeys create --user <id> --reusable --ephemeral --expiration 100y` |

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

`.github/workflows/release.yml` — build/push the image, then the two shared
actions from [`homelab-actions`](https://github.com/SebastianThomas/homelab-actions):

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
    permissions: { contents: read, packages: write }
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: ${{ github.actor }}, password: ${{ secrets.GITHUB_TOKEN }} }
      - uses: docker/build-push-action@v6
        with: { push: true, tags: "ghcr.io/${{ github.repository }}:${{ github.ref_name }}" }

      - uses: SebastianThomas/homelab-actions/headscale-connect@v1
        with:
          auth-key:     ${{ secrets.TS_AUTHKEY }}
          login-server: ${{ secrets.HEADSCALE_URL }}
      - uses: SebastianThomas/homelab-actions/kube-deploy@v1
        with:
          server:    ${{ secrets.KUBE_API }}
          ca:        ${{ secrets.KUBE_CA }}
          token:     ${{ secrets.KUBE_TOKEN }}
          namespace: <name>
          image:     ghcr.io/${{ github.repository }}:${{ github.ref_name }}
```

(If `homelab-actions` is private: enable it under its Settings → Actions →
"Accessible from repositories owned by the user". See its README.)

## Versioning & rollback

- **Deploy a version:** push tag `v1.2.3` in the app repo → its `release`
  workflow applies `deploy/` with `APP_IMAGE=…:v1.2.3` and waits for the rollout.
- **Deploy the next version:** push `v1.2.4`. Nothing in `homelab-infra` changes.
- **Roll back:** run the app repo's `release` workflow (`workflow_dispatch`)
  against the old tag, or `kubectl -n <name> rollout undo deployment/<name>`.
- **What if `homelab-infra`'s `deploy` runs?** It only re-applies the platform
  scaffold (namespace/RBAC/DB/HTTPRoute). It never touches the Deployment, so it
  can't revert a version.
