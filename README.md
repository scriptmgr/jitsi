# Jitsi Meet Installer (Docker, Bash)

This repository provides a **Bash** installation and update script (`install.sh`) for running a full [Jitsi Meet](https://jitsi.org/jitsi-meet/) stack in **Docker containers**, using the **official Docker Engine repositories** (not `docker.io` from the distro).

- ✅ Bash script (`#!/usr/bin/env bash`)
- ✅ Platform agnostic (Debian/Ubuntu, RHEL/CentOS/Alma/Rocky, Fedora with DNF 4 or 5, openSUSE, Arch)
- ✅ Installs **Docker CE** from official repos (no `docker.io` package)
- ✅ Self-contained: generates all config files (no git clone needed)
- ✅ Idempotent: re-run safely to update without breaking existing setup
- ✅ Reverse proxy–friendly (HTTP bound to a random host port from **64000–64999** by default)
- ✅ Auth **optional by default** (anyone can create rooms)
- ✅ **User self-registration** via web form or XMPP client
- ✅ Creates or updates the **admin account** when authentication is enabled
- ✅ **Customizable branding** (app name, watermark, etc.)
- ✅ **Optional Jibri** for recording and live streaming
- ✅ Email delivery via host mail server



## Quick Start

Run the installer directly:

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E bash
```

Or with environment overrides:

```sh
export PUBLIC_URL=https://meet.example.com
export ENABLE_AUTH=1
export APP_NAME="My Company Meetings"
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E bash
```

That's it. The script will:

1. Install or update Docker CE from the official repositories.
2. Create `/opt/jitsi` directory structure.
3. Generate a `.env` file with sane defaults (or read existing one).
4. Write a `docker-compose.yml` for the Jitsi Meet stack.
5. Pull images and start containers.
6. Install the `meet-admin` and `jitsi-stack` operational commands. An admin account is created or updated only when `ENABLE_AUTH=1`.


## Defaults

- **Admin user:** `administrator` when `ENABLE_AUTH=1` (authentication is disabled by default)
- **Admin password:** Randomly generated if not provided when `ENABLE_AUTH=1`. Saved at:

  ```text
  /opt/jitsi/credentials.txt
  ```

- **HTTP port:** Randomly selected from `64000–64999` unless `HTTP_PORT` is set; the reverse proxy forwards to this host port.

- **Public URL:** `http://$(hostname -f)` unless overridden
- **Email:** Containers send via `host.docker.internal:25` (relay to host MTA)
- **User registration:** Enabled by default at `/register`


## Environment Variables

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `JITSI_BASE_DIR` | `/opt/jitsi` | Installation root directory |
| `PUBLIC_URL` | `http://$(hostname)` | Public URL for Jitsi Meet |
| `HTTP_PORT` | Random port from `64000–64999` | Host port mapped to the web container's HTTP port |
| `INTERNAL_PROXY_IP` | Detected Docker host IPv4 address | Host address on which the web port is published; set explicitly if detection fails |
| `WRITE_NGINX_VHOST` | `1` | Write an Nginx vhost when Nginx is installed; use `0` to skip |
| `NGINX_VHOST_DIR` | `/etc/nginx/vhosts.d` | Directory for the generated Nginx vhost |
| `NGINX_SSL_CERT_DIR` | Detected certificate directory | Directory containing `fullchain.pem` and `privkey.pem` for the generated vhost |
| `ENABLE_AUTH` | `0` | `0` = open, `1` = secure domain |
| `ADMIN_USER` | `administrator` | Admin username |
| `ADMIN_PASS` | (generated when `ENABLE_AUTH=1`) | Admin password |
| `JITSI_TAG` | `unstable` | Docker image tag |
| `TZ` | `America/New_York` | Timezone |

### Branding

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_NAME` | `CasjaysDev Meet` | Application name shown in UI |
| `PROVIDER_NAME` | `CasjaysDev` | Provider/company name |
| `DEFAULT_LANGUAGE` | `en` | UI language |

### Features

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_REGISTRATION` | `true` | User self-registration |
| `ENABLE_WELCOME_PAGE` | `true` | Show landing page |
| `ENABLE_PREJOIN_PAGE` | `true` | Preview audio/video before joining |
| `ENABLE_LOBBY` | `true` | Waiting room feature |
| `ENABLE_BREAKOUT_ROOMS` | `true` | Sub-meeting rooms |

### Recording (Jibri)

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_JIBRI` | `0` | Enable Jibri container |
| `ENABLE_RECORDING` | `false`* | Show recording button |
| `ENABLE_LIVESTREAMING` | `false`* | Show streaming button |

*Auto-enabled when `ENABLE_JIBRI=1`

### Video Quality

| Variable | Default | Description |
|----------|---------|-------------|
| `RESOLUTION` | `720` | Default video height |
| `RESOLUTION_WIDTH` | `1280` | Default video width |

### Watermark

| Variable | Default | Description |
|----------|---------|-------------|
| `SHOW_JITSI_WATERMARK` | `false` | Show Jitsi logo |
| `SHOW_BRAND_WATERMARK` | `false` | Show custom logo |
| `BRAND_WATERMARK_LINK` | (empty) | URL for custom logo click |


## User Registration

Users can register accounts in two ways:

### Web Registration
Visit `/register` on your Jitsi instance to create an account through a web form.

### XMPP Client Registration
Connect to port `5222` with any XMPP client that supports in-band registration:
- Conversations (Android)
- Gajim (Desktop)
- Dino (Desktop)
- Monal (iOS)

To disable registration:
```sh
ENABLE_REGISTRATION=false sudo -E bash install.sh
```


## Recording with Jibri

To enable recording and live streaming:

```sh
ENABLE_JIBRI=1 PUBLIC_URL=https://meet.example.com sudo -E bash install.sh
```

**Requirements:**
- Sufficient CPU/RAM (Jibri runs headless Chrome)
- ALSA loopback kernel module (`snd-aloop`) - script will attempt to load it

Recordings are saved to `/opt/jitsi/rootfs/data/recordings/`.


## Reverse Proxy

TLS is not handled inside the container stack. Instead, run a reverse proxy (e.g., Nginx, Caddy, Traefik) that terminates TLS and forwards traffic to the host address and port configured by `INTERNAL_PROXY_IP` and `HTTP_PORT` (the port is randomly selected from `64000–64999` by default):

```text
http://<INTERNAL_PROXY_IP>:<HTTP_PORT>
```

Three requirements for the proxy to work correctly:

1. **WebSocket support** — Jitsi uses WebSocket for signalling. The proxy must forward `Upgrade: websocket` requests.
2. **`X-Forwarded-Proto: https`** — Jitsi derives all BOSH/WebSocket URLs from `PUBLIC_URL`. If the proxy serves HTTPS but this header is missing or wrong, Jitsi generates `http://` resource URLs and browsers block them as mixed content.
3. **Raised timeouts** — Jitsi WebSocket connections are long-lived (hours). Default Nginx timeouts of 60 s will silently drop active calls. Set `proxy_read_timeout` and `proxy_send_timeout` to at least 3600 s.

In the examples below, replace `<INTERNAL_PROXY_IP>` and `<HTTP_PORT>` with the values from the installer's `.env` file.

### Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name meet.example.com;

    ssl_certificate /etc/letsencrypt/live/meet.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meet.example.com/privkey.pem;

    location / {
        proxy_pass http://<INTERNAL_PROXY_IP>:<HTTP_PORT>;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

### Caddy

Caddy sets `X-Forwarded-Proto` and handles WebSocket upgrades automatically.

```caddyfile
meet.example.com {
    reverse_proxy <INTERNAL_PROXY_IP>:<HTTP_PORT>
}
```

### Firewall: JVB media port

The reverse proxy only handles HTTP/WebSocket (signalling). **Media traffic (audio/video) flows directly from each participant's browser to the Jitsi Video Bridge over UDP port 10000** — it never goes through the proxy.

You must open this port on your firewall:

```sh
# firewalld (RHEL/AlmaLinux/Fedora)
firewall-cmd --permanent --add-port=10000/udp
firewall-cmd --reload

# ufw (Debian/Ubuntu)
ufw allow 10000/udp
```

If UDP port 10000 is blocked, the call will appear to connect (signalling works over HTTPS) but participants will have no audio or video.


## Updating

Re-run the script anytime:

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E bash
```

This will:

- Read existing `.env` to preserve your settings
- Add any new configuration options
- Pull updated Docker images
- Recreate the stack with no data loss
- Preserve and/or regenerate secrets as needed
- Update the admin account password if changed

When the installer replaces an existing generated configuration file, it saves a timestamped copy under `$JITSI_BASE_DIR/backup/`. The `jitsi-stack backup` command creates a timestamped `.tar.gz` archive of the installation directory, including `.env` and other secrets; the archive is created with owner-only permissions. Store or transfer these archives accordingly.


## Uninstalling

`--remove` stops and removes the Compose stack, its Docker images and named volumes, removes this installer's Nginx vhost when it can identify it, and deletes the entire `$JITSI_BASE_DIR` directory, including configuration, recordings, and backups. Back up anything you need before using it. The command refuses a symlink installation directory, a missing Compose file, or unsafe top-level paths.

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo bash -s -- --remove
```

Or if you have the script locally:

```sh
sudo bash install.sh --remove
```


## Files & Layout

All paths are relative to `JITSI_BASE_DIR` (default `/opt/jitsi`):

- `$JITSI_BASE_DIR/.env` – main configuration (mode `600`)
- `$JITSI_BASE_DIR/docker-compose.yml` – container stack definition
- `$JITSI_BASE_DIR/rootfs/config/` – persistent config mounted into containers
- `$JITSI_BASE_DIR/rootfs/data/` – persistent service data, including Jibri recordings when enabled
- `$JITSI_BASE_DIR/credentials.txt` – saved admin credentials when `ENABLE_AUTH=1` (mode `600`)
- `$JITSI_BASE_DIR/backup/` – timestamped copies of replaced configuration files and archives created by `jitsi-stack backup`

The installer requires `JITSI_BASE_DIR` to be an absolute path, at least five characters long, not one of several protected system/root paths, and not itself a symlink. It also refuses a symlink `.env` file. `HTTP_PORT` must be `1–65535`; `ENABLE_AUTH`, `ENABLE_JIBRI`, and `WRITE_NGINX_VHOST` must be `0` or `1`. `INTERNAL_PROXY_IP`, when set, must be IPv4. `PUBLIC_URL` must be an HTTP(S) URL with a valid host, and `PUBLIC_DOMAIN` must match that host.

When `WRITE_NGINX_VHOST=1` and Nginx is installed, the installer writes `$NGINX_VHOST_DIR/$PUBLIC_DOMAIN.conf` (default `/etc/nginx/vhosts.d/$PUBLIC_DOMAIN.conf`) and tests the Nginx configuration. If the configuration is valid, it reloads active Nginx, or enables and starts Nginx if the service is inactive. If the test fails, it warns and leaves the service unchanged. If Nginx is absent or the option is `0`, it skips vhost generation. Set `NGINX_SSL_CERT_DIR` to the directory containing the certificate and key if automatic detection is not correct. The generated config terminates TLS; provision valid certificate files before enabling the vhost.


## Custom Docker Images

This installer uses custom Docker images with enhanced features:

- **`casjaysdevdocker/prosody`** - Prosody with user registration enabled
- **`casjaysdevdocker/jitsi-web`** - Web UI with registration page

These are based on the official `jitsi/*` images with additional modules.


## Requirements

- Root privileges (or sudo)
- One of: `apt`, `dnf`, `yum`, `zypper`, `pacman`
- `curl`, `gpg`, and `openssl` (recommended for password generation)
- `jq` is installed automatically through the detected package manager when missing; it is required by the operational commands.


## License

MIT. See [LICENSE](LICENSE).


## Notes

- Designed for **reverse proxy** use only. Jitsi's internal web container runs plain HTTP.
- `ENABLE_AUTH=0` allows open room creation (default). Switch to `ENABLE_AUTH=1` in `.env` for secure domain.
- Uses custom Docker images based on official Jitsi images with registration support.
