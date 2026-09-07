# Runbook: split the Headscale users (`sebas` → `infra` / `services` / `github`)

One-time migration. The target model and the day-to-day commands live in
[`kubernetes/infrastructure/headscale/README.md`](../kubernetes/infrastructure/headscale/README.md#users-one-per-kind-of-node-owner);
this file is only the cut-over.

| User | Nodes | How they get there |
|---|---|---|
| `sebas` | your laptop | unchanged |
| `infra` | `kube-cp-01`, `kube-worker-01` | re-registered by hand (steps 4–5) |
| `services` | `grafana`, future service nodes | already there — nothing to do |
| `github` | CI runners (homelab-infra + app repos) | next CI run, once `TS_AUTHKEY` points at the new key (step 3) |

Headscale v0.29 has **no `nodes move`**: a registered node is reassigned by
*deleting its record and re-registering*. Ephemeral CI nodes need nothing; the
two K3s nodes get a short admin-plane blip (kubectl / SSH-over-tailnet /
MagicDNS) while they re-register — `wg0` carries the cluster join and all pod
traffic, so the cluster itself never notices.

## Prep

```bash
export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml
hs()  { kubectl -n headscale exec -i deploy/headscale -- headscale "$@"; }
uid() { hs users list -o json | jq -r ".[] | select(.name==\"$1\").id"; }
```

## 1. Create the users

```bash
hs users create infra
hs users create github
hs users create services   # skip if `hs users list` already shows it
hs users list
```

## 2. Issue the pre-auth keys

```bash
# github — CI runners: reusable + ephemeral
hs preauthkeys create --user "$(uid github)" --reusable --ephemeral --expiration 8760h

# infra — used by hand to re-register kube-cp-01 and kube-worker-01 (steps 4–5).
# One reusable key covers both; non-ephemeral (the nodes persist).
hs preauthkeys create --user "$(uid infra)" --reusable --expiration 8760h
```

`services` needs no new key now — the Grafana node reconnects with the node key
on its `grafana-tailnet-state` PVC. Only reissue (for `--user "$(uid services)"`)
if that PVC is ever wiped.

## 3. Repoint `TS_AUTHKEY` (the CI key)

`TS_AUTHKEY` is a per-repo `production` Environment secret (a personal GitHub
account has no org-level secrets). Set it to the **github** key from step 2 in
every repo that joins the tailnet from CI:

- `SebastianThomas/homelab-infra` — Settings → Environments → `production` → `TS_AUTHKEY`
- every app repo that ships a `release.yml` (`SebastianThomas/genie-web`, …) — same

Nothing to deploy: the next workflow run picks up the new value and its runner
registers under `github`.

## 4. Re-register `kube-cp-01` (over **public** SSH — no lock-out risk, `:22` stays public)

```bash
# a. note the current tailnet setup, so the new `tailscale up` matches it
ssh sebas@homelab.sthomas.ch sudo tailscale debug prefs
#    -> Hostname, CorpDNS (false == the node was brought up --accept-dns=false),
#       AdvertiseRoutes (contains 0.0.0.0/0 == it advertises the exit node)
hs nodes list        # note kube-cp-01's node ID and its tailnet IP (expect 100.64.0.2)

# b. on the node: drop the current session, then delete the stale record
ssh sebas@homelab.sthomas.ch sudo tailscale logout
hs nodes delete -i <cp-node-id>          # confirm the prompt

# c. re-register under infra, matching the flags from (a)
ssh sebas@homelab.sthomas.ch \
  'sudo tailscale up --login-server=https://headscale.homelab.sthomas.ch \
     --authkey=<infra-key> --hostname=kube-cp-01 \
     --accept-dns=false --advertise-exit-node'
#   if `tailscale up` refuses ("changing settings requires ..."), add --reset

# d. re-approve the exit-node routes (new node ID)
hs nodes list
hs nodes approve-routes -i <new-cp-node-id> -r 0.0.0.0/0,::/0
```

Step 4 runs over **public** SSH, so `tailscale logout` does not drop your shell.

**Check the tailnet IP** in the `hs nodes list` output. Sequential allocation
almost always hands `100.64.0.2` straight back (the delete frees it, and the CP
re-registers before the worker).

If it is **not** `100.64.0.2`, the API-server cert SAN is stale — kubectl over
the MagicDNS name still validates (that SAN is unchanged), but fix the drift:

1. `ansible/group_vars/all/main.yml` → `k3s_cp_tailscale_ip: "<new IP>"`, commit.
2. Run **`provision`** with `limit: k3s_cp` — re-renders `/etc/rancher/k3s/config.yaml`
   and k3s reissues the cert with the new SAN.

`KUBE_API` / `SSH_HOST` use the MagicDNS name, not the IP — leave them.

## 5. Re-register `kube-worker-01` (the Pi — from **home LAN / OpenVPN / console**)

Deleting the Pi's record drops tailnet SSH to it (`ansible_host` is its MagicDNS
name), and it is behind NAT — you need a path to it that does not go through the
tailnet.

```bash
# a. on the Pi, over the LAN — check flags, then log out:
sudo tailscale debug prefs        # same flags check as step 4a
sudo tailscale logout

# b. from the cluster:
hs nodes list
hs nodes delete -i <worker-node-id>          # confirm the prompt

# c. on the Pi:
sudo tailscale up --login-server=https://headscale.homelab.sthomas.ch \
  --authkey=<infra-key> --hostname=kube-worker-01 \
  --accept-dns=false --advertise-exit-node

# d. from the cluster:
hs nodes list
hs nodes approve-routes -i <new-worker-node-id> -r 0.0.0.0/0,::/0
```

The Pi's tailnet IP is not referenced anywhere as code (`node_ip` / `wg_ip` are
`wg0` addresses, `ansible_host` is the MagicDNS name) — an IP change here is
harmless.

## 6. Verify

```bash
hs nodes list
#   kube-cp-01, kube-worker-01  -> user `infra`
#   grafana                     -> user `services`
#   sebas's laptop              -> user `sebas`   (only thing left under sebas)

kubectl get nodes -o wide                       # both Ready
ssh sebas@homelab.sthomas.ch kubectl get nodes  # API reachable
tailscale ping kube-cp-01 ; tailscale ping kube-worker-01
```

Trigger a CI run (`deploy` → *Run workflow*, or push a no-op to `kubernetes/`)
and confirm a `gha-homelab-…` runner shows up under `github` in `hs nodes list`
mid-run (it disconnects and is dropped when the run ends).

## 7. Clean up

```bash
hs preauthkeys list
hs preauthkeys expire --id <id>    # the OLD sebas-user CI key, plus any stale ones
```

Expire the old `sebas` CI key **after** every repo secret is updated (step 3), so
a stale checkout can't keep registering runners under `sebas`.

## Rollback

Keys and registrations are cheap and `wg0` keeps the cluster up throughout. If a
re-registration lands wrong: `hs nodes delete -i <bad-id>`, then re-run the
node's `tailscale up` with the correct flags. Worst case for `kube-cp-01`, reach
it on public `:22` and, if the tailnet is wedged, `sudo ufw allow 6443/tcp` for
temporary public API access (see the main README → *Private API access*).

## Follow-up (optional): the ACL

With the users split, `policy.mode: database` can carry a real ACL (write it in
Headplane → **Access Controls**). A first cut:

- `sebas`, `github` → `infra` on `tcp:22,6443`
- `sebas`, `infra` → `services` on `tcp:443`
- exit-node use (`autogroup:internet`) for `sebas` only

Until an ACL exists, the split is bookkeeping — every node can still reach every
other node.
