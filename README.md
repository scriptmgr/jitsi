# Jitsi Meet Installer (Docker, POSIX)

This repository provides a **POSIX-compliant** installation and update script (`install.sh`) for running a full [Jitsi Meet](https://jitsi.org/jitsi-meet/) stack in **Docker containers**, using the **official Docker Engine repositories** (not `docker.io` from the distro).

- ✅ POSIX shell (`sh`) — no Bashisms
- ✅ Platform agnostic (Debian/Ubuntu, RHEL/CentOS/Alma/Rocky, Fedora, openSUSE, Arch)
- ✅ Installs **Docker CE** from official repos (no `docker.io` package)
- ✅ Self-contained: generates all config files (no git clone needed)
- ✅ Idempotent: re-run safely to update without breaking existing setup
- ✅ Reverse proxy–friendly (HTTP bound to port **64453**)
- ✅ Auth **optional by default** (anyone can create rooms)
- ✅ **User self-registration** via web form or XMPP client
- ✅ Creates or updates **admin account** automatically
- ✅ **Customizable branding** (app name, watermark, etc.)
- ✅ **Optional Jibri** for recording and live streaming
- ✅ Email delivery via host mail server



## Quick Start

Run the installer directly:

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E sh
```

Or with environment overrides:

```sh
export PUBLIC_URL=https://meet.example.com
export ENABLE_AUTH=1
export APP_NAME="My Company Meetings"
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E sh
```

That's it. The script will:

1. Install or update Docker CE from the official repositories.
2. Create `/opt/jitsi` directory structure.
3. Generate a `.env` file with sane defaults (or read existing one).
4. Write a `docker-compose.yml` for the Jitsi Meet stack.
5. Pull images and start containers.
6. Create or update the admin account (`administrator`).


## Defaults

- **Admin user:** `administrator`
- **Admin password:** Randomly generated if not provided. Saved at:

  ```text
  /opt/jitsi/credentials.txt
  ```

- **HTTP port:** `64453` (reverse proxy should terminate TLS and forward here)

- **Public URL:** `http://$(hostname -f)` unless overridden
- **Email:** Containers send via `host.docker.internal:25` (relay to host MTA)
- **User registration:** Enabled by default at `/register`


## Environment Variables

### Core Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `JITSI_BASE_DIR` | `/opt/jitsi` | Installation root directory |
| `PUBLIC_URL` | `http://$(hostname)` | Public URL for Jitsi Meet |
| `HTTP_PORT` | `64453` | Internal HTTP port |
| `ENABLE_AUTH` | `0` | `0` = open, `1` = secure domain |
| `ADMIN_USER` | `administrator` | Admin username |
| `ADMIN_PASS` | (generated) | Admin password |
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
ENABLE_REGISTRATION=false sudo -E sh install.sh
```


## Recording with Jibri

To enable recording and live streaming:

```sh
ENABLE_JIBRI=1 PUBLIC_URL=https://meet.example.com sudo -E sh install.sh
```

**Requirements:**
- Sufficient CPU/RAM (Jibri runs headless Chrome)
- ALSA loopback kernel module (`snd-aloop`) - script will attempt to load it

Recordings are saved to `/opt/jitsi/config/recordings/`.


## Reverse Proxy

TLS is not handled inside the container stack. Instead, run a reverse proxy (e.g., Nginx, Caddy, Traefik) that terminates TLS and forwards traffic to:

```text
http://127.0.0.1:64453
```

**Important:** WebSocket support is required for Jitsi to function properly.

### Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name meet.example.com;

    ssl_certificate /etc/letsencrypt/live/meet.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meet.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:64453;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Caddy

```caddyfile
meet.example.com {
    reverse_proxy 127.0.0.1:64453
}
```


## Updating

Re-run the script anytime:

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E sh
```

This will:

- Read existing `.env` to preserve your settings
- Add any new configuration options
- Pull updated Docker images
- Recreate the stack with no data loss
- Preserve and/or regenerate secrets as needed
- Update the admin account password if changed


## Uninstalling

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo sh -s -- --remove
```

Or if you have the script locally:

```sh
sudo sh install.sh --remove
```


## Files & Layout

- `/opt/jitsi/.env` – main configuration
- `/opt/jitsi/docker-compose.yml` – container stack definition
- `/opt/jitsi/config/` – persistent config mounted into containers
- `/opt/jitsi/config/recordings/` – Jibri recordings (if enabled)
- `/opt/jitsi/credentials.txt` – saved admin credentials
- `/opt/jitsi/.backup/` – timestamped backups of replaced files


## Custom Docker Images

This installer uses custom Docker images with enhanced features:

- **`casjaysdevdocker/prosody`** - Prosody with user registration enabled
- **`casjaysdevdocker/jitsi-web`** - Web UI with registration page

These are based on the official `jitsi/*` images with additional modules.


## Requirements

- Root privileges (or sudo)
- One of: `apt`, `dnf`, `yum`, `zypper`, `pacman`
- `curl`, `gpg`, and `openssl` (recommended for password generation)


## License

MIT. See [LICENSE](LICENSE).


## Notes

- Designed for **reverse proxy** use only. Jitsi's internal web container runs plain HTTP.
- `ENABLE_AUTH=0` allows open room creation (default). Switch to `ENABLE_AUTH=1` in `.env` for secure domain.
- Uses custom Docker images based on official Jitsi images with registration support.
