# Public routing: host nginx in front of K3s

> **HISTORICAL.** Traefik is now the public edge — `service.spec.type:
> LoadBalancer`, a `websecure` HTTPS listener, and cert-manager gateway certs
> (`infrastructure/cert-manager/gateway-certs.yaml`). nginx + certbot on the VPS
> are stopped. This doc is kept for the design rationale and the flip runbook
> ([last section](#flip-to-traefik-as-edge-done)). A few `-dev` docker-compose
> stacks (std-dive-logger, sonar-protocol, start-hack) were left un-migrated and
> are offline until moved into the cluster.

## Background (nginx-edge mode)

The Strato VM (`kube-cp-01`) ran **nginx + certbot** for ~13 `*.sthomas.ch`
sites reverse-proxying to local docker-compose apps. K3s was added on the same
box, and its bundled Traefik + ServiceLB (klipper) grabs the host's `:80`/`:443`
via iptables DNAT — which took traffic away from nginx and broke those sites.

So while the legacy apps were still on docker-compose: **nginx stayed the public
edge**, Traefik demoted to an internal backend reachable only on its ClusterIP.

```
Internet :80/:443
  → nginx (host, certbot)
      ├─ genie-web / kochbuch / … .sthomas.ch   → localhost:<docker port>          (unchanged)
      └─ *.homelab.sthomas.ch                    → 10.43.66.94:80  → Traefik → HTTPRoute → Service → Pod
```

Routing inside the cluster is **Gateway API** (`HTTPRoute` → the shared
`traefik-gateway`) — see [`gateway-api.md`](gateway-api.md). That's independent
of this edge setup: nginx proxies to the same Traefik `web` entrypoint either
way.

`10.43.66.94` is Traefik's **ClusterIP**, pinned in
`infrastructure/traefik/helmchartconfig.yaml`. Reachable from the host because
the node is in the cluster (kube-proxy programs the ClusterIP). Nothing is
published on a host port, so there is nothing extra to firewall.

## 1. Apply the Traefik config

`infrastructure/traefik/helmchartconfig.yaml` sets `service.spec.type: ClusterIP`
(klipper stops hijacking the ports) with the ClusterIP pinned.

> The Traefik chart (v40, bundled with K3s) renders the Service spec straight
> from `service.spec`. A top-level `service.type` is **silently ignored** — it
> must be `service.spec.type`. Likewise never set `ports.web.hostIP`: the chart
> feeds it into the entrypoint listen address and Traefik ends up bound to the
> pod's loopback, unreachable by kube-proxy or nginx.

```bash
# deploy workflow, or:
kubectl apply -k kubernetes/infrastructure/traefik
```

klipper removes its `svclb-traefik` DaemonSet once the Service is no longer
`LoadBalancer`. Check, and force it if it lingers:

```bash
sudo k3s kubectl -n kube-system get svc traefik          # TYPE should be ClusterIP
sudo k3s kubectl -n kube-system get ds
sudo k3s kubectl -n kube-system delete ds -l svccontroller.k3s.cattle.io/svcname=traefik   # if still there
```

Confirm the port hijack is gone and Traefik answers on its ClusterIP:

```bash
sudo iptables -t nat -S PREROUTING | grep -E '3[0-9]{4}'          # klipper DNAT rules -> empty
sudo ss -tlnp | grep -E ':(80|443)\s'                             # 80/443 -> nginx only
curl -sI -H 'Host: headscale.homelab.sthomas.ch' http://10.43.66.94/   # -> 200/301/404 from Traefik, not 000
```

- Stale klipper `PREROUTING ... --dport 443 -j DNAT` rule survives a config
  change: `sudo systemctl restart k3s` (its shutdown cleans klipper rules), or
  delete the rule by hand.
- `curl http://10.43.66.94` returns `000` (connection refused): the Traefik pod
  is likely still the old one bound to loopback — `kubectl -n kube-system
  rollout restart deploy traefik` and recheck `ss` inside the pod.

## 2. nginx vhosts for cluster hostnames

Two additive files — your existing `*.sthomas.ch` vhosts are untouched.

### `homelab-cluster-wildcard` — the catch-all (set up once)

`/etc/nginx/sites-available/homelab-cluster-wildcard`, symlinked into
`sites-enabled/`. A `*.homelab.sthomas.ch` server that proxies everything to
Traefik — **a new cluster app needs no nginx change**, only a cert `--expand`
(step 3). Exact-name vhosts (below) still win over it.

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name *.homelab.sthomas.ch;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name *.homelab.sthomas.ch;

    ssl_certificate     /etc/letsencrypt/live/homelab-cluster/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/homelab-cluster/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    location / {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout  120s;
        proxy_send_timeout  120s;
    }
}
```

> `listen 443 ssl;` (not `... ssl http2;`) matches the legacy vhosts and avoids
> nginx's "protocol options redefined" warning. nginx 1.24 has no `http2 on;`.

### `homelab-cluster` — exact-name overrides

Only for hosts that need special proxy behaviour. **Headscale** does — its
control protocol is a long-lived upgraded POST:

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 80; listen [::]:80;
    server_name headscale.homelab.sthomas.ch;
    location / { return 301 https://$host$request_uri; }
}
server {
    listen 443 ssl; listen [::]:443 ssl;
    server_name headscale.homelab.sthomas.ch;
    ssl_certificate     /etc/letsencrypt/live/headscale.homelab.sthomas.ch/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/headscale.homelab.sthomas.ch/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    location / {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }
}
```

Most apps (Grafana included) are fine on the wildcard block and need no entry here.

### `sthomas.ch` + `dev.sthomas.ch` — a cluster app on the *main* domain

Some apps live on `*.sthomas.ch` (or the apex) rather than `*.homelab.sthomas.ch`,
so the wildcard block can't catch them — they need an exact-name vhost. The
`sthomas.ch` site (namespaces `sthomas-ch-prod` / `sthomas-ch-dev`, repo
`SebastianThomas/sthomas.ch`) replaced its old `docker-compose` vhost
(`localhost:8101` / `:8102`) with this. TLS stays on the existing
`genie-web.sthomas.ch` certbot cert, which already lists both names — **no cert
change needed**.

Replaces `/etc/nginx/sites-available/dev.sthomas.ch` (the file holds both):

```nginx
server {
    server_name sthomas.ch;
    location / {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/genie-web.sthomas.ch/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/genie-web.sthomas.ch/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
server {
    server_name dev.sthomas.ch;
    location / {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    listen 443 ssl; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/genie-web.sthomas.ch/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/genie-web.sthomas.ch/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
server {
    if ($host = dev.sthomas.ch) { return 301 https://$host$request_uri; } # managed by Certbot
    server_name dev.sthomas.ch;
    listen 80;
    return 404; # managed by Certbot
}
server {
    if ($host = sthomas.ch) { return 301 https://$host$request_uri; } # managed by Certbot
    server_name sthomas.ch;
    listen 80;
    return 404; # managed by Certbot
}
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

If you ever need to re-check the ClusterIP:

```bash
sudo k3s kubectl -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}'
```

(it's pinned in `helmchartconfig.yaml`, so it should not move).

## 3. Certificate

The wildcard block serves a cert named **`homelab-cluster`** — a SAN cert you
grow one hostname at a time (`server_name *.homelab…` can't present a name the
cert doesn't carry, and Strato has no ACME DNS API for a real wildcard cert):

```bash
# first app:
sudo certbot certonly --nginx --cert-name homelab-cluster -d grafana.homelab.sthomas.ch
# each later app - list ALL names again, with --expand:
sudo certbot certonly --nginx --cert-name homelab-cluster --expand \
  -d grafana.homelab.sthomas.ch -d <newapp>.homelab.sthomas.ch
