# headscale/

Self-hosted Tailscale control server ([headscale](https://headscale.net)) plus
the [Headplane](https://github.com/tale/headplane) web UI, both in the
`headscale` namespace, pinned to `kube-cp-01`.

| | |
|---|---|
| Public URL | `https://headscale.homelab.sthomas.ch` (`/` = control API, `/admin` = Headplane) |
| Datastore | SQLite on a `local-path` PVC (`headscale-data`) |
| DERP | Tailscale's public relays (no embedded DERP) |
| MagicDNS base domain | `ts.homelab.sthomas.ch` |
| TLS | Traefik + cert-manager (`letsencrypt-prod`) |
| Headplane mode | "limited" — own Deployment, API-key auth. Manages nodes / users / pre-auth keys / routes / ACLs. Editing headscale's `config.yaml` from the UI is intentionally not enabled (config stays in git). |

Config is in [`files/headscale-config.yaml`](files/headscale-config.yaml) and
[`files/headplane-config.yaml`](files/headplane-config.yaml) (rendered into
hash-suffixed ConfigMaps, so an edit rolls the pods).

## First-time bootstrap (the API-key dance)

Headplane needs a headscale API key that only exists once headscale is running.

```bash
export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml

# 1. Deploy (Headplane comes up NotReady - expected).
kubectl apply -k kubernetes/infrastructure/headscale

# 2. Generate the API key.
kubectl -n headscale exec deploy/headscale -- \
  headscale apikeys create --expiration 8760h

# 3. Put it (and a cookie secret) where the deploy can find it:
#    - CI  : GitHub Environment secrets HEADPLANE_API_KEY + HEADPLANE_COOKIE_SECRET, then re-run `deploy`
#    - local:
kubectl -n headscale create secret generic headplane-secret \
  --from-literal=cookie_secret="$(openssl rand -hex 16)" \
  --from-literal=api_key="<the key from step 2>" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Roll Headplane.
kubectl -n headscale rollout restart deploy/headplane
```

Then open `https://headscale.homelab.sthomas.ch/admin` and paste the same
API key to log in.

## Day-to-day (headscale CLI)

gRPC is bound to localhost, so use the pod:

```bash
hs() { kubectl -n headscale exec -i deploy/headscale -- headscale "$@"; }

hs users create alice
hs preauthkeys create --user alice --reusable --expiration 24h
hs nodes list
hs routes list
```

Register a machine:

```bash
tailscale up --login-server=https://headscale.homelab.sthomas.ch --authkey=<key>
```

## Editing DNS / tailnet records

Edit [`files/extra-records.json`](files/extra-records.json) (A/AAAA only),
commit — `deploy` re-applies and headscale hot-reloads within ~1 min.

## Alternative: full UI (single-Pod integration mode)

To edit headscale settings from the Headplane UI you would run both containers
in one Pod with `shareProcessNamespace: true`, a ServiceAccount that can `get`
pods, and `integration.kubernetes.enabled: true`. That couples headscale's
lifecycle to Headplane's. Not done here — the limited-mode split is simpler and
keeps config in git. See the headplane docs if you want it.
