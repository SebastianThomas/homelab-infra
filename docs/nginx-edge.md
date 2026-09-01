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

## 2. nginx vhost for cluster hostnames

One file, additive — your existing vhosts are untouched.

`/etc/nginx/sites-available/homelab-cluster` (symlink into `sites-enabled/`):

```nginx
# top of the file, or in /etc/nginx/conf.d/upgrade-map.conf if not already present
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 80;
    listen [::]:80;
    server_name headscale.homelab.sthomas.ch;   # one server_name per cluster app, or use *.homelab.sthomas.ch
    location / { return 301 https://$host$request_uri; }

    # Keep this only if you want cert-manager to keep renewing its in-cluster
    # certs (pre-warm for the eventual flip); harmless to omit.
    location /.well-known/acme-challenge/ {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host $host;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name headscale.homelab.sthomas.ch;

    ssl_certificate     /etc/letsencrypt/live/genie-web.sthomas.ch/fullchain.pem;  # updated by `certbot --expand` in step 3
    ssl_certificate_key /etc/letsencrypt/live/genie-web.sthomas.ch/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    location / {
        proxy_pass http://10.43.66.94:80;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # Headscale control protocol: long-lived upgraded POST
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/homelab-cluster /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

> `listen 443 ssl http2;` is the inline form for nginx < 1.25.1 (the VM runs
> 1.24). On newer nginx use `listen 443 ssl;` + a separate `http2 on;`.

The `proxy_*` timeout/upgrade/buffering directives matter for **headscale** (and
websocket apps). Plain HTTP apps don't need them — for those a bare
`location / { proxy_pass http://10.43.66.94:80; proxy_set_header Host $host; ... }`
is enough. Traefik does the per-host + per-path routing from there via the
`HTTPRoute` objects.

If you ever need to re-check the ClusterIP:

```bash
sudo k3s kubectl -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}'
```

(it's pinned in `helmchartconfig.yaml`, so it should not move).

## 3. Certificate

Fits your existing certbot flow — add the hostname to the live cert:

```bash
sudo certbot --nginx --expand -d headscale.homelab.sthomas.ch -d grafana.homelab.sthomas.ch
```

(one `-d` per cluster host — `headscale`, `grafana`, then one per app; or
`--expand` again later). Auto-renews
with the timer you already have. A wildcard `*.homelab.sthomas.ch` is nicer but
needs DNS-01 → delegating `homelab.sthomas.ch` to a provider with an API
(deSEC/Cloudflare, free) — optional.

## 4. Verify

```bash
curl -sS https://headscale.homelab.sthomas.ch/health          # -> ok, valid cert
kubectl -n headscale exec deploy/headscale -- headscale nodes list
```

Existing sites: `curl -sI https://genie-web.sthomas.ch` etc. — back to normal.

## Adding a cluster app (in this mode)

1. `kubernetes/apps/<name>/` as usual — its `HTTPRoute` attaches to
   `traefik-gateway` (nothing about it is edge-specific).
2. Add `<name>.homelab.sthomas.ch` to the nginx `homelab-cluster` vhost (or rely
   on a `*.homelab.sthomas.ch` block) and `certbot --expand -d <name>...`.
3. DNS: `<name>.homelab.sthomas.ch` → the VM (covered by a wildcard if you have one).

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
