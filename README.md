# homelab-infra

Infrastructure-as-code for a small self-hosted **K3s** cluster.

- **Ansible** (`ansible/`) prepares the Debian hosts and installs a
  version-pinned K3s. Nothing else.
- **Kubernetes manifests** (`kubernetes/`) run on the cluster: ingress/TLS,
  CloudNativePG, a self-hosted **Headscale** (Tailscale control server) + web
  UI, and your apps.
- **GitHub Actions** (`.github/workflows/`) drive both — `provision` (Ansible)
  and `deploy` (`kubectl apply`). Secrets live in a GitHub **Environment**.

```
Fresh Debian ──ssh──▶ Ansible ──▶ host config ──▶ K3s server ──▶ working cluster
                                                                      │
                                                     kubectl / Kustomize
                                                                      ▼
                                        cert-manager · CloudNativePG · Headscale · apps
```

## Nodes

Hostname pattern `kube-<role>-<number>`.

| Node | Machine | Role |
|---|---|---|
| `kube-cp-01` | Strato VPS — `homelab.sthomas.ch` → `h2977839.stratoserver.net` (`81.169.131.24`) | K3s **server**, SQLite datastore, runs everything |
| `kube-worker-01` | Raspberry Pi at home (arm64) | K3s **agent**, optional, opt-in workloads (Phase 2) |

