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

## Users: one per kind of node owner

Nodes belong to a headscale **user**, and they are cheap. One user per *kind* of
owner keeps `headscale nodes list` readable and gives a future ACL something to
target:

| User | Nodes | Registered by |
|---|---|---|
| `sebas` (you) | personal devices — your laptop | `tailscale login` by hand |
| `infra` | the K3s host nodes — `kube-cp-01`, `kube-worker-01`, any future node | `tailscale up` by hand on the node (README → *Adding a worker node*) |
| `services` | in-cluster workloads that are their own tailnet node — Grafana (`grafana`), and whatever comes next | pre-auth key baked into the pod (e.g. `TS_AUTHKEY_GRAFANA`) |
| `github` | GitHub Actions runners — one ephemeral node per CI run, from **homelab-infra and every app repo** | `TS_AUTHKEY` in the run's environment (`setup-ssh` here, `homelab-actions/headscale-connect` in app repos) |

```bash
hs users create infra
hs users create services
hs users create github
hs users list                 # the numeric ID is what preauthkeys wants
```

> **This is organisation, not isolation.** With no policy in the database
> (`policy.mode: database`, nothing loaded) headscale lets every node reach
> every other node, whoever owns it. Separate users only start *restricting*
> anything once you write an ACL — e.g. allow `sebas` + `github` → `infra` on
> `:22`/`:6443`, `sebas` + `infra` → `services` on `:443`, and nothing else.
> Until then, treat the split as bookkeeping that makes that ACL possible later.

MagicDNS is unaffected: names are flat (`<node>.ts.homelab.sthomas.ch`), not
per-user, so a node keeps its name if it is re-registered under another user —
but node names stay unique cluster-wide, so a second live node called `grafana`
becomes `grafana-1`.

### Moving an existing node to another user

Headscale v0.29 has **no `nodes move`** — reassigning an already-registered node
means delete its record, then re-register it (fresh `tailscale up` with a
pre-auth key for the new user). Ephemeral CI nodes need nothing (the next run
re-creates them under whatever user `TS_AUTHKEY` now belongs to); a persistent
node (a K3s host) has a short admin-plane blip while it re-registers — `wg0`
carries the cluster itself, so nothing cluster-critical notices. Full procedure
for the K3s nodes: [`docs/headscale-user-split.md`](../../../docs/headscale-user-split.md).

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

| Use | User | Command |
|---|---|---|
| **A device you register once** (your laptop) | `sebas` | `hs preauthkeys create --user <ID> --reusable --expiration 24h` — short is fine, the node persists |
| **CI runners** (`TS_AUTHKEY`) — new ephemeral machine every run | `github` | `hs preauthkeys create --user <ID> --reusable --ephemeral --expiration 8760h` |
| **A K3s host node** (`kube-cp-01`, a worker) — registered once by hand (`tailscale up`), then persists | `infra` | `hs preauthkeys create --user <ID> --reusable --expiration 8760h` |
| **An in-cluster service node** (Grafana's `TS_AUTHKEY_GRAFANA`) | `services` | `hs preauthkeys create --user <ID> --reusable --expiration 8760h` — **never** `--ephemeral`: the pod is long-lived and an ephemeral node is deleted the moment it disconnects |

`--ephemeral` = the node is removed from headscale as soon as it disconnects
(the CI action runs `tailscale logout` on exit), so runner nodes never pile up.

`TS_AUTHKEY` (the `github`-user key) is a **per-repo** secret in homelab-infra
*and every app repo* (they run `homelab-actions/headscale-connect`) — a personal
GitHub account has no org-level secrets, so rotating it means updating each repo.
Promote it to an org secret if these repos ever move under an org.

One-liner (needs `jq` locally) — resolve the user name to its ID, then issue:

```bash
hs_uid=$(kubectl -n headscale exec deploy/headscale -- headscale users list -o json | jq -r '.[]|select(.name=="github").id')
kubectl -n headscale exec deploy/headscale -- headscale preauthkeys create --user "$hs_uid" --reusable --ephemeral --expiration 8760h
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
