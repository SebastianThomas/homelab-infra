# Public routing: host nginx in front of K3s

The Strato VM (`kube-cp-01`) already runs **nginx + certbot** for ~13
`*.sthomas.ch` sites that reverse-proxy to local docker-compose apps. K3s was
added on the same box, and its bundled Traefik + ServiceLB (klipper) grabs the
host's `:80`/`:443` via iptables DNAT — which takes the traffic away from nginx
and breaks those sites.

So: **nginx stays the public edge.** Traefik is demoted to an internal backend.

```
Internet :80/:443
  → nginx (host, certbot)
      ├─ genie-web / kochbuch / … .sthomas.ch      → localhost:<docker port>   (unchanged)
      └─ *.homelab.sthomas.ch                       → 127.0.0.1:8081  → Traefik → Ingress → Service → Pod
```

The repo change for this is one file: `infrastructure/traefik/helmchartconfig.yaml`
sets `service.type: ClusterIP` (klipper stops hijacking the ports) and binds
Traefik's HTTP entrypoint to `127.0.0.1:8081`.

## 1. Apply it

```bash
# deploy workflow, or:
kubectl apply -k kubernetes/infrastructure/traefik
```

klipper should remove its `svclb-traefik` DaemonSet when it sees the service is
no longer `LoadBalancer`. Check, and force it if it lingers:

```bash
sudo k3s kubectl -n kube-system get ds
sudo k3s kubectl -n kube-system delete ds -l svccontroller.k3s.cattle.io/svcname=traefik   # if still there
```

Confirm the port hijack is gone and Traefik is on loopback:

```bash
sudo iptables -t nat -S PREROUTING | grep -E '3[0-9]{4}'   # klipper DNAT rules -> should be empty
sudo ss -tlnp | grep -E ':(8081|80|443)\s'                 # 8081 -> 127.0.0.1 (traefik); 80/443 -> nginx
```

- Stale klipper `PREROUTING ... --dport 443 -j DNAT` rule survives:
  `sudo systemctl restart k3s` (its shutdown cleans klipper rules), or delete it
  by hand.
- `8081` shows `0.0.0.0` instead of `127.0.0.1` (chart ignored `hostIP`): it's
  not publicly routable through the K3s FORWARD chain in practice, but to be
  safe add `firewall_allow_rules` nothing for it and, if paranoid,
  `sudo ufw deny 8081/tcp`. Or proxy nginx to the Traefik ClusterIP instead
  (`kubectl -n kube-system get svc traefik` → `proxy_pass http://<clusterIP>;`).

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

    # keep this only if you want cert-manager to keep renewing its in-cluster
    # certs (pre-warm for the eventual flip); harmless to omit.
    location /.well-known/acme-challenge/ {
        proxy_pass http://127.0.0.1:8081;
        proxy_set_header Host $host;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name headscale.homelab.sthomas.ch;

    ssl_certificate     /etc/letsencrypt/live/genie-web.sthomas.ch/fullchain.pem;  # updated by `certbot --expand` in step 3
    ssl_certificate_key /etc/letsencrypt/live/genie-web.sthomas.ch/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;

    location / {
        proxy_pass http://127.0.0.1:8081;
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

The `proxy_*` timeout/upgrade/buffering directives matter for **headscale** (and
websocket apps). Plain HTTP apps don't need them — for those a bare
`location / { proxy_pass http://127.0.0.1:8081; proxy_set_header Host $host; ... }`
is enough. Traefik does the per-host + per-path routing from there via the
Ingress objects.

## 3. Certificate

Fits your existing certbot flow — add the hostname to the live cert:

```bash
sudo certbot --nginx --expand -d headscale.homelab.sthomas.ch
```

(one `-d` per cluster app; or `-d app1... -d app2...` in one go). Auto-renews
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

1. `kubernetes/apps/<name>/` as usual (its `Ingress` still uses
   `ingressClassName: traefik`; the `tls:` block + `cert-manager.io` annotation
   are inert here but harmless — leave or drop them).
2. Add `<name>.homelab.sthomas.ch` to the nginx `homelab-cluster` vhost (or rely
   on a `*.homelab.sthomas.ch` block) and `certbot --expand -d <name>...`.
3. DNS: `<name>.homelab.sthomas.ch` → the VM (covered by a wildcard if you have one).

## Flip to Traefik-as-edge (later, when the legacy docker apps are gone)

1. `infrastructure/traefik/helmchartconfig.yaml`: `service.type: LoadBalancer`;
   `ports.web` → `hostPort: 80` (drop `hostIP`); add `ports.websecure.hostPort: 443`.
2. Ensure every cluster `Ingress` has `tls:` + `cert-manager.io/cluster-issuer:
   letsencrypt-prod` (re-add if you dropped them). cert-manager is still
   installed and issues per-host certs.
3. `deploy`. Confirm `https://headscale.homelab.sthomas.ch` serves a
   cert-manager cert.
4. `sudo systemctl disable --now nginx certbot.timer`.

If you kept the `/.well-known/acme-challenge/` forward in step 2, cert-manager
has been renewing its certs all along and there's zero HTTPS gap at the flip.
