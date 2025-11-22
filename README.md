# Jitsi Meet Installer (Docker, POSIX)

This repository provides a **POSIX-compliant** installation and update script (`install.sh`) for running a full [Jitsi Meet](https://jitsi.org/jitsi-meet/) stack in **Docker containers**, using the **official Docker Engine repositories** (not `docker.io` from the distro).

- ✅ POSIX shell (`sh`) — no Bashisms
- ✅ Platform agnostic (Debian/Ubuntu, RHEL/CentOS/Alma/Rocky, Fedora, openSUSE, Arch)
- ✅ Installs **Docker CE** from official repos (no `docker.io` package)
- ✅ Self-contained: generates all config files (no git clone needed)
- ✅ Idempotent: re-run safely to update without breaking existing setup
- ✅ Reverse proxy–friendly (HTTP bound to port **64453**)
- ✅ Auth **optional by default** (anyone can create rooms)
- ✅ Creates or updates **admin account** automatically
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

* **Admin user:** `administrator`
* **Admin password:** Randomly generated if not provided. Saved at:

  ```
  /opt/jitsi/credentials.txt
  ```
* **HTTP port:** `64453` (reverse proxy should terminate TLS and forward here)
* **Public URL:** `http://$(hostname -f)` unless overridden
* **Email:** Containers send via `host.docker.internal:25` (relay to host MTA)


## Environment Overrides

You can set environment variables before running `install.sh`:

```sh
JITSI_BASE_DIR=/srv/jitsi \
PUBLIC_URL=https://meet.example.com \
ENABLE_AUTH=1 \
ADMIN_USER=myadmin \
ADMIN_PASS=secretpass \
HTTP_PORT=8080 \
sudo -E sh ./install.sh
```

Key variables:

* `JITSI_BASE_DIR` – installation root (default: `/opt/jitsi`)
* `PUBLIC_URL` – base URL for Jitsi Meet
* `HTTP_PORT` – internal HTTP port (default: `64453`)
* `ENABLE_AUTH` – `0` (default, anyone can create rooms) or `1` (secure domain)
* `ADMIN_USER` / `ADMIN_PASS` – credentials for Prosody admin


## Reverse Proxy

TLS is not handled inside the container stack. Instead, run a reverse proxy (e.g., Nginx, Caddy, Traefik) that terminates TLS and forwards traffic to:

```
http://127.0.0.1:64453
```

Example Nginx snippet:

```nginx
server {
    listen 443 ssl;
    server_name meet.example.com;

    ssl_certificate /etc/letsencrypt/live/meet.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/meet.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:64453;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```



## Updating

Re-run the script anytime:

```sh
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E sh
```

This will:

* Read existing `.env` to preserve your settings
* Pull updated Docker images
* Recreate the stack with no data loss
* Preserve and/or regenerate secrets as needed
* Update the admin account password if changed


## Files & Layout

* `/opt/jitsi/.env` – main configuration
* `/opt/jitsi/docker-compose.yml` – container stack definition
* `/opt/jitsi/config/` – persistent config mounted into containers
* `/opt/jitsi/credentials.txt` – saved admin credentials
* `/opt/jitsi/.backup/` – timestamped backups of replaced files


## Requirements

* Root privileges (or sudo)
* One of: `apt`, `dnf`, `yum`, `zypper`, `pacman`
* `curl`, `gpg`, and `openssl` (recommended for password generation)


## License

MIT. See [LICENSE](LICENSE).


## Notes

* Designed for **reverse proxy** use only. Jitsi’s internal web container runs plain HTTP.
* `ENABLE_AUTH=0` allows open room creation (default). Switch to `ENABLE_AUTH=1` in `.env` for secure domain.
* Uses the **official Docker Hub images** (`jitsi/web`, `jitsi/prosody`, `jitsi/jicofo`, `jitsi/jvb`).
