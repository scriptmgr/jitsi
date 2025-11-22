#!/bin/sh
# shellcheck shell=sh
# POSIX-compliant installer/updater for a full Jitsi Meet (docker-jitsi-meet) stack
# - Uses official Docker Engine repos (NOT distro 'docker.io' package)
# - Self-contained: generates all config files (no git clone needed)
# - HTTP port set to 64453 (reverse proxy terminates TLS)
# - Auth optional (default: anyone can create rooms)
# - Creates/updates admin user 'administrator' with random password if missing
# - Email server assumed to be on the host; containers use host.docker.internal as SMTP
# - Safe to re-run to update images and config (reads existing .env)
#
# Requirements: POSIX sh, root privileges (or sudo), curl, gpg (for repo keys)
# Tested families: Debian/Ubuntu, RHEL/CentOS/Alma/Rocky, Fedora, openSUSE, Arch
#
# Usage:
#   curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E sh
#
# Environment overrides (optional):
#   JITSI_BASE_DIR=/opt/jitsi
#   PUBLIC_URL=https://meet.example.com
#   ENABLE_AUTH=0|1   (default 0: anyone can create rooms)
#   ADMIN_USER=administrator
#   ADMIN_PASS=...    (if unset, generated)
#   HTTP_PORT=64453   (change if needed; reverse proxy should point here)
# shellcheck disable=SC1090

set -eu

VERSION="1.0.0"

# -------- Help/Version --------
show_help() {
  cat <<EOF
Jitsi Meet Installer - Deploy Jitsi Meet via Docker

Usage: $0 [OPTIONS]

Options:
  -h, --help      Show this help message
  -v, --version   Show version
  -r, --remove    Stop containers, remove images, and delete install directory

Environment variables:
  JITSI_BASE_DIR   Installation directory (default: /opt/jitsi)
  PUBLIC_URL       Public URL for Jitsi Meet
  ENABLE_AUTH      0 = anyone can create rooms, 1 = auth required
  ADMIN_USER       Admin username (default: administrator)
  ADMIN_PASS       Admin password (generated if not set)
  HTTP_PORT        HTTP port (default: 64453)
  JITSI_TAG        Docker image tag (default: unstable)

Examples:
  sudo sh $0
  PUBLIC_URL=https://meet.example.com sudo -E sh $0
  sudo sh $0 --remove
EOF
  exit 0
}

show_version() {
  echo "Jitsi Meet Installer v${VERSION}"
  exit 0
}

do_remove() {
  require_root "$@"

  if [ ! -d "$JITSI_BASE_DIR" ]; then
    die "Installation directory not found: $JITSI_BASE_DIR"
  fi

  info "Stopping and removing Jitsi containers..."
  if [ -f "$COMPOSE_FILE" ]; then
    docker_compose down --rmi all --volumes 2>/dev/null || true
  fi

  info "Removing installation directory: $JITSI_BASE_DIR"
  rm -rf "$JITSI_BASE_DIR"

  info "Jitsi Meet has been removed."
  exit 0
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      show_help
      ;;
    -v|--version)
      show_version
      ;;
    -r|--remove)
      REMOVE_MODE=1
      shift
      ;;
    *)
      die "Unknown option: $1. Use --help for usage."
      ;;
  esac
done

# -------- Config (defaults) --------
JITSI_BASE_DIR="${JITSI_BASE_DIR:-/opt/jitsi}"
JITSI_DATA_DIR="$JITSI_BASE_DIR/.data"
COMPOSE_FILE="$JITSI_BASE_DIR/docker-compose.yml"
ENV_FILE="$JITSI_BASE_DIR/.env"
CREDS_FILE="$JITSI_BASE_DIR/credentials.txt"
BACKUP_DIR="$JITSI_BASE_DIR/.backup"

# Load existing .env if present (allows re-run to preserve settings)
if [ -f "$ENV_FILE" ]; then
	. "$ENV_FILE"
fi

