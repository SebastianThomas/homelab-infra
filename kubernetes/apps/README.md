# apps/

**homelab-infra carries no per-app config.** Each app lives entirely in its own
repo — namespace, Deployment, Service, HTTPRoute, (optional) database — and
deploys itself on tag via GitHub Actions.

`_template/` here is just a **copy-paste source**: copy it into your app repo as
`deploy/`, `s/myapp/<name>/`, done. homelab-infra never applies it.

What homelab-infra *does* provide:

- `infrastructure/app-deployer/` — one shared `app-deployer` ServiceAccount +
  ClusterRole. Its token is the `KUBE_TOKEN` for **all** app repos. Scope: deploy
  apps (any namespace), not touch the platform.
- the shared Traefik `Gateway`, cert-manager, the CNPG operator + image catalog.

## Per app — one-time

```bash
cp -r <homelab-infra>/kubernetes/apps/_template <your-app-repo>/deploy
cd <your-app-repo>/deploy && sed -i '' 's/myapp/<name>/g' *.yaml kustomization.yaml
# adjust deployment.yaml (ports, resources, env); uncomment database.yaml if needed
```

Add `.github/workflows/release.yml` (see below). Set the app repo's **`production`
GitHub Environment** secrets:

| Secret | Value |
|---|---|
| `KUBE_API` | `https://kube-cp-01.ts.homelab.sthomas.ch:6443` |
| `KUBE_CA` | `kubectl -n ci get secret app-deployer-token -o jsonpath='{.data.ca\.crt}'` |
| `KUBE_TOKEN` | `kubectl -n ci get secret app-deployer-token -o jsonpath='{.data.token}' \| base64 -d` |
| `HEADSCALE_URL` | `https://headscale.homelab.sthomas.ch` |
| `TS_AUTHKEY` | reusable+ephemeral headscale pre-auth key (share one across app repos) |
| image registry creds | `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`, or use `ghcr.io` + `GITHUB_TOKEN` |

`KUBE_CA` / `KUBE_TOKEN` are the **same value for every app** — extract once.

TLS: nothing to do — the shared `websecure` listener carries a wildcard cert
(`*.sthomas.ch` / `*.homelab.sthomas.ch`, see [`docs/gateway-api.md`](../../docs/gateway-api.md#tls)).
Just point the hostname's DNS at the VPS.

## `deploy/` layout (the `_template`)

```
deploy/
├── namespace.yaml     # <name> namespace, node-pinned via annotation
├── deployment.yaml    # image: ${APP_IMAGE}  (substituted at deploy time)
├── service.yaml       # name <name>, port 80
├── httproute.yaml     # <name>.homelab.sthomas.ch -> the Service
├── database.yaml      # optional CNPG Cluster; secret <name>-db-app has `uri`
└── kustomization.yaml # namespace: <name>, resources list
```

`kube-deploy` runs `kubectl kustomize deploy/`, substitutes `${APP_IMAGE}`, applies.

## `.github/workflows/release.yml`

```yaml
name: release
on:
  push: { tags: ["v*"] }   # deploy v1.2.3 by pushing tag v1.2.3
  workflow_dispatch: {}     # re-run against an old tag to roll back
jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production
    steps:
      - uses: actions/checkout@v4
      - name: Image ref
        run: echo "IMAGE=${{ secrets.DOCKERHUB_USERNAME }}/<name>:${GITHUB_REF_NAME}" >> "$GITHUB_ENV"
      - uses: docker/login-action@v3
        with: { username: ${{ secrets.DOCKERHUB_USERNAME }}, password: ${{ secrets.DOCKERHUB_TOKEN }} }
      - uses: docker/build-push-action@v6
        with: { push: true, tags: "${{ env.IMAGE }}" }
      - uses: SebastianThomas/homelab-actions/headscale-connect@v1
        with: { auth-key: ${{ secrets.TS_AUTHKEY }}, login-server: ${{ secrets.HEADSCALE_URL }} }
      - uses: SebastianThomas/homelab-actions/kube-deploy@v1
        with:
          server: ${{ secrets.KUBE_API }}
          ca: ${{ secrets.KUBE_CA }}
          token: ${{ secrets.KUBE_TOKEN }}
          namespace: <name>
          image: ${{ env.IMAGE }}
```

(`homelab-actions` is public so `uses:` resolves from any repo/org. A private
action repo owned by a user only resolves from that user's own repos, not from
org repos.)

Live example: [`SebastianThomas/genie-web`](https://github.com/SebastianThomas/genie-web).

## Versioning & rollback

- **Deploy:** push tag `v1.2.3` → build + `kubectl apply` + wait for rollout.
- **Roll back:** `workflow_dispatch` the `release` workflow against an older tag,
  or `kubectl -n <name> rollout undo deployment/<name>`.
- Nothing in homelab-infra changes for any of this.
