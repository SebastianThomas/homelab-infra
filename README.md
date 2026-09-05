# homelab-infra

Infrastructure-as-code for a small self-hosted **K3s** cluster.

- **Ansible** (`ansible/`) prepares the Debian hosts and installs a
  version-pinned K3s. Nothing else.
- **Kubernetes manifests** (`kubernetes/`) run on the cluster: Gateway API
  routing / TLS, CloudNativePG, a self-hosted **Headscale** (Tailscale control
  server) + web UI, and your apps.
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
| `kube-worker-01` | Raspberry Pi 4 (8 GB) at home, Ubuntu Server arm64, behind NAT | K3s **agent**, opt-in workloads only (tainted) |

`kube-cp-01` is the whole cluster on its own. A worker joins the pod network
over the Headscale tailnet — see [Adding a worker node](#adding-a-worker-node).

Node labels/taints (set by Ansible via `--node-label` / `--node-taint`):
`homelab.sthomas.ch/location=strato` on the VPS; `location=home` +
`homelab.sthomas.ch/edge=true:NoSchedule` on the Pi.

Namespaces are **not pinned to a node** — pods schedule wherever there is room,
so adding a node lets it pick up work with no per-repo edits. The Pi is kept out
by its taint, which nothing tolerates by default, and anything with a
`local-path` PVC is fixed to one node anyway by the PV's `nodeAffinity`.

### Running a workload on the Pi

Annotate the app's namespace. **Both** annotations are needed: the selector
picks the node, the toleration gets past the `NoSchedule` taint. With only the
selector, pods stay `Pending` forever.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
  annotations:
    scheduler.alpha.kubernetes.io/node-selector: "homelab.sthomas.ch/location=home"
    scheduler.alpha.kubernetes.io/defaultTolerations: >-
      [{"key":"homelab.sthomas.ch/edge","operator":"Equal",
        "value":"true","effect":"NoSchedule"}]
```

The Pi is **arm64**, so every image in that namespace needs an `arm64` variant
(build with `docker buildx --platform linux/amd64,linux/arm64`). A
manifest-list image works on both nodes unchanged.

Ingress is unaffected: Traefik stays on the VPS and reaches Pi pods over the
flannel-on-tailscale mesh, so an `HTTPRoute` for a Pi workload looks like any
other.

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

- Debian 12/13 or Ubuntu Server 24.04 (the Pi: Ubuntu Server arm64), freshly
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
| `SSH_PRIVATE_KEY` | private key with passwordless-`sudo` SSH access to the nodes |
| `SSH_KNOWN_HOSTS` | `ssh-keyscan kube-cp-01.ts.homelab.sthomas.ch homelab.sthomas.ch` output (optional) |
| `ANSIBLE_SSH_USER` | your SSH user, e.g. `sebas` |
| `SSH_HOST` | `kube-cp-01.ts.homelab.sthomas.ch` (tailnet) — `homelab.sthomas.ch` before the tailnet exists |
| `KUBE_API` | `https://kube-cp-01.ts.homelab.sthomas.ch:6443` (tailnet) |
| `HEADSCALE_URL` | `https://headscale.homelab.sthomas.ch` |
| `K3S_TOKEN` | `openssl rand -hex 32` — the cluster join secret |
| `HEADPLANE_COOKIE_SECRET` | `openssl rand -hex 16` (exactly 32 chars; set after first deploy) |
| `HEADPLANE_API_KEY` | `headscale apikeys create --expiration 8760h` output (set after first deploy) |
| `TS_AUTHKEY` | Headscale pre-auth key for CI runners — `--reusable --ephemeral --expiration 8760h` (not `100y` — a headscale upgrade can reject those). Same value in every app repo. |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password (optional — `bootstrap.sh` generates a random one otherwise) |
| `GRAFANA_ADMIN_USER` | Grafana admin username (optional, defaults to `admin`) |
| `TS_AUTHKEY_GRAFANA` | Headscale pre-auth key for the Grafana tailnet node, issued for the **`services`** user — `--reusable --expiration 8760h` (**not** `--ephemeral`). Without it Grafana has no way in at all. |
| `ACME_DNS_JSON` | acme-dns accounts for the DNS-01 wildcard cert — one combined JSON `{ "<zone>": {username,password,fulldomain,subdomain,allowfrom}, … }`. `deploy` writes it to Secret `cert-manager/acme-dns`. See [DNS](#2-dns). |

> GitHub masks secret values in workflow logs, so `SSH_HOST` / `KUBE_API` etc.
> show up as `***` in run output — expected.

### 2. DNS

In your `sthomas.ch` zone, point the `homelab` subtree at the VPS (plain
A/CNAME — **no Cloudflare proxy**, it breaks the Tailscale control protocol):

| Name | Type | Value | Covers |
|---|---|---|---|
| `homelab.sthomas.ch` | CNAME (or A) | `h2977839.stratoserver.net` (or `81.169.131.24`) | the K3s API on `:6443` |
| `*.homelab.sthomas.ch` | CNAME | `homelab.sthomas.ch` | Headscale + every public app — one wildcard, no per-app records |

No wildcard support at your DNS host? Add a CNAME per name instead
(`headscale.homelab.sthomas.ch`, then one per app, all → `homelab.sthomas.ch`).

`ts.homelab.sthomas.ch` (the MagicDNS base domain) needs **no** record — it is
answered inside the tailnet only. Tailnet-only services live there: **Grafana is
`grafana.ts.homelab.sthomas.ch`**, and that name is not a DNS record at all —
it is a *Tailscale node*. The `grafana-tailnet` pod joins the tailnet as the
node `grafana`, so MagicDNS answers with the pod's own `100.64.0.0/10` address
and the only route to it is a WireGuard session. Traefik has no route for
Grafana, and no port on the VPS leads there. Its `_acme-challenge` name *is*
delegated, though — see below.

**TLS delegation.** Traefik serves one cert-manager DNS-01 *wildcard* cert. If
your DNS host has no ACME API (wint.global, Strato, …), CNAME-delegate the
challenge names to [acme-dns](https://github.com/joohoi/acme-dns):

1. Register once per zone: `curl -sX POST https://auth.acme-dns.io/register`
   (save each JSON). One account per `_acme-challenge.<zone>` name — the
   apex + `*` of the same zone share one; more than 2 challenges on one account
   collide (acme-dns keeps the last 2 TXT).
2. At your DNS host: `_acme-challenge.sthomas.ch`,
   `_acme-challenge.homelab.sthomas.ch`,
   `_acme-challenge.ts.homelab.sthomas.ch`, … → the returned
   `<uuid>.auth.acme-dns.io`. The `ts.` one is for `*.ts.homelab.sthomas.ch`,
   the cert the tailnet-only services serve themselves (Grafana today) — the
   *challenge* record is public even though the names it certifies are not, and
   so is the issued cert: Let's Encrypt publishes every name to the CT logs, so
   treat a MagicDNS name as unlisted, never as secret.
3. Combine the JSONs keyed by zone and store as the **`ACME_DNS_JSON`**
   Environment secret (the `deploy` workflow writes it to `cert-manager/acme-dns`):
   ```bash
   jq -n '{ "sthomas.ch": input, "homelab.sthomas.ch": input }' ~/acmedns-sthomas.json ~/acmedns-homelab.json | pbcopy
   ```
   **Adding a zone later, without rebuilding the whole thing** (dropping a zone
   here breaks issuance for every name that used it) — read the live secret,
   merge, put it back:
   ```bash
   kubectl -n cert-manager get secret acme-dns -o jsonpath='{.data.acmedns\.json}' | base64 -d \
     | jq --slurpfile new ~/acmedns-<zone>.json '. + {"<zone>": $new[0]}' > ~/acmedns-all.json
   ```
   Two zones may share one account (same object under both keys) — but only
   while their combined challenge count stays ≤ 2.
   Do this **before** deploying a `Certificate` that needs the new zone
   (`gateway-certs.yaml` for public names, `monitoring/tailnet-certificate.yaml`
   for the tailnet ones): cert-manager re-orders a cert whenever its name list
   changes, and an undelegated zone makes that order fail (the last good cert
   keeps serving, but stops renewing).

See [`docs/gateway-api.md`](docs/gateway-api.md#tls) and
`kubernetes/infrastructure/cert-manager/`.

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
Headscale/Headplane → monitoring (VictoriaMetrics/Logs + Grafana) → the shared
`app-deployer` identity. Apps deploy themselves from their own repos.

### 5b. HTTP routing

Inside the cluster, routing is **Gateway API** — `HTTPRoute` objects attach to a
shared `traefik-gateway` served by the K3s-bundled Traefik (Gateway API CRDs
ship with K3s). See [`docs/gateway-api.md`](docs/gateway-api.md).

At the edge: **Traefik is the public edge**. `service.spec.type: LoadBalancer`
→ K3s ServiceLB (klipper) binds the host's `:80`/`:443` straight to Traefik;
`ports.web.redirectTo` sends HTTP → HTTPS. TLS terminates on one cert-manager
DNS-01 **wildcard** cert (`gateway-tls`, `*.sthomas.ch` + `*.homelab.sthomas.ch`),
so a new hostname needs nothing at the edge.

### 6. Finish Headscale

Headplane needs an API key that only exists once headscale runs — do the
[bootstrap dance](kubernetes/infrastructure/headscale/README.md#first-time-bootstrap-the-api-key-dance):
generate the key, set `HEADPLANE_API_KEY` + `HEADPLANE_COOKIE_SECRET`, re-run
`deploy`. Then:

```bash
curl -sf https://headscale.homelab.sthomas.ch/health   # -> 200
```

and open `…/admin`.

### 7. Grafana

`deploy` brings up VictoriaMetrics + VictoriaLogs + Grafana (~40 dashboards, VM
and VL datasources pre-wired) at **`https://grafana.ts.homelab.sthomas.ch` —
tailnet only, enforced**: the `grafana-tailnet` pod is a Tailscale node and
terminates TLS itself, Grafana has no HTTPRoute, and nothing on the public IP
answers for it. Needs `TS_AUTHKEY_GRAFANA` (above) on the first run. Off the
tailnet, `kubectl -n monitoring port-forward
svc/victoria-metrics-k8s-stack-grafana 3000:80`. Log in as `admin`:

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

(or set `GRAFANA_ADMIN_PASSWORD` in the `production` Environment before the run).

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

**The app lives entirely in its own repo** — namespace, Deployment, Service,
HTTPRoute, optional DB — and deploys itself on tag. homelab-infra carries no
per-app config; it just provides the shared `app-deployer` identity (one
`KUBE_TOKEN` for every app), the Gateway, cert-manager and the CNPG operator.

Copy [`kubernetes/apps/_template`](kubernetes/apps/README.md) into your app repo
as `deploy/`, add a `release.yml` that calls
[`SebastianThomas/homelab-actions`](https://github.com/SebastianThomas/homelab-actions)
(`headscale-connect` + `kube-deploy`), set the repo's `production` secrets, push a
tag. Live example: [`SebastianThomas/genie-web`](https://github.com/SebastianThomas/genie-web).
Full walkthrough: [`kubernetes/apps/README.md`](kubernetes/apps/README.md).

## Where things live

| | |
|---|---|
| `kubernetes/infrastructure/` | cluster-wide services (Gateway/Traefik, TLS, DB operator, Headscale, monitoring, app-deployer) |
| `kubernetes/apps/_template/` | copy-paste source for an app repo's `deploy/` |
| the app's own repo | **everything** for that app |

Ansible never deploys anything under `kubernetes/`.

---

## Private API access over Tailscale

`kube-cp-01` runs a standalone `tailscaled` on the Headscale tailnet
(`100.64.0.2`), so `kubectl` — yours and CI's — reaches the API by its MagicDNS
name and public `:6443` is firewalled off:

- API cert carries `kube-cp-01.ts.homelab.sthomas.ch` + `100.64.0.2` (Ansible,
  from `k3s_cp_tailscale_ip`).
- `KUBE_API` / `SSH_HOST` secrets point at the MagicDNS name; CI runners join
  the tailnet per-run with a `--reusable --ephemeral` Headscale key (`TS_AUTHKEY`).
- The `firewall` role deletes the public `:6443` rule and trusts `tailscale0`
  wholesale. `:22`/`:80`/`:443` stay public. Emergency access if the tailnet
  breaks: `ssh <user>@homelab.sthomas.ch` → `sudo kubectl …`, or
  `sudo ufw allow 6443/tcp`.

## Adding a worker node

A worker's pod traffic rides the tailnet (flannel on `tailscale0`), so the node
must be on the tailnet *before* Ansible touches it. `kube-worker-01` (the Pi) is
already in the inventory — for another node, copy that block.

**On the node** (console / LAN — Ansible can't reach it yet):

```bash
# 1. hostname = inventory name, BEFORE tailscale registers it
sudo hostnamectl set-hostname kube-worker-01

# 2. the ops user Ansible logs in as (name = your ANSIBLE_SSH_USER secret)
sudo adduser --disabled-password --gecos "" <user>
sudo usermod -aG sudo <user>
echo '<user> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/<user>
sudo install -d -m700 -o <user> -g <user> /home/<user>/.ssh
echo '<public key matching the SSH_PRIVATE_KEY secret>' | sudo tee /home/<user>/.ssh/authorized_keys
sudo chown <user>:<user> /home/<user>/.ssh/authorized_keys && sudo chmod 600 "$_"

# 3. join the tailnet (Headscale pre-auth key: `headscale preauthkeys create
#    --user 1 --reusable --expiration 8760h`). --accept-dns=false keeps the
#    node's own resolver; --advertise-exit-node because it's also an exit node.
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --login-server=https://headscale.homelab.sthomas.ch \
  --authkey=<key> --hostname=kube-worker-01 \
  --accept-dns=false --advertise-exit-node
tailscale ip -4      # note this - it goes in the inventory
```

**On kube-cp-01** — approve the node's advertised routes (`--advertise-exit-node`
= `0.0.0.0/0,::/0`). The pod CIDR needs *no* route: flannel's VXLAN is wrapped in
node-to-node tailnet traffic, which tailscale already carries.

```bash
sudo k3s kubectl -n headscale exec deploy/headscale -- headscale nodes list
sudo k3s kubectl -n headscale exec deploy/headscale -- \
  headscale nodes approve-routes -i <id> -r 0.0.0.0/0,::/0
# also expire the pre-auth key now it has registered (it's reusable):
sudo k3s kubectl -n headscale exec deploy/headscale -- headscale preauthkeys expire -i <key-id>
```

**Then, as code:**

1. Put the node's tailnet IP in its inventory block (`node_ip:`), commit.
2. Run **`provision` `limit: k3s_cp`** first — adds `flannel-iface: tailscale0`
   and restarts k3s (~1 min; running pods and Traefik keep serving). The CP's
   node InternalIP moves to `100.64.0.2` — cosmetic, klipper still serves
   `:80`/`:443` on the public IP. Take a `/var/lib/rancher/k3s` backup first
   (see [Backups](#backups)).
3. Run **`provision` `limit: kube-worker-01`** — Pi prereqs (memory cgroup on
   `/boot/firmware/cmdline.txt` + a reboot, `vxlan` module), the agent (joins
   over `https://100.64.0.2:6443` with `node-name` pinned to the inventory
   name), IP forwarding + UDP-GRO tuning for the exit node, and a
   `~/.kube/config` for the login user pointing at the CP over the tailnet.
   It also wipes stale agent state / deletes an old node object if the Pi first
   registered under its image hostname.
4. Verify: `kubectl get nodes -o wide` (`kube-worker-01` `Ready`), then a
   tolerating test pod:

   ```bash
   kubectl run pi-test --image=busybox --restart=Never --rm -it \
     --overrides='{"spec":{"nodeSelector":{"homelab.sthomas.ch/location":"home"},
     "tolerations":[{"key":"homelab.sthomas.ch/edge","operator":"Exists"}]}}' \
     -- sh -c 'nslookup kubernetes.default.svc.cluster.local && wget -qO- -T5 -S https://kubernetes.default/healthz --no-check-certificate 2>&1 | head -1'
   ```

   (DNS resolves + a `401` from the API both mean cross-node pod networking works.)

**Scheduling onto it:** nothing lands on the Pi unless it opts in. A namespace
does that with the annotations in
[`kubernetes/apps/_template/namespace.yaml`](kubernetes/apps/_template/namespace.yaml)
(`location=home` selector + the `edge` toleration).

### If the tailnet is down when kube-cp-01 boots

`flannel-iface: tailscale0` means k3s waits (up to 90 s, systemd `ExecStartPre`)
for `tailscale0` before starting. A genuine Tailscale outage at boot leaves k3s
`failed` after the retry budget (`10-startlimit.conf`). Running pods (Traefik
included) keep serving through it. Recover with:

```bash
sudo systemctl restart tailscaled
sudo systemctl reset-failed k3s && sudo systemctl start k3s
```

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