HTTP_PORT="${HTTP_PORT:-64453}" # internal HTTP for reverse proxy
PUBLIC_URL="${PUBLIC_URL:-http://$(hostname -f 2>/dev/null || hostname)}"
ENABLE_AUTH="${ENABLE_AUTH:-0}" # 0 = guest access (anyone can create rooms), 1 = auth required
AUTH_TYPE="${AUTH_TYPE:-internal}"
ADMIN_USER="${ADMIN_USER:-administrator}"
ADMIN_PASS="${ADMIN_PASS:-}"
SMTP_SERVER_DEFAULT="host.docker.internal"
SMTP_PORT_DEFAULT="25"

# Docker image tags (can be overridden)
JITSI_TAG="${JITSI_TAG:-unstable}"
# -----------------------------------

umask 022

need_cmd() { command -v "$1" >/dev/null 2>&1; }
die() {
	printf '%s\n' "ERROR: $*" >&2
	exit 1
}
info() { printf '%s\n' "INFO: $*"; }
warn() { printf '%s\n' "WARN: $*" >&2; }

require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		if need_cmd sudo; then
			exec sudo -E -- "$0" "$@"
		else
			die "Must be run as root or with sudo."
		fi
	fi
}

timestamp() { date +%Y%m%d-%H%M%S; }

randpass() {
	# portable random password: 24 chars [A-Za-z0-9]
	# prefer openssl if present; else use dd/od
	if need_cmd openssl; then
		openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 24
	else
		dd if=/dev/urandom bs=1 count=48 2>/dev/null | od -An -tx1 | tr -dc 'A-Za-z0-9' | head -c 24
	fi
}

detect_pkg_mgr() {
	if need_cmd apt-get; then
		echo apt
		return
	elif need_cmd dnf; then
		echo dnf
		return
	elif need_cmd yum; then
		echo yum
		return
	elif need_cmd zypper; then
		echo zypper
		return
	elif need_cmd pacman; then
		echo pacman
		return
	fi
	die "No supported package manager found (apt/dnf/yum/zypper/pacman)."
}

setup_docker_official() {
	PM="$(detect_pkg_mgr)"
	info "Installing Docker Engine from official repositories using: $PM"

	case "$PM" in
	apt)
		# Avoid distro 'docker.io' pkg; use official Docker APT repo
		need_cmd gpg || apt-get update && apt-get install -y gpg
		apt-get update
		apt-get install -y ca-certificates gnupg curl
		install -m 0755 -d /etc/apt/keyrings
		if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
			curl -fsSL https://download.docker.com/linux/$(
				. /etc/os-release
				echo "$ID"
			)/gpg |
				gpg --dearmor -o /etc/apt/keyrings/docker.gpg
			chmod a+r /etc/apt/keyrings/docker.gpg
		fi
		. /etc/os-release
		echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
			>/etc/apt/sources.list.d/docker.list
		apt-get update
		apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		systemctl enable --now docker
		;;

	dnf)
		dnf -y install dnf-plugins-core curl
		. /etc/os-release
		case "$ID" in
		fedora)
			dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
			;;
		*)
			# RHEL, CentOS, AlmaLinux, Rocky, etc.
			dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
			;;
		esac
		dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		systemctl enable --now docker
		;;

	yum)
		yum -y install yum-utils curl
		yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
		yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		systemctl enable --now docker
		;;

	zypper)
		zypper refresh
		zypper -n install ca-certificates curl
		. /etc/os-release
		zypper -n addrepo https://download.docker.com/linux/$ID/docker-ce.repo docker-ce || true
		zypper refresh
		zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
			zypper -n install docker docker-compose
		systemctl enable --now docker
		;;

	pacman)
		pacman -Sy --noconfirm --needed docker docker-compose
		systemctl enable --now docker
		;;

	*)
		die "Unsupported package manager: $PM"
		;;
	esac
}