`kube-cp-01` is the whole cluster on its own. The Pi is added later over the
Headscale tailnet (see [Adding kube-worker-01](#adding-kube-worker-01)).

Node labels/taints (set by Ansible via `--node-label` / `--node-taint`):
`homelab.sthomas.ch/location=strato` on the VPS; `location=home` +
`homelab.sthomas.ch/edge=true:NoSchedule` on the Pi (so nothing lands there
unless a namespace opts in). Workloads are pinned per-namespace with a
`scheduler.alpha.kubernetes.io/node-selector` annotation — the K3s server runs
the `PodNodeSelector` / `PodTolerationRestriction` admission plugins.

---

## Requirements on the machine running Ansible

Only needed for **local** runs (CI has its own). `ansible` (≥ 2.15; the full
package, which bundles `community.general`), an OpenSSH client with a key on the
hosts, `openssl`, and — to talk to the cluster afterwards — `kubectl`.

```bash
pipx install --include-deps ansible      # or: brew install ansible
```

`kubectl` includes Kustomize; no separate install.

## Assumptions about the hosts

- Debian 12/13 (the Pi: 64-bit Raspberry Pi OS / Debian arm64), freshly
  installed, reachable over SSH, with a `sudo`-capable user.
- The VPS has a mostly-static public IPv4 and its Strato hostname resolves to it.
- `python3` present (default on Debian).

The `common` role keeps hosts minimal: hostname, apt upgrade, a short package
list, timezone, swap off, `/etc/hosts` for the cluster, the `wireguard` module.

---

## Bootstrapping

### 1. GitHub Environment

Create an Environment named **`production`** (Settings → Environments) with:

**Secrets** (everything is a secret — no Environment variables needed)

| Name | Value / how |
|---|---|
| `SSH_PRIVATE_KEY` | private key with `sudo` SSH access to the nodes |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan homelab.sthomas.ch` output (optional but recommended) |
| `ANSIBLE_SSH_USER` | your SSH user, e.g. `sebas` |
| `SSH_HOST` | `homelab.sthomas.ch` |
| `KUBE_API` | `https://homelab.sthomas.ch:6443` |
| `HEADSCALE_URL` | `https://headscale.homelab.sthomas.ch` |
| `K3S_TOKEN` | `openssl rand -hex 32` — the cluster join secret |
| `HEADPLANE_COOKIE_SECRET` | `openssl rand -hex 16` (set after first deploy) |
| `HEADPLANE_API_KEY` | `headscale apikeys create` output (set after first deploy) |
| `TS_PREAUTH_KEY` | Headscale pre-auth key for the K3s nodes (`--reusable --expiration 100y`) — for private API access / the Pi |
| `TS_AUTHKEY` | Headscale pre-auth key for CI runners (`--reusable --ephemeral --expiration 100y`) — runners join the tailnet when set |

> GitHub masks secret values in workflow logs, so `SSH_HOST` / `KUBE_API` etc.
> show up as `***` in run output — expected.

### 2. DNS

In your `sthomas.ch` zone, point the `homelab` subtree at the VPS (plain
A/CNAME — **no Cloudflare proxy**, it breaks the Tailscale control protocol):

| Name | Type | Value | Covers |
|---|---|---|---|
| `homelab.sthomas.ch` | CNAME (or A) | `h2977839.stratoserver.net` (or `81.169.131.24`) | the K3s API on `:6443` |
| `*.homelab.sthomas.ch` | CNAME | `homelab.sthomas.ch` | Headscale + every app — one wildcard, no per-app records |

No wildcard support at your DNS host? Add a CNAME per name instead
(`headscale.homelab.sthomas.ch`, then one per app, all → `homelab.sthomas.ch`).

`ts.homelab.sthomas.ch` (the MagicDNS base domain) needs **no** record — it is
answered inside the tailnet only.

### 3. Inventory & version

Edit `ansible/inventory/hosts.yml` (`ansible_host`, `ansible_user`) and
`ansible/group_vars/all/main.yml` (`k3s_version` — pin to a current release from
<https://github.com/k3s-io/k3s/releases>).

### 4. Provision the host

Run the **`provision`** workflow (Actions tab → Run workflow). It writes the
vault from the Environment secrets, then `ansible-playbook site.yml`: ufw, K3s
server, and it leaves a kubeconfig on the node.

Local equivalent:

```bash
cd ansible
cp group_vars/all/vault.yml.example group_vars/all/vault.yml   # fill in, then:
ansible-vault encrypt group_vars/all/vault.yml
ansible-playbook site.yml --ask-vault-pass
export KUBECONFIG=$PWD/../kubeconfig/kube-cp-01.yaml
```

### 5. Deploy the cluster

Run the **`deploy`** workflow (or `kubernetes/bootstrap.sh` locally). It applies,
in order: Traefik config → cert-manager + issuers → CloudNativePG + catalog →
Headscale/Headplane → the platform scaffold of each `apps/<name>/`.

### 6. Finish Headscale

Headplane needs an API key that only exists once headscale runs — do the
[bootstrap dance](kubernetes/infrastructure/headscale/README.md#first-time-bootstrap-the-api-key-dance):
generate the key, set `HEADPLANE_API_KEY` + `HEADPLANE_COOKIE_SECRET`, re-run
`deploy`. Then:

```bash
curl -sf https://headscale.homelab.sthomas.ch/health   # -> 200
```

and open `…/admin`.

---

## Using the cluster

**On the node** — `provision` drops a working `~/.kube/config` for your SSH user,
so `kubectl` just works over SSH:

```bash
ssh sebas@homelab.sthomas.ch kubectl get nodes
```

**From your laptop** — a local Ansible run writes `kubeconfig/kube-cp-01.yaml`
(git-ignored, API address already rewritten to `homelab.sthomas.ch`):

```bash
export KUBECONFIG=$PWD/kubeconfig/kube-cp-01.yaml && kubectl get nodes
```

Or pull it over SSH (rewriting the loopback address):

```bash
ssh sebas@homelab.sthomas.ch sudo cat /etc/rancher/k3s/k3s.yaml | sed 's#127.0.0.1#homelab.sthomas.ch#' > ~/.kube/homelab.yaml
```

`kubeconfig/` and `*.kubeconfig` are git-ignored — never commit one.

## Adding an application

Apps are **split across two repos** so you can ship a new version from the app's
own repo with **no commit here**:

- **This repo** owns the platform side per app — namespace, node placement,
  a scoped `deployer` ServiceAccount, database, ingress. Set it up once:
  `cp -r kubernetes/apps/_template kubernetes/apps/<name>`, adjust, push.
- **The app's repo** owns its `Deployment` + `Service` and deploys itself on
  release via the reusable composite action
  `SebastianThomas/homelab-infra/.github/actions/deploy-to-k8s@main`, pinning
  whatever version it wants (git tag → image tag). Rollback = redeploy an older
  tag or `kubectl rollout undo`.

Full walkthrough + templates: [`kubernetes/apps/README.md`](kubernetes/apps/README.md).

## Where things live

| | |
|---|---|
| `kubernetes/infrastructure/` | cluster-wide services (ingress tuning, TLS, DB operator, Headscale) |
| `kubernetes/apps/<name>/` | the platform side of an app (namespace, RBAC, database, ingress) |
| the app's own repo | its `Deployment` / `Service` and released version |

Ansible never deploys anything under `kubernetes/`.

---

## Private API access over Tailscale

Put the VPS on the Headscale tailnet so `kubectl` (yours and CI's) reaches the
API by its stable MagicDNS name instead of the public IP — and you can then
firewall off public `:6443`.

1. **Pre-auth key** for the VPS
   ([how](kubernetes/infrastructure/headscale/README.md#creating-a-pre-auth-key)):
   `--reusable --expiration 100y`. Put it in the Ansible vault as
   `vault_tailscale_preauth_key` and in the `TS_PREAUTH_KEY` GitHub secret.
2. Set `k3s_enable_vpn: true` in `ansible/group_vars/all/main.yml`, run
   **`provision`** (`limit: k3s_cp`). K3s installs Tailscale, joins the tailnet
   via `--vpn-auth`, and adds `kube-cp-01.ts.homelab.sthomas.ch` to the API cert.
3. **CI key**: a second pre-auth key, `--reusable --ephemeral --expiration 100y`
   → `TS_AUTHKEY` GitHub secret. Now every `deploy`/`provision` runner joins the
   tailnet automatically (via `.github/actions/setup-ssh`).
4. Flip the endpoint secrets to the MagicDNS name:
   - `SSH_HOST` → `kube-cp-01.ts.homelab.sthomas.ch`
   - `KUBE_API` → `https://kube-cp-01.ts.homelab.sthomas.ch:6443`
   Your laptop: `tailscale switch` to the homelab profile, then re-fetch the
   kubeconfig with that host (see [Using the cluster](#using-the-cluster)).
5. **Close public `:6443`** — in `ansible/roles/firewall/defaults/main.yml`
   swap the `6443` rule for the tailnet-scoped one shown in its comments, run
   `provision`. Leave `:22` public (only `provision`'s inventory `ansible_host`
   still uses it; the deploy runner is on the tailnet).

## Adding kube-worker-01

The Pi joins the K3s pod network over the same tailnet. Do this after "Private
API access" above (the VPS is already on the tailnet then).

1. Read the VPS tailnet IP (`ssh … tailscale ip -4`, or `headscale nodes list`)
   into `k3s_cp_tailscale_ip` in `group_vars/all/main.yml`; run `provision`
   `limit: k3s_cp` (adds it to the cert + `node-external-ip`).
2. Uncomment `kube-worker-01` in `ansible/inventory/hosts.yml`, set its
   `ansible_host` to its tailnet name, run `provision`.
3. In Headplane, approve the Pi node and its `10.42.x.0/24` pod route.

---

## Updating the pinned K3s version

Bump `k3s_version` in `ansible/group_vars/all/main.yml` (one minor at a time),
run `provision`. `site.yml` does servers before agents. Renovate opens the PR
for you (label `k3s-upgrade`).

## Backups

Git holds **configuration**. Runtime **state** on `kube-cp-01` — everything
under `/var/lib/rancher/k3s/` — needs its own backup:

| Path | Contents | If lost |
|---|---|---|
| `server/db/state.db*` | SQLite datastore: every K8s object, incl. Secrets & CRs | the whole cluster |
| `server/tls/`, `server/token`, `server/cred/` | cluster CA + join secrets | nodes/kubeconfigs no longer trusted; agents can't rejoin |
| `storage/` | every `local-path` PVC: **CloudNativePG data**, Headscale `db.sqlite` + `noise_private.key`, Headplane state | DB data; losing the noise key ⇒ **every tailnet node must re-register** |

```bash
sudo systemctl stop k3s
sudo tar czf "/root/k3s-backup-$(date +%F).tgz" /var/lib/rancher/k3s
sudo systemctl start k3s
# then copy it off the box (cron / systemd-timer / rsync to the Pi or a NAS)
```

A filesystem/LVM/ZFS snapshot of `/var/lib/rancher/k3s` works without the stop.
CloudNativePG has **no** backups configured (by choice); for a logical dump when
you need one: `kubectl -n <ns> exec <cluster>-1 -- pg_dump -Fc <db>`.

To rebuild from scratch: fresh Debian → `provision` (same `k3s_version`) →
restore the tarball over `/var/lib/rancher/k3s` → `deploy` → re-add the Pi.
