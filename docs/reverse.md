# Reverse Proxy Setup

Prosody's internal web server listens on port 80 bound to `127.0.0.1` on the host. Point any reverse proxy at `http://127.0.0.1:80` — it routes everything internally: the Jitsi web app, `/http-bind` (BOSH), `/xmpp-websocket`, and `/colibri-ws/` (JVB colibri WebSocket).

**Critical requirements for all proxies:**

- WebSocket `Upgrade` / `Connection` headers must be forwarded
- `X-Forwarded-Proto: https` must be set (Jitsi generates mixed-content URLs without it)
- Read/send timeouts must be at least 900 s (WebSocket connections are long-lived)

`install.sh` writes an nginx vhost automatically when nginx is present. Set `WRITE_NGINX_VHOST=0` to skip it.

---

## Table of Contents

- [Architecture](#architecture)
- [Wildcard Subdomain Rooms](#wildcard-subdomain-rooms)
- [nginx](#nginx)
- [Apache](#apache)
- [Caddy](#caddy)
- [HAProxy](#haproxy)
- [Traefik](#traefik)
- [GitHub Pages / Project Docs Redirects](#github-pages--project-docs-redirects)
- [Firewall](#firewall)

---

## Architecture

```
Client (TLS)
    │
    ▼
Frontend Proxy  (443 → http://127.0.0.1:80)
    │
    ▼
prosody:80  (internal web server — routes by path)
    ├── /               → web:80          (Jitsi web app)
    ├── /http-bind      → prosody:5280    (BOSH signalling)
    ├── /xmpp-websocket → prosody:5280    (XMPP WebSocket)
    └── /colibri-ws/    → jvb:9090        (JVB colibri WebSocket)
```

All four backends run inside Docker on the `meet` internal network. Only port 80 is exposed to the host (bound to `127.0.0.1`).

---

## Wildcard Subdomain Rooms

When `ENABLE_SUBDOMAIN_ROOMS=1`, `room.yourdomain.com` takes the user directly into the Jitsi room named `room`. The design uses two steps to keep browsers, native apps, and the `room.domain/room` edge case all working correctly.

**Two-step flow:**

1. `room.domain/` — the frontend proxy issues a **same-domain 302** to `/room`. Using the same hostname keeps native-app WebSocket sessions alive; a cross-domain redirect to `domain/room` would change the server and break them.
2. `room.domain/room` (and all other paths) — the proxy forwards to prosody with `Host: base_domain`. Prosody serves the correct Jitsi config. The edge case where the URL is already `room.domain/room` hits this block directly — no double-room problem.

**Requires a `*.yourdomain.com` wildcard SSL certificate** on the frontend proxy.

| URL | Behavior |
|-----|----------|
| `room.domain/` | 302 → `room.domain/room` (same host) |
| `room.domain/room` | proxy → prosody → Jitsi room |
| `room.domain/xmpp-websocket` | proxy → prosody WebSocket |
| `room.domain/colibri-ws/...` | proxy → prosody → JVB |

---

## nginx

`install.sh` writes this config to `$NGINX_VHOST_DIR/$PUBLIC_DOMAIN.conf` automatically. The SSL directives are commented out — fill in your certificate paths (or use certbot; see below).

```nginx
# HTTP → HTTPS redirect
server {
    listen 80;
    server_name yourdomain.com *.yourdomain.com;
    return 301 https://$host$request_uri;
}

# Main Jitsi vhost
server {
    listen 443 ssl;
    server_name yourdomain.com;

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Security headers
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy no-referrer always;

    location / {
        proxy_pass         http://127.0.0.1:80;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }
}

# Wildcard subdomain → conference room
# Requires a *.yourdomain.com wildcard SSL cert.
server {
    listen 443 ssl;
    server_name ~^(?P<room>[^.]+)\.yourdomain\.com$;

    ssl_certificate     /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Step 1: root → same-domain redirect to /{room}
    location = / {
        return 302 /$room;
    }

    # Step 2: all other paths → proxy with base domain Host header
    location / {
        proxy_pass         http://127.0.0.1:80;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host              yourdomain.com;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }
}
```

**SSL note — certbot wildcard example:**

```bash
certbot certonly --dns-<provider> \
  -d yourdomain.com \
  -d '*.yourdomain.com'
```

Replace `<provider>` with your DNS plugin (e.g. `cloudflare`, `route53`). Wildcard certificates require a DNS challenge; HTTP challenge cannot issue `*.domain` certs.

---

## Apache

Requires `mod_proxy`, `mod_proxy_http`, `mod_proxy_wstunnel`, `mod_headers`, and `mod_rewrite`.

```apache
# Enable required modules:
# a2enmod proxy proxy_http proxy_wstunnel headers rewrite ssl

<VirtualHost *:80>
    ServerName yourdomain.com
    Redirect permanent / https://yourdomain.com/
</VirtualHost>

<VirtualHost *:443>
    ServerName yourdomain.com

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/yourdomain.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/yourdomain.com/privkey.pem

    # Security headers
    Header always set X-Frame-Options SAMEORIGIN
    Header always set X-Content-Type-Options nosniff
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Referrer-Policy no-referrer

    # WebSocket upgrade
    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) ws://127.0.0.1:80/$1 [P,L]

    ProxyPreserveHost On
    ProxyPass        / http://127.0.0.1:80/
    ProxyPassReverse / http://127.0.0.1:80/

    RequestHeader set X-Forwarded-Proto "https"
    ProxyTimeout 900
</VirtualHost>
```

**Wildcard subdomain rooms with Apache:**

Add a separate VirtualHost with `ServerAlias` and a rewrite rule for the room redirect. Apache regex VirtualHost matching requires `mod_vhost_alias` or explicit aliases — the cleanest approach is a catch-all:

```apache
<VirtualHost *:443>
    ServerName yourdomain.com
    ServerAlias *.yourdomain.com

    SSLEngine on
    SSLCertificateFile    /etc/letsencrypt/live/yourdomain.com/fullchain.pem
    SSLCertificateKeyFile /etc/letsencrypt/live/yourdomain.com/privkey.pem

    RewriteEngine On

    # Extract subdomain into %{ENV:ROOM}
    RewriteCond %{HTTP_HOST} ^([^.]+)\.yourdomain\.com$ [NC]
    RewriteRule ^ - [E=ROOM:%1]

    # Step 1: root path on a subdomain → same-domain redirect to /{room}
    RewriteCond %{HTTP_HOST} ^[^.]+\.yourdomain\.com$ [NC]
    RewriteCond %{REQUEST_URI} ^/?$
    RewriteRule ^ /%{ENV:ROOM} [R=302,L]

    # WebSocket upgrade
    RewriteCond %{HTTP:Upgrade} websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule ^/?(.*) ws://127.0.0.1:80/$1 [P,L]

    # Step 2: proxy everything else with base domain Host header
    ProxyPreserveHost Off
    ProxyPass        / http://127.0.0.1:80/
    ProxyPassReverse / http://127.0.0.1:80/

    RequestHeader set Host "yourdomain.com"
    RequestHeader set X-Forwarded-Proto "https"
    ProxyTimeout 900
</VirtualHost>
```

---

## Caddy

Caddy handles TLS automatically, including wildcards via DNS challenge (no manual cert management needed).

```caddyfile
# Main Jitsi site
yourdomain.com {
    reverse_proxy 127.0.0.1:80

    header {
        X-Frame-Options SAMEORIGIN
        X-Content-Type-Options nosniff
        X-XSS-Protection "1; mode=block"
        Referrer-Policy no-referrer
    }
}

# Wildcard subdomain → conference room
# Caddy handles *.yourdomain.com via DNS-01 challenge (set dns provider in global options)
*.yourdomain.com {
    @root {
        path /
    }
    @room vars {re.subdomain.1} .+

    # Extract subdomain name
    @subdomain host ~^(?P<subdomain>[^.]+)\.yourdomain\.com$

    # Step 1: root → redirect to /{subdomain}
    handle @root {
        redir /{http.regexp.subdomain.subdomain} 302
    }

    # Step 2: everything else → proxy with base domain Host override
    handle {
        reverse_proxy 127.0.0.1:80 {
            header_up Host yourdomain.com
        }
    }
}
```

**Global options for wildcard TLS (DNS challenge):**

```caddyfile
{
    acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}
```

Replace `cloudflare` with your DNS provider module. See [caddyserver.com/docs/automatic-https](https://caddyserver.com/docs/automatic-https) for the full list.

---

## HAProxy

HAProxy supports WebSocket via `timeout tunnel`. SSL termination is done at the frontend.

```
global
    log /dev/log local0
    maxconn 4096

defaults
    log     global
    mode    http
    option  httplog
    timeout connect  5s
    timeout client   900s
    timeout server   900s
    timeout tunnel   1h      # required for WebSocket connections

frontend jitsi_https
    bind *:443 ssl crt /etc/haproxy/certs/yourdomain.com.pem
    default_backend jitsi_back

    # Wildcard subdomain: capture subdomain part
    http-request set-var(req.room) req.hdr(host),regsub('^([^.]+)\.yourdomain\.com$','\1')

    # Step 1: subdomain root → same-domain redirect
    acl is_subdomain hdr_reg(host) -i ^[^.]+\.yourdomain\.com$
    acl is_root      path /
    http-request redirect location /%[var(req.room)] code 302 if is_subdomain is_root

    # Step 2: subdomain non-root → rewrite Host to base domain
    http-request set-header Host yourdomain.com if is_subdomain

    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Forwarded-For %[src]

backend jitsi_back
    server prosody 127.0.0.1:80 check
```

**Note:** HAProxy terminates TLS at the frontend. The PEM file must contain the full chain + private key concatenated:

```bash
cat fullchain.pem privkey.pem > /etc/haproxy/certs/yourdomain.com.pem
```

For wildcard support, use a wildcard cert PEM in the same format.

---

## Traefik

### docker-compose labels approach

Add labels to the prosody service in `docker-compose.yml`, or run Traefik as a separate container:

```yaml
# Traefik static config (traefik.yml)
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"

certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@yourdomain.com
      storage: /letsencrypt/acme.json
      dnsChallenge:
        provider: cloudflare
```

```yaml
# docker-compose.yml labels for a service that maps to prosody:80 externally
# (or a dedicated Traefik-aware proxy container)
services:
  jitsi-proxy:
    image: nginx:alpine          # thin pass-through to 127.0.0.1:80
    labels:
      - "traefik.enable=true"

      # Main domain router
      - "traefik.http.routers.jitsi.rule=Host(`yourdomain.com`)"
      - "traefik.http.routers.jitsi.entrypoints=websecure"
      - "traefik.http.routers.jitsi.tls.certresolver=letsencrypt"
      - "traefik.http.routers.jitsi.middlewares=jitsi-headers"
      - "traefik.http.services.jitsi.loadbalancer.server.port=80"

      # Wildcard subdomain router
      - "traefik.http.routers.jitsi-wild.rule=HostRegexp(`{subdomain:[^.]+}.yourdomain.com`)"
      - "traefik.http.routers.jitsi-wild.entrypoints=websecure"
      - "traefik.http.routers.jitsi-wild.tls.certresolver=letsencrypt"
      - "traefik.http.routers.jitsi-wild.tls.domains[0].main=yourdomain.com"
      - "traefik.http.routers.jitsi-wild.tls.domains[0].sans=*.yourdomain.com"
      - "traefik.http.routers.jitsi-wild.middlewares=jitsi-room-redirect,jitsi-host-rewrite"

      # Security headers middleware
      - "traefik.http.middlewares.jitsi-headers.headers.customResponseHeaders.X-Frame-Options=SAMEORIGIN"
      - "traefik.http.middlewares.jitsi-headers.headers.customResponseHeaders.X-Content-Type-Options=nosniff"
      - "traefik.http.middlewares.jitsi-headers.headers.customResponseHeaders.Referrer-Policy=no-referrer"

      # Room redirect middleware (root path only — Traefik regex redirect)
      - "traefik.http.middlewares.jitsi-room-redirect.redirectregex.regex=^https://([^.]+)\\.yourdomain\\.com/?$$"
      - "traefik.http.middlewares.jitsi-room-redirect.redirectregex.replacement=https://$${1}.yourdomain.com/$${1}"
      - "traefik.http.middlewares.jitsi-room-redirect.redirectregex.permanent=false"

      # Host rewrite middleware (set Host to base domain for non-root requests)
      - "traefik.http.middlewares.jitsi-host-rewrite.headers.customRequestHeaders.Host=yourdomain.com"
```

**Note:** Traefik's `redirectregex` matches the full URL, so the root-path redirect regex must match `^https://room.domain/?$` and only redirect that pattern. All other paths fall through to the proxy with the Host header rewritten to the base domain.

---

## GitHub Pages / Project Docs Redirects

Once GitHub Pages is configured for this project, add convenience redirects in your frontend proxy so users can find documentation without knowing the GitHub Pages URL.

**nginx example (add inside the main server block):**

```nginx
location /help {
    return 301 https://scriptmgr.github.io/jitsi/;
}
location /contact {
    return 301 https://scriptmgr.github.io/jitsi/contact;
}
```

**Apache equivalent:**

```apache
Redirect 301 /help    https://scriptmgr.github.io/jitsi/
Redirect 301 /contact https://scriptmgr.github.io/jitsi/contact
```

**Caddy equivalent:**

```caddyfile
redir /help    https://scriptmgr.github.io/jitsi/ 301
redir /contact https://scriptmgr.github.io/jitsi/contact 301
```

Update the target URL once GitHub Pages is configured and the published URL is confirmed.

---

## Firewall

**Required — open UDP 10000 for JVB media (audio/video RTP/RTCP):**

```bash
# iptables
iptables -A INPUT -p udp --dport 10000 -j ACCEPT

# firewalld
firewall-cmd --permanent --add-port=10000/udp && firewall-cmd --reload

# ufw
ufw allow 10000/udp
```

**TCP 443 and 80** must also be open for HTTPS and the HTTP→HTTPS redirect.

**TURN server:** if participants are behind restrictive corporate firewalls or symmetric NAT, they may fail to establish a peer-to-peer RTP path. A TURN server (e.g. coturn) relays media over TCP 443 or UDP 3478/5349, bypassing most firewall restrictions. See [Jitsi's TURN documentation](https://jitsi.github.io/handbook/docs/devops-guide/coturn) for setup instructions.