ensure_docker() {
	if ! need_cmd docker; then
		setup_docker_official
	else
		info "Docker already installed."
		# ensure service running
		if need_cmd systemctl; then systemctl start docker 2>/dev/null || true; fi
	fi

	# Compose plugin is "docker compose"
	if docker compose version >/dev/null 2>&1; then
		info "Docker Compose plugin is available."
	elif need_cmd docker-compose; then
		info "Legacy docker-compose is available."
	else
		warn "Docker Compose not found; attempting to install via official repos."
		setup_docker_official
	fi
}

backup_file() {
	[ -f "$1" ] || return 0
	mkdir -p "$BACKUP_DIR"
	cp -p "$1" "$BACKUP_DIR/$(basename "$1").$(timestamp)"
}

init_dirs() {
	mkdir -p "$JITSI_BASE_DIR" "$JITSI_DATA_DIR" "$BACKUP_DIR"
	mkdir -p "$JITSI_BASE_DIR/config" # to mount into containers
}

gen_env_if_missing() {
	if [ ! -f "$ENV_FILE" ]; then
		info "Creating default .env"
		cat >"$ENV_FILE" <<EOF
# Auto-generated by install.sh
# Re-run install.sh to safely update. Local edits are preserved.
# Core
CONFIG=./config
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=0
ENABLE_HTTP_REDIRECT=0
ENABLE_LETSENCRYPT=0
PUBLIC_URL=$PUBLIC_URL
TZ=$(printf %s "${TZ:-UTC}")

# Auth (optional)
ENABLE_AUTH=$ENABLE_AUTH
AUTH_TYPE=$AUTH_TYPE
XMPP_DOMAIN=meet.jitsi
XMPP_AUTH_DOMAIN=auth.meet.jitsi
XMPP_GUEST_DOMAIN=guest.meet.jitsi
ENABLE_GUESTS=$([ "$ENABLE_AUTH" = "1" ] && echo 0 || echo 1)

# Component creds (autofilled if empty on first run)
JICOFO_AUTH_USER=focus
JICOFO_AUTH_PASSWORD=
JVB_AUTH_USER=jvb
JVB_AUTH_PASSWORD=

# Videobridge / RTP
JVB_UDP_PORT=10000
JVB_TCP_HARVESTER_DISABLED=true

# SMTP via host
SMTP_SERVER=${SMTP_SERVER:-$SMTP_SERVER_DEFAULT}
SMTP_PORT=${SMTP_PORT:-$SMTP_PORT_DEFAULT}
SMTP_FROM=${SMTP_FROM:-"no-reply@$(hostname -f 2>/dev/null || hostname)"}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
SMTP_TLS=${SMTP_TLS:-0}
SMTP_STARTTLS=${SMTP_STARTTLS:-0}

# Image tag
JITSI_IMAGE_TAG=$JITSI_TAG
EOF
	else
		info "Found existing .env (preserving)."
	fi
}

# Merge helper: set KEY=value if KEY absent in .env
ensure_env_key() {
	key="$1"
	val="$2"
	if ! grep -E "^$key=" "$ENV_FILE" >/dev/null 2>&1; then
		printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
	fi
}

fill_missing_secrets() {
	# Ensure component secrets exist
	. "$ENV_FILE"

	changed=0

	if [ -z "${JICOFO_AUTH_PASSWORD:-}" ]; then
		pw="$(randpass)"
		sed -i "s/^JICOFO_AUTH_PASSWORD=.*/JICOFO_AUTH_PASSWORD=$pw/" "$ENV_FILE"
		changed=1
	fi
	if [ -z "${JVB_AUTH_PASSWORD:-}" ]; then
		pw="$(randpass)"
		sed -i "s/^JVB_AUTH_PASSWORD=.*/JVB_AUTH_PASSWORD=$pw/" "$ENV_FILE"
		changed=1
	fi

	# Ensure ADMIN credentials (we store separately; not in .env)
	if [ -z "${ADMIN_PASS:-}" ]; then
		if [ -f "$CREDS_FILE" ] && grep -q "^ADMIN_USER=$ADMIN_USER$" "$CREDS_FILE"; then
			ADMIN_PASS="$(grep '^ADMIN_PASS=' "$CREDS_FILE" | head -1 | cut -d= -f2-)"
		else
			ADMIN_PASS="$(randpass)"
		fi
	fi

	if [ "$changed" -eq 1 ]; then
		info "Filled missing component credentials."
	fi
}

