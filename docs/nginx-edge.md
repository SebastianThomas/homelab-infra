# Public routing: host nginx in front of K3s

The Strato VM (`kube-cp-01`) already runs **nginx + certbot** for ~13
`*.sthomas.ch` sites that reverse-proxy to local docker-compose apps. K3s was
added on the same box, and its bundled Traefik + ServiceLB (klipper) grabs the
host's `:80`/`:443` via iptables DNAT — which takes the traffic away from nginx
and breaks those sites.

So: **nginx stays the public edge.** Traefik is demoted to an internal backend
reachable only on its ClusterIP.

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

## Flip to Traefik-as-edge (later, when the legacy docker apps are gone)

1. `infrastructure/traefik/helmchartconfig.yaml`:
   - `service.spec.type: LoadBalancer` (drop the pinned `clusterIP`)
   - `ports.web` → add `hostPort: 80`; `ports.websecure` → add `hostPort: 443`
     (no `hostIP`)
   - add a `websecure` HTTPS listener to `gateway.listeners` with
     `certificateRefs` pointing at a Secret, and annotate the Gateway with
     `cert-manager.io/cluster-issuer: letsencrypt-prod` — cert-manager then
     fills that Secret (HTTP-01 solver still uses a temporary Ingress, which
     Traefik's Ingress provider serves). Details in
     [`gateway-api.md`](gateway-api.md#tls-at-the-flip).
2. `deploy`. Confirm `https://headscale.homelab.sthomas.ch` serves a
   cert-manager cert.
3. `sudo systemctl disable --now nginx certbot.timer`.

If you kept the `/.well-known/acme-challenge/` forward in step 1, cert-manager
can pre-warm its certs before the flip for a zero HTTPS gap.
