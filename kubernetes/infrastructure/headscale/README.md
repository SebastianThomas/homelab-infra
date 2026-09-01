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

gRPC is bound to localhost, so run the CLI in the pod:

```bash
hs() { kubectl -n headscale exec -i deploy/headscale -- headscale "$@"; }

hs users create alice
hs users list                 # note the numeric ID
hs nodes list
hs routes list
```

## Creating a pre-auth key

`headscale preauthkeys create` takes the user **ID** (a number), not the name.

```bash
hs users list
```

```bash
hs preauthkeys create --user <ID> --reusable --expiration 24h
```

One-liner (needs `jq` locally):

```bash
hs_uid=$(kubectl -n headscale exec deploy/headscale -- headscale users list -o json | jq -r '.[]|select(.name=="alice").id')
kubectl -n headscale exec deploy/headscale -- headscale preauthkeys create --user "$hs_uid" --reusable --expiration 24h
```

List / expire keys:

```bash
hs preauthkeys list --user <ID>
hs preauthkeys expire --user <ID> --key <KEY>
```

Or do all of this in Headplane: **Users** → add → the user's ⋯ menu →
**pre-auth keys**.

## Connecting a client

### One `tailscaled`, multiple tailnets as profiles (recommended)

Use `tailscale login` — it authenticates the machine **without** reconfiguring
the current profile. A different `--login-server` = a new profile; existing
profiles (e.g. a work tailnet) are left alone.

```bash
tailscale login --login-server=https://headscale.homelab.sthomas.ch --auth-key=<KEY> --hostname=<name>
```

Then move between tailnets — each profile keeps its own control server, node,
DNS and routes:

```bash
tailscale switch --list
```

```bash
tailscale switch <account>          # e.g. "thomas@ubique.ch" or the profile ID
```

Check which one is active:

```bash
tailscale status ; tailscale debug prefs | grep -i controlurl
```

If `tailscale login` complains that changing settings needs every non-default
flag re-listed, it isn't recognising this as a new profile — fall back to
`tailscale up --reset --login-server=… --auth-key=… --hostname=…` (only `up`
has `--reset`; on a plain daemon it still creates the new profile).

> **This does not work through the macOS Tailscale GUI app.** That app pins the
> control URL for its own `tailscaled` and ignores CLI `--login-server` — your
> command silently hits the *other* tailnet ("invalid pre auth key" from the
> wrong server; `--reset` logs you out of it). On macOS, either run **only**
> Homebrew's `tailscaled` (`sudo brew services start tailscale`, no GUI app —
> the profile/`switch` flow above then works), or keep the GUI app and use the
> separate-daemon method below.

### macOS: keep the work GUI app, add homelab as a second daemon

A second `tailscaled` with its own state — cannot touch the app:

```bash
brew install tailscale
sudo mkdir -p /var/lib/tailscaled-homelab
sudo /opt/homebrew/bin/tailscaled --tun=userspace-networking --socket=/tmp/ts-homelab.sock --statedir=/var/lib/tailscaled-homelab --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055
```

```bash
/opt/homebrew/bin/tailscale --socket=/tmp/ts-homelab.sock up --login-server=https://headscale.homelab.sthomas.ch --auth-key=<KEY> --hostname=<name>
```

Reach homelab-tailnet hosts through the proxy
(`ALL_PROXY=socks5://localhost:1055 …`); stop it with `sudo pkill -f ts-homelab.sock`.

> The Raspberry Pi is **not** connected by either method — K3s's `--vpn-auth`
> joins it automatically in Phase 2 using `TS_PREAUTH_KEY`.

> **"invalid pre auth key" checklist:** `tailscale debug prefs | grep -i
> controlurl` must show *your* Headscale URL (if not, `--login-server` didn't
> apply — you're on the wrong daemon).
> `kubectl -n headscale exec deploy/headscale -- headscale preauthkeys list`
> must show the key with `Used=false` and a future expiry.

## Editing DNS / tailnet records

Edit [`files/extra-records.json`](files/extra-records.json) (A/AAAA only),
commit — `deploy` re-applies and headscale hot-reloads within ~1 min.

## Alternative: full UI (single-Pod integration mode)

To edit headscale settings from the Headplane UI you would run both containers
in one Pod with `shareProcessNamespace: true`, a ServiceAccount that can `get`
pods, and `integration.kubernetes.enabled: true`. That couples headscale's
lifecycle to Headplane's. Not done here — the limited-mode split is simpler and
keeps config in git. See the headplane docs if you want it.