write_compose() {
	backup_file "$COMPOSE_FILE"
	info "Writing docker-compose.yml"
	cat >"$COMPOSE_FILE" <<'YAML'
services:
  # XMPP server (Prosody)
  prosody:
    container_name: jitsi-prosody
    image: jitsi/prosody:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    ports:
      - "5222:5222"
      - "5347:5347"
      - "5280:5280"
    volumes:
      - ${CONFIG}/prosody:/config:Z
    environment:
      - XMPP_DOMAIN=${XMPP_DOMAIN}
      - XMPP_AUTH_DOMAIN=${XMPP_AUTH_DOMAIN}
      - XMPP_GUEST_DOMAIN=${XMPP_GUEST_DOMAIN}
      - ENABLE_AUTH=${ENABLE_AUTH}
      - AUTH_TYPE=${AUTH_TYPE}
      - ENABLE_GUESTS=${ENABLE_GUESTS}
      - PUBLIC_URL=${PUBLIC_URL}
      - JICOFO_AUTH_USER=${JICOFO_AUTH_USER}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
    networks:
      meet:
        aliases:
          - xmpp.meet.jitsi

  # Focus (Jicofo)
  jicofo:
    container_name: jitsi-jicofo
    image: jitsi/jicofo:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    depends_on: [ prosody ]
    volumes:
      - ${CONFIG}/jicofo:/config:Z
    environment:
      - XMPP_DOMAIN=${XMPP_DOMAIN}
      - XMPP_AUTH_DOMAIN=${XMPP_AUTH_DOMAIN}
      - JICOFO_AUTH_USER=${JICOFO_AUTH_USER}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - ENABLE_AUTH=${ENABLE_AUTH}
      - XMPP_SERVER=xmpp.meet.jitsi
    networks: [ meet ]

  # Videobridge
  jvb:
    container_name: jitsi-jvb
    image: jitsi/jvb:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    depends_on: [ prosody ]
    ports:
      - "10000:10000/udp"
    volumes:
      - ${CONFIG}/jvb:/config:Z
    environment:
      - XMPP_AUTH_DOMAIN=${XMPP_AUTH_DOMAIN}
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - JVB_UDP_PORT=${JVB_UDP_PORT}
      - JVB_TCP_HARVESTER_DISABLED=${JVB_TCP_HARVESTER_DISABLED}
      - XMPP_SERVER=xmpp.meet.jitsi
    networks: [ meet ]

  # Web (no TLS here; reverse proxy handles it)
  web:
    container_name: jitsi-web
    image: jitsi/web:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    depends_on: [ prosody, jicofo ]
    ports:
      - "${HTTP_PORT:-64453}:80"
    volumes:
      - ${CONFIG}/web:/config:Z
    environment:
      - ENABLE_LETSENCRYPT=0
      - ENABLE_HTTP_REDIRECT=0
      - PUBLIC_URL=${PUBLIC_URL}
      - XMPP_DOMAIN=${XMPP_DOMAIN}
      - XMPP_AUTH_DOMAIN=${XMPP_AUTH_DOMAIN}
      - XMPP_GUEST_DOMAIN=${XMPP_GUEST_DOMAIN}
      - ENABLE_AUTH=${ENABLE_AUTH}
      - ENABLE_GUESTS=${ENABLE_GUESTS}
      - SMTP_SERVER=${SMTP_SERVER}
      - SMTP_PORT=${SMTP_PORT}
      - SMTP_FROM=${SMTP_FROM}
      - SMTP_USERNAME=${SMTP_USERNAME}
      - SMTP_PASSWORD=${SMTP_PASSWORD}
      - SMTP_TLS=${SMTP_TLS}
      - SMTP_STARTTLS=${SMTP_STARTTLS}
      - XMPP_SERVER=xmpp.meet.jitsi
    networks: [ meet ]

networks:
  meet:
    driver: bridge
YAML
}

