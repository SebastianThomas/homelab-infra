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
| Routing | `httproute.yaml` (Gateway API) → `traefik-gateway` in `kube-system` — see [`docs/gateway-api.md`](../../../docs/gateway-api.md) |
| TLS | the cluster wildcard cert (`gateway-tls`), terminated at Traefik |
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

## Users: people vs. service nodes

Nodes belong to a headscale **user**, and they are cheap — keep the two kinds
apart so `headscale nodes list` stays readable and a future ACL has something to
target:

| User | Nodes |
|---|---|
| `<you>` (e.g. `sebas`) | your laptop, the K3s nodes, CI runners |
| `services` | in-cluster workloads that are their own tailnet node — Grafana (`grafana`), and whatever comes next |

```bash
hs users create services
hs users list                 # the numeric ID is what preauthkeys wants
```

> **This is organisation, not isolation.** With no policy in the database
> (`policy.mode: database`, nothing loaded) headscale lets every node reach
> every other node, whoever owns it. Separate users only start *restricting*
> anything once you write an ACL — e.g. allow `group:admins` → the `services`
> user's nodes on `:443` and nothing else. Until then, treat the split as
> bookkeeping that makes that ACL possible later.

MagicDNS is unaffected: names are flat (`<node>.ts.homelab.sthomas.ch`), not
per-user, so moving a node between users does not change its name — but node
names stay unique cluster-wide, so a second node called `grafana` becomes
`grafana-1`.

## Creating a pre-auth key

`headscale preauthkeys create` takes the user **ID** (a number), not the name
(`hs users list` to find it).

**Expiry:** `--expiration` (default `1h`; accepts `30m`, `24h`, `30d`, `8760h`).
A *registered node* does not expire (`node.expiry: 0` in our config), so a node
stays connected even after its key expires — the key only has to be valid at
registration time.

> **Don't use silly-long expirations like `100y`.** A Headscale upgrade
> (v0.29 did this) can start rejecting pre-auth keys with far-future
> expirations — established nodes keep working but every *new* CI runner then
> fails at `tailscale up` (silent, 120 s timeout). Symptom: CI green, then all
> runs fail at "Join the Headscale tailnet" with nothing in the headscale log.
> Fix: create a fresh key, update `TS_AUTHKEY` everywhere (below), re-run.

| Use | Command |
|---|---|
| **A device you register once** (your laptop, the VPS on the tailnet) | `hs preauthkeys create --user <ID> --reusable --expiration 24h` — short is fine, the node persists |
| **CI runners** (`TS_AUTHKEY`) — new ephemeral machine every run | `hs preauthkeys create --user <ID> --reusable --ephemeral --expiration 8760h` |
| **A K3s worker node** — registered once by hand (`tailscale up`), then persists | `hs preauthkeys create --user <ID> --reusable --expiration 8760h` |
| **An in-cluster service node** (`services` user; Grafana's `TS_AUTHKEY_GRAFANA`) | `hs preauthkeys create --user <ID> --reusable --expiration 8760h` — **never** `--ephemeral`: the pod is long-lived and an ephemeral node is deleted the moment it disconnects |

`--ephemeral` = the node is removed from headscale as soon as it disconnects
(the CI action runs `tailscale logout` on exit), so runner nodes never pile up.

`TS_AUTHKEY` lives as a **per-repo** secret in homelab-infra *and every app
repo* (they run `headscale-connect`). Rotating it means updating all of them —
or promote it to an org-level secret so it's one place.

One-liner (needs `jq` locally):

```bash
hs_uid=$(kubectl -n headscale exec deploy/headscale -- headscale users list -o json | jq -r '.[]|select(.name=="alice").id')
kubectl -n headscale exec deploy/headscale -- headscale preauthkeys create --user "$hs_uid" --reusable --expiration 24h
```

List / expire keys:

```bash
hs preauthkeys list                 # v0.29: no --user flag; shows all, with IDs
hs preauthkeys expire --id <ID>
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

> A K3s worker node (the Pi) joins with a standalone `tailscale up` run once by
> hand on the node — see the main README "Adding a worker node".

> **"invalid pre auth key" checklist:** `tailscale debug prefs | grep -i
> controlurl` must show *your* Headscale URL (if not, `--login-server` didn't
> apply — you're on the wrong daemon).
> `kubectl -n headscale exec deploy/headscale -- headscale preauthkeys list`
> must show the key with `Used=false` and a future expiry.

## Editing DNS / tailnet records

Edit [`files/extra-records.json`](files/extra-records.json) (A/AAAA only),
commit — `deploy` re-applies and headscale hot-reloads within ~1 min. (The file
is rendered into a hash-suffixed ConfigMap, so an edit also rolls the pod.)

Use it for records that point at something already on the tailnet. It is **not**
how a cluster service is published on the tailnet: a static record pointing at
`kube-cp-01` only sends the client to the public Traefik on the node's :443,
which serves the same route to the public internet. A record cannot restrict
anything.

**A tailnet-only service gets its own tailnet node instead.** A `tailscale`
container in the workload's pod registers with headscale under the service's
name, so MagicDNS answers with *that pod's* `100.64.0.0/10` address and the only
way in is a WireGuard session — no public listener anywhere. Grafana is the
worked example:
[`../monitoring/README.md`](../monitoring/README.md#access--tailnet-only-enforced)
(and the three reasons the Traefik-side approaches fail are in
[`docs/gateway-api.md`](../../../docs/gateway-api.md#tailnet-only-services)).

Such a node needs a **reusable, non-ephemeral** pre-auth key and persistent
state; both node records and static records live in the same namespace, so a
static record must not collide with a node name — headscale's node records win.

## Alternative: full UI (single-Pod integration mode)

To edit headscale settings from the Headplane UI you would run both containers
in one Pod with `shareProcessNamespace: true`, a ServiceAccount that can `get`
pods, and `integration.kubernetes.enabled: true`. That couples headscale's
lifecycle to Headplane's. Not done here — the limited-mode split is simpler and
keeps config in git. See the headplane docs if you want it.