```

`certonly` = get/renew the cert, don't let certbot rewrite the hand-managed
vhost. Auto-renews via the existing systemd timer (`authenticator = nginx`).
Headscale keeps its own single-name cert (`headscale.homelab.sthomas.ch`).

A true wildcard cert would end the per-app step — it needs DNS-01, i.e.
delegating `homelab.sthomas.ch` to a provider with an ACME API (deSEC /
Cloudflare, free). Optional, later.

## 4. Verify

```bash
curl -sS https://headscale.homelab.sthomas.ch/health          # -> ok, valid cert
kubectl -n headscale exec deploy/headscale -- headscale nodes list
```

Existing sites: `curl -sI https://genie-web.sthomas.ch` etc. — back to normal.

## Adding a cluster app (in this mode)

1. `kubernetes/apps/<name>/` as usual — its `HTTPRoute` attaches to
   `traefik-gateway` (nothing about it is edge-specific).
2. Grow the cert — `certbot certonly --nginx --cert-name homelab-cluster --expand
   -d <every existing name> -d <name>.homelab.sthomas.ch`. **No nginx edit** (the
   wildcard vhost already covers it), unless the app needs special proxy
   behaviour → add an exact-name block to `homelab-cluster`.
3. DNS: covered by the `*.homelab.sthomas.ch` wildcard.