docker_compose() {
	if docker compose version >/dev/null 2>&1; then
		docker compose -f "$COMPOSE_FILE" "$@"
	elif need_cmd docker-compose; then
		docker-compose -f "$COMPOSE_FILE" "$@"
	else
		die "Docker Compose not available."
	fi
}

start_stack() {
	info "Pulling images..."
	docker_compose pull
	info "Starting/updating stack..."
	docker_compose up -d
}

wait_for_prosody() {
	info "Waiting for Prosody to become ready..."
	i=0
	while :; do
		if docker logs jitsi-prosody 2>&1 | grep -q "Prosody is ready"; then
			break
		fi
		i=$((i + 1))
		if [ "$i" -gt 60 ]; then
			warn "Prosody readiness not confirmed in time; continuing."
			break
		fi
		sleep 2
	done
}

register_admin_user() {
	. "$ENV_FILE"
	# We register in the auth domain if auth is enabled; otherwise register in XMPP_DOMAIN
	domain="$XMPP_DOMAIN"
	if [ "${ENABLE_AUTH:-0}" = "1" ]; then
		domain="$XMPP_AUTH_DOMAIN"
	fi

	info "Ensuring admin user '${ADMIN_USER}@${domain}' exists..."
	# Try to detect existing user by attempting to set password; if it fails, register.
	if docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua passwd "$ADMIN_USER" "$domain" "$ADMIN_PASS" >/dev/null 2>&1; then
		info "Updated password for ${ADMIN_USER}@${domain}"
	else
		docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua register "$ADMIN_USER" "$domain" "$ADMIN_PASS" >/dev/null 2>&1 ||
			warn "Could not register admin user; verify Prosody is healthy."
	fi

	umask 077
	{
		echo "ADMIN_USER=$ADMIN_USER"
		echo "ADMIN_DOMAIN=$domain"
		echo "ADMIN_PASS=$ADMIN_PASS"
		echo "UPDATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	} >"$CREDS_FILE"
	info "Admin credentials saved at: $CREDS_FILE"
}

post_summary() {
	. "$ENV_FILE"
	cat <<OUT

------------------------------------------------------------
Jitsi Meet is up.
Reverse proxy target (HTTP): 127.0.0.1:${HTTP_PORT}
Public URL (for clients):   ${PUBLIC_URL}
Auth enabled:               ${ENABLE_AUTH} (0=anyone can create rooms)
Admin user:                 ${ADMIN_USER}@$([ "$ENABLE_AUTH" = "1" ] && printf %s "$XMPP_AUTH_DOMAIN" || printf %s "$XMPP_DOMAIN")
Admin password:             (stored in $CREDS_FILE)
SMTP relay:                 ${SMTP_SERVER}:${SMTP_PORT} (from ${SMTP_FROM})
Images tag:                 ${JITSI_TAG}
Data dir:                   ${JITSI_DATA_DIR}
Compose file:               ${COMPOSE_FILE}
Env file:                   ${ENV_FILE}
------------------------------------------------------------

If using a reverse proxy (recommended), forward your TLS vhost to:
  http://127.0.0.1:${HTTP_PORT}

For updates later, just re-run:
curl -fsSL https://github.com/scriptmgr/jitsi/raw/refs/heads/main/install.sh | sudo -E sh
------------------------------------------------------------
OUT
}

main() {
	# Handle remove mode
	if [ "${REMOVE_MODE:-0}" = "1" ]; then
		do_remove "$@"
	fi

	require_root "$@"
	ensure_docker
	init_dirs
	gen_env_if_missing

	# Ensure SMTP defaults and tag keys exist in case .env was user-supplied
	ensure_env_key SMTP_SERVER "$SMTP_SERVER_DEFAULT"
	ensure_env_key SMTP_PORT "$SMTP_PORT_DEFAULT"
	ensure_env_key JITSI_IMAGE_TAG "$JITSI_TAG"

	fill_missing_secrets
	write_compose
	start_stack
	wait_for_prosody
	register_admin_user
	post_summary
}

main "$@"