## Flip to Traefik-as-edge (DONE)

What was applied, in order. All hostnames the cluster serves at the edge are in
the two `Certificate`s in `infrastructure/cert-manager/gateway-certs.yaml`.

### 1. As-code (merged to `main`, applied by the deploy workflow)

- `infrastructure/traefik/helmchartconfig.yaml`:
  - `service.spec.type: LoadBalancer` (clusterIP kept pinned — harmless)
  - `gateway.listeners.websecure` — HTTPS :8443, `certificateRefs`
    `[gateway-tls-homelab, gateway-tls-public]`
  - `ports.web.redirectTo.port: websecure` — HTTP→HTTPS at the entrypoint
- `infrastructure/cert-manager/gateway-certs.yaml` — the two `Certificate`s
  (`kind: Certificate`, HTTP-01 via Traefik's Ingress provider — no Gateway
  annotation needed).
- Each app repo's `HTTPRoute` grew its bare `*.sthomas.ch` name alongside the
  `*.homelab.sthomas.ch` one (`genie-web`, `kochbuch`, `hansenberg-*`).

Both certs start `Ready=False` — the nginx wildcard vhost serves ACME
challenges from a local webroot (for the old certbot cert), not Traefik.

### 2. Pre-verify routing + pre-warm the homelab cert (nginx still the live edge)

Check every hostname routes through Traefik:

```bash
for h in sthomas.ch dev.sthomas.ch genie-web.sthomas.ch kochbuch.sthomas.ch \
         hansenberg-alumni-map.sthomas.ch grafana.homelab.sthomas.ch \
         headscale.homelab.sthomas.ch; do
  printf '%s -> ' "$h"; curl -s -o /dev/null -w '%{http_code}\n' \
    -H "Host: $h" http://10.43.66.94/
done   # each -> 200/301/302, not 000/404
```

Point the wildcard vhost's ACME location at Traefik so `gateway-tls-homelab`
issues *before* the flip (grafana / headscale / `*.homelab` then keep a valid
cert across it). In `/etc/nginx/sites-available/homelab-cluster-wildcard`,
change the `:80` server's

```nginx
    location /.well-known/acme-challenge/ { root /var/www/html; }
```

to

```nginx
    location /.well-known/acme-challenge/ {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host $host;
    }
```

```bash
sudo nginx -t && sudo systemctl reload nginx
kubectl -n kube-system get certificate -w      # gateway-tls-homelab -> Ready=True (~1-2 min)
```

`gateway-tls-public` (the bare `*.sthomas.ch` names) still can't validate until
the flip — those get a ~2–4 min cert warning in step 3. Pre-warm them too by
adding the same `location` to each bare-name vhost if that matters.

### 3. The flip (one maintenance window, ~2–4 min of imperfect TLS)

```bash
sudo systemctl stop nginx
# klipper svclb-traefik now binds :80/:443. Force it if it lingers:
sudo k3s kubectl -n kube-system delete pod -l svccontroller.k3s.cattle.io/svcname=traefik
sudo ss -tlnp | grep -E ':(80|443)\s'          # -> the svclb process, not nginx
# gateway-tls-public completes now that ACME challenges reach Traefik:
sudo k3s kubectl -n kube-system get certificate -w   # gateway-tls-public -> Ready=True
```

Verify, then make it permanent:

```bash
curl -sI https://sthomas.ch                         # 200, valid LE cert
curl -sI https://grafana.homelab.sthomas.ch
curl -sS https://headscale.homelab.sthomas.ch/health
sudo systemctl disable --now nginx certbot.timer
```

Rollback: `sudo systemctl start nginx` (svclb loses the ports, nginx retakes
them), then revert `service.spec.type` to `ClusterIP` and redeploy.

### 4. Leftovers

- `/etc/nginx/sites-*` and the host certbot certs are now dead — remove at
  leisure.
- The un-migrated `-dev` compose stacks (`/root/std-dive-logger`,
  `/root/sonar-protocol-backend`, `/root/start-hack-backend`) keep running but
  are unreachable (no route). Migrate into the cluster, then
  `docker compose down` + delete the dirs.
