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

Core Environment Variables:
  JITSI_BASE_DIR      Installation directory (default: /opt/jitsi)
  PUBLIC_URL          Public URL for Jitsi Meet
  ENABLE_AUTH         0 = anyone can create rooms, 1 = auth required
  ADMIN_USER          Admin username (default: administrator)
  ADMIN_PASS          Admin password (generated if not set)
  HTTP_PORT           HTTP port (default: 64453)
  JITSI_TAG           Docker image tag (default: unstable)
  TZ                  Timezone (default: America/New_York or host TZ)

Branding:
  APP_NAME            Application name (default: CasjaysDev Meet)
  PROVIDER_NAME       Provider name (default: CasjaysDev)
  DEFAULT_LANGUAGE    UI language (default: en)

Features:
  ENABLE_REGISTRATION User self-registration (default: true)
  ENABLE_WELCOME_PAGE Show welcome/landing page (default: true)
  ENABLE_PREJOIN_PAGE Preview before joining (default: true)
  ENABLE_LOBBY        Waiting room feature (default: true)
  ENABLE_BREAKOUT_ROOMS Sub-meeting rooms (default: true)

Recording (requires Jibri):
  ENABLE_JIBRI        Enable Jibri for recording/streaming (default: 0)
                      When enabled, auto-enables recording features

Video Quality:
  RESOLUTION          Default video height (default: 720)
  RESOLUTION_WIDTH    Default video width (default: 1280)

Watermark:
  SHOW_JITSI_WATERMARK  Show Jitsi logo (default: false)
  SHOW_BRAND_WATERMARK  Show custom logo (default: false)
  BRAND_WATERMARK_LINK  URL for custom logo click

Examples:
  sudo sh $0
  PUBLIC_URL=https://meet.example.com sudo -E sh $0
  ENABLE_JIBRI=1 PUBLIC_URL=https://meet.example.com sudo -E sh $0
  APP_NAME="My Meetings" ENABLE_AUTH=1 sudo -E sh $0
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
	-h | --help)
		show_help
		;;
	-v | --version)
		show_version
		;;
	-r | --remove)
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
ENV_FILE="$JITSI_BASE_DIR/.env"
COMPOSE_FILE="$JITSI_BASE_DIR/docker-compose.yml"
JITSI_DATA_DIR="$JITSI_BASE_DIR/rootfs/data"
JITSI_CONFIG_DIR="$JITSI_BASE_DIR/rootfs/config"
CREDS_FILE="$JITSI_BASE_DIR/credentials.txt"
BACKUP_DIR="$JITSI_BASE_DIR/backup"
PUBLIC_URL="${PUBLIC_URL:-http://$(hostname -f 2>/dev/null || hostname)}"
# Extract domain from PUBLIC_URL (strip protocol) - used for auth, email, display
PUBLIC_DOMAIN=$(printf '%s' "$PUBLIC_URL" | sed -e 's|^https\?://||' -e 's|/.*||' -e 's|:.*||')
HOST_TZ="America/New_York"

JVB_AUTH_PASSWORD="$(randpass)"
JICOFO_AUTH_PASSWORD="$(randpass)"
# Load existing .env if present (allows re-run to preserve settings)
# Skip if in remove mode to avoid parse errors
# Note: We parse it carefully since docker-compose .env format differs from shell
if [ -f "$ENV_FILE" ] && [ "${REMOVE_MODE:-0}" != "1" ]; then
	while IFS='=' read -r key value; do
		# Skip comments and empty lines
		case "$key" in
		\#* | "") continue ;;
		esac
		# Export the variable (value may contain spaces)
		export "$key=$value" 2>/dev/null || true
	done <"$ENV_FILE"
fi

HTTP_PORT="${HTTP_PORT:-64453}" # internal HTTP for reverse proxy
ENABLE_AUTH="${ENABLE_AUTH:-0}" # 0 = guest access (anyone can create rooms), 1 = auth required
AUTH_TYPE="${AUTH_TYPE:-internal}"
ADMIN_USER="${ADMIN_USER:-administrator}"
# Strip domain from ADMIN_USER if provided (e.g., admin@domain.com -> admin)
ADMIN_USER=$(printf '%s' "$ADMIN_USER" | sed 's/@.*//')
# Detect host timezone
if [ -f /etc/timezone ]; then
	HOST_TZ=$(cat /etc/timezone)
elif [ -L /etc/localtime ]; then
	HOST_TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
fi
TZ="${TZ:-$HOST_TZ}"
ADMIN_PASS="${ADMIN_PASS:-}"
SMTP_SERVER_DEFAULT="host.docker.internal"
SMTP_PORT_DEFAULT="25"
# Docker image tags (can be overridden)
JITSI_TAG="${JITSI_TAG:-unstable}"
# Jibri (recording/streaming) - disabled by default
ENABLE_JIBRI="${ENABLE_JIBRI:-0}"

# Branding defaults
APP_NAME="${APP_NAME:-CasjaysDev Meet}"
PROVIDER_NAME="${PROVIDER_NAME:-CasjaysDev}"
NATIVE_APP_NAME="${NATIVE_APP_NAME:-$APP_NAME}"
DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-en}"

# Feature defaults
ENABLE_WELCOME_PAGE="${ENABLE_WELCOME_PAGE:-true}"
ENABLE_PREJOIN_PAGE="${ENABLE_PREJOIN_PAGE:-true}"
ENABLE_LOBBY="${ENABLE_LOBBY:-true}"
ENABLE_CLOSE_PAGE="${ENABLE_CLOSE_PAGE:-false}"
DISABLE_AUDIO_LEVELS="${DISABLE_AUDIO_LEVELS:-false}"
ENABLE_NOISY_MIC_DETECTION="${ENABLE_NOISY_MIC_DETECTION:-true}"
ENABLE_BREAKOUT_ROOMS="${ENABLE_BREAKOUT_ROOMS:-true}"
# User registration (via custom prosody image)
ENABLE_REGISTRATION="${ENABLE_REGISTRATION:-true}"

# Recording defaults (auto-enabled if Jibri is enabled)
if [ "$ENABLE_JIBRI" = "1" ]; then
	ENABLE_RECORDING="${ENABLE_RECORDING:-true}"
	ENABLE_LIVESTREAMING="${ENABLE_LIVESTREAMING:-true}"
	ENABLE_FILE_RECORDING_SERVICE="${ENABLE_FILE_RECORDING_SERVICE:-true}"
else
	ENABLE_RECORDING="${ENABLE_RECORDING:-false}"
	ENABLE_LIVESTREAMING="${ENABLE_LIVESTREAMING:-false}"
	ENABLE_FILE_RECORDING_SERVICE="${ENABLE_FILE_RECORDING_SERVICE:-false}"
fi

# Video quality defaults
RESOLUTION="${RESOLUTION:-720}"
RESOLUTION_MIN="${RESOLUTION_MIN:-180}"
RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1280}"
RESOLUTION_WIDTH_MIN="${RESOLUTION_WIDTH_MIN:-320}"

# Watermark defaults
SHOW_JITSI_WATERMARK="${SHOW_JITSI_WATERMARK:-false}"
JITSI_WATERMARK_LINK="${JITSI_WATERMARK_LINK:-}"
SHOW_BRAND_WATERMARK="${SHOW_BRAND_WATERMARK:-false}"
BRAND_WATERMARK_LINK="${BRAND_WATERMARK_LINK:-}"
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

check_jibri_prereqs() {
	# Jibri requires snd-aloop kernel module
	if [ "${ENABLE_JIBRI:-0}" = "1" ]; then
		info "Checking Jibri prerequisites..."

		# Check for snd-aloop module
		if ! lsmod | grep -q snd_aloop; then
			warn "ALSA loopback module (snd-aloop) not loaded."
			info "Attempting to load snd-aloop..."
			modprobe snd-aloop || warn "Could not load snd-aloop. Recording may not work."

			# Try to make it persistent
			if [ -d /etc/modules-load.d ]; then
				echo "snd-aloop" >/etc/modules-load.d/jibri.conf
				info "Added snd-aloop to /etc/modules-load.d/jibri.conf"
			fi
		else
			info "snd-aloop module is loaded."
		fi

		# Create recordings directory
		mkdir -p "${JITSI_DATA_DIR}/recordings"
		chmod 777 "${JITSI_DATA_DIR}/recordings"
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
	mkdir -p "$JITSI_BASE_DIR" "$JITSI_CONFIG_DIR" "$JITSI_DATA_DIR" "$BACKUP_DIR"
}

gen_env_if_missing() {
	if [ ! -f "$ENV_FILE" ]; then
		info "Creating default .env"
		cat >"$ENV_FILE" <<EOF
# Auto-generated by install.sh
# Re-run install.sh to safely update. Local edits are preserved.
# Core
JITSI_DATA_DIR=$JITSI_DATA_DIR
JITSI_CONFIG_DIR=$JITSI_CONFIG_DIR
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=0
ENABLE_HTTP_REDIRECT=0
ENABLE_LETSENCRYPT=0
PUBLIC_URL=$PUBLIC_URL
TZ=$TZ

# Auth (optional)
ENABLE_AUTH=$ENABLE_AUTH
ENABLE_GUESTS=1
AUTH_TYPE=$AUTH_TYPE
# Public domain for user-facing display
PUBLIC_DOMAIN=$PUBLIC_DOMAIN

# Component creds (autofilled if empty on first run)
JICOFO_AUTH_USER=focus
JICOFO_AUTH_PASSWORD=$JICOFO_AUTH_PASSWORD
JVB_AUTH_USER=jvb
JVB_AUTH_PASSWORD=$JVB_AUTH_PASSWORD

# Videobridge / RTP
JVB_UDP_PORT=10000
JVB_TCP_HARVESTER_DISABLED=true

# SMTP via host
SMTP_SERVER=${SMTP_SERVER:-$SMTP_SERVER_DEFAULT}
SMTP_PORT=${SMTP_PORT:-$SMTP_PORT_DEFAULT}
SMTP_FROM=${SMTP_FROM:-"no-reply@$PUBLIC_DOMAIN"}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
SMTP_TLS=${SMTP_TLS:-0}
SMTP_STARTTLS=${SMTP_STARTTLS:-0}

# Image tag
JITSI_IMAGE_TAG=$JITSI_TAG

# Branding (customize these)
APP_NAME='$APP_NAME'
PROVIDER_NAME='$PROVIDER_NAME'
NATIVE_APP_NAME='$NATIVE_APP_NAME'
DEFAULT_LANGUAGE=$DEFAULT_LANGUAGE

# Features
ENABLE_WELCOME_PAGE=$ENABLE_WELCOME_PAGE
ENABLE_PREJOIN_PAGE=$ENABLE_PREJOIN_PAGE
ENABLE_LOBBY=$ENABLE_LOBBY
ENABLE_CLOSE_PAGE=$ENABLE_CLOSE_PAGE
DISABLE_AUDIO_LEVELS=$DISABLE_AUDIO_LEVELS
ENABLE_NOISY_MIC_DETECTION=$ENABLE_NOISY_MIC_DETECTION
ENABLE_BREAKOUT_ROOMS=$ENABLE_BREAKOUT_ROOMS
ENABLE_REGISTRATION=$ENABLE_REGISTRATION

# Jibri (recording/streaming)
ENABLE_JIBRI=$ENABLE_JIBRI
JIBRI_RECORDER_USER=recorder
JIBRI_RECORDER_PASSWORD=
JIBRI_XMPP_USER=jibri
JIBRI_XMPP_PASSWORD=

# Recording/Streaming (auto-enabled if Jibri is enabled)
ENABLE_RECORDING=$ENABLE_RECORDING
ENABLE_LIVESTREAMING=$ENABLE_LIVESTREAMING
ENABLE_FILE_RECORDING_SERVICE=$ENABLE_FILE_RECORDING_SERVICE

# Video Quality
RESOLUTION=$RESOLUTION
RESOLUTION_MIN=$RESOLUTION_MIN
RESOLUTION_WIDTH=$RESOLUTION_WIDTH
RESOLUTION_WIDTH_MIN=$RESOLUTION_WIDTH_MIN

# Watermark
JITSI_WATERMARK_LINK=$JITSI_WATERMARK_LINK
SHOW_JITSI_WATERMARK=$SHOW_JITSI_WATERMARK
BRAND_WATERMARK_LINK=$BRAND_WATERMARK_LINK
SHOW_BRAND_WATERMARK=$SHOW_BRAND_WATERMARK
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

	# Jibri credentials (if enabled)
	if [ "${ENABLE_JIBRI:-0}" = "1" ]; then
		if [ -z "${JIBRI_RECORDER_PASSWORD:-}" ]; then
			pw="$(randpass)"
			sed -i "s/^JIBRI_RECORDER_PASSWORD=.*/JIBRI_RECORDER_PASSWORD=$pw/" "$ENV_FILE"
			changed=1
		fi
		if [ -z "${JIBRI_XMPP_PASSWORD:-}" ]; then
			pw="$(randpass)"
			sed -i "s/^JIBRI_XMPP_PASSWORD=.*/JIBRI_XMPP_PASSWORD=$pw/" "$ENV_FILE"
			changed=1
		fi
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
    image: casjaysdevdocker/prosody:latest
    restart: unless-stopped
    pull_policy: always
    ports:
      - "5222:5222"
      - "5347:5347"
      - "5280:5280"
    volumes:
      - ${JITSI_CONFIG_DIR}/prosody:/config:Z
    environment:
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_GUEST_DOMAIN=guest.meet.jitsi
      - ENABLE_AUTH=${ENABLE_AUTH}
      - AUTH_TYPE=${AUTH_TYPE}
      - ENABLE_GUESTS=${ENABLE_GUESTS}
      - PUBLIC_URL=${PUBLIC_URL}
      - JICOFO_AUTH_USER=${JICOFO_AUTH_USER}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      # User registration
      - ENABLE_REGISTRATION=${ENABLE_REGISTRATION}
      # Jibri (recording)
      - JIBRI_XMPP_USER=${JIBRI_XMPP_USER}
      - JIBRI_XMPP_PASSWORD=${JIBRI_XMPP_PASSWORD}
      - JIBRI_RECORDER_USER=${JIBRI_RECORDER_USER}
      - JIBRI_RECORDER_PASSWORD=${JIBRI_RECORDER_PASSWORD}
      - XMPP_RECORDER_DOMAIN=recorder.meet.jitsi
      - XMPP_MUC_DOMAIN=muc.meet.jitsi
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
    networks:
      meet:
        aliases:
          - xmpp.meet.jitsi

  # Focus (Jicofo)
  jicofo:
    container_name: jitsi-jicofo
    image: jitsi/jicofo:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    pull_policy: always
    depends_on: [ prosody ]
    volumes:
      - ${JITSI_CONFIG_DIR}/jicofo:/config:Z
    environment:
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_MUC_DOMAIN=muc.meet.jitsi
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
      - JICOFO_AUTH_USER=${JICOFO_AUTH_USER}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JIBRI_BREWERY_MUC=jibribrewery
      - JIBRI_PENDING_TIMEOUT=90
      - ENABLE_AUTH=${ENABLE_AUTH}
      - XMPP_SERVER=xmpp.meet.jitsi
    networks: [ meet ]

  # Videobridge
  jvb:
    container_name: jitsi-jvb
    image: jitsi/jvb:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    pull_policy: always
    depends_on: [ prosody ]
    ports:
      - "10000:10000/udp"
    volumes:
      - ${JITSI_CONFIG_DIR}/jvb:/config:Z
    environment:
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - JVB_UDP_PORT=${JVB_UDP_PORT}
      - JVB_TCP_HARVESTER_DISABLED=${JVB_TCP_HARVESTER_DISABLED}
      - XMPP_SERVER=xmpp.meet.jitsi
    networks: [ meet ]

  # Web (no TLS here; reverse proxy handles it)
  web:
    container_name: jitsi-web
    image: casjaysdevdocker/jitsi-web:latest
    restart: unless-stopped
    pull_policy: always
    depends_on: [ prosody, jicofo ]
    ports:
      - "${HTTP_PORT:-64453}:80"
    volumes:
      - ${JITSI_DATA_DIR}/web:/config:Z
    environment:
      - ENABLE_LETSENCRYPT=0
      - ENABLE_HTTP_REDIRECT=0
      - PUBLIC_URL=${PUBLIC_URL}
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_GUEST_DOMAIN=guest.meet.jitsi
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
      # Branding
      - APP_NAME=${APP_NAME}
      - NATIVE_APP_NAME=${NATIVE_APP_NAME}
      - PROVIDER_NAME=${PROVIDER_NAME}
      - DEFAULT_LANGUAGE=${DEFAULT_LANGUAGE}
      # Features
      - ENABLE_WELCOME_PAGE=${ENABLE_WELCOME_PAGE}
      - ENABLE_PREJOIN_PAGE=${ENABLE_PREJOIN_PAGE}
      - ENABLE_LOBBY=${ENABLE_LOBBY}
      - ENABLE_CLOSE_PAGE=${ENABLE_CLOSE_PAGE}
      - DISABLE_AUDIO_LEVELS=${DISABLE_AUDIO_LEVELS}
      - ENABLE_NOISY_MIC_DETECTION=${ENABLE_NOISY_MIC_DETECTION}
      - ENABLE_BREAKOUT_ROOMS=${ENABLE_BREAKOUT_ROOMS}
      # Recording/Streaming
      - ENABLE_RECORDING=${ENABLE_RECORDING}
      - ENABLE_LIVESTREAMING=${ENABLE_LIVESTREAMING}
      - ENABLE_FILE_RECORDING_SERVICE=${ENABLE_FILE_RECORDING_SERVICE}
      # Quality
      - RESOLUTION=${RESOLUTION}
      - RESOLUTION_MIN=${RESOLUTION_MIN}
      - RESOLUTION_WIDTH=${RESOLUTION_WIDTH}
      - RESOLUTION_WIDTH_MIN=${RESOLUTION_WIDTH_MIN}
      # Watermark
      - SHOW_JITSI_WATERMARK=${SHOW_JITSI_WATERMARK}
      - JITSI_WATERMARK_LINK=${JITSI_WATERMARK_LINK}
      - SHOW_BRAND_WATERMARK=${SHOW_BRAND_WATERMARK}
      - BRAND_WATERMARK_LINK=${BRAND_WATERMARK_LINK}
    networks: [ meet ]

networks:
  meet:
    driver: bridge
YAML

	# Add Jibri if enabled
	if [ "${ENABLE_JIBRI:-0}" = "1" ]; then
		info "Adding Jibri (recording/streaming) to compose..."
		cat >>"$COMPOSE_FILE" <<'JIBRI_YAML'

  # Jibri (recording/streaming)
  jibri:
    container_name: jitsi-jibri
    image: jitsi/jibri:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    pull_policy: always
    depends_on: [ prosody, jicofo ]
    privileged: true
    volumes:
      - /dev/shm:/dev/shm
      - ${JITSI_CONFIG_DIR}/jibri:/config:Z
      - ${JITSI_DATA_DIR}/recordings:/recordings:Z
    environment:
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
      - XMPP_MUC_DOMAIN=muc.meet.jitsi
      - XMPP_RECORDER_DOMAIN=recorder.meet.jitsi
      - XMPP_SERVER=xmpp.meet.jitsi
      - JIBRI_XMPP_USER=${JIBRI_XMPP_USER}
      - JIBRI_XMPP_PASSWORD=${JIBRI_XMPP_PASSWORD}
      - JIBRI_RECORDER_USER=${JIBRI_RECORDER_USER}
      - JIBRI_RECORDER_PASSWORD=${JIBRI_RECORDER_PASSWORD}
      - JIBRI_RECORDING_DIR=/recordings
      - JIBRI_FINALIZE_RECORDING_SCRIPT_PATH=/config/finalize.sh
      - JIBRI_STRIP_DOMAIN_JID=muc
      - DISPLAY=:0
      - TZ=${TZ}
    cap_add:
      - SYS_ADMIN
      - NET_BIND_SERVICE
    devices:
      - /dev/snd:/dev/snd
    shm_size: '2gb'
    networks: [ meet ]
JIBRI_YAML
	fi
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
		# Check for various ready indicators in Prosody logs
		if docker logs jitsi-prosody 2>&1 | grep -qE "(Prosody is ready|Started|prosody started|Activated service)"; then
			break
		fi
		# Also check if prosody is responding
		if docker exec jitsi-prosody prosodyctl status >/dev/null 2>&1; then
			break
		fi
		i=$((i + 1))
		if [ "$i" -gt 30 ]; then
			warn "Prosody readiness not confirmed in time; continuing."
			break
		fi
		sleep 2
	done
}

register_admin_user() {
	. "$ENV_FILE"
	# We register in the auth domain if auth is enabled; otherwise register in main XMPP domain
	domain="meet.jitsi"
	if [ "${ENABLE_AUTH:-0}" = "1" ]; then
		domain="auth.meet.jitsi"
	fi

	info "Ensuring admin user '${ADMIN_USER}@${PUBLIC_DOMAIN}' exists..."
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
		echo "ADMIN_DOMAIN=$PUBLIC_DOMAIN"
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
Admin user:                 ${ADMIN_USER}@${PUBLIC_DOMAIN}
Admin password:             (stored in $CREDS_FILE)
SMTP relay:                 ${SMTP_SERVER}:${SMTP_PORT} (from ${SMTP_FROM})
Jibri (recording):          ${ENABLE_JIBRI:-0} (0=disabled, 1=enabled)
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
	check_jibri_prereqs
	init_dirs
	gen_env_if_missing

	# Ensure all required keys exist in case .env was user-supplied or outdated
	ensure_env_key JITSI_DATA_DIR "$JITSI_DATA_DIR"
	ensure_env_key JITSI_CONFIG_DIR "$JITSI_CONFIG_DIR"
	ensure_env_key SMTP_SERVER "$SMTP_SERVER_DEFAULT"
	ensure_env_key SMTP_PORT "$SMTP_PORT_DEFAULT"
	ensure_env_key SMTP_FROM "no-reply@$PUBLIC_DOMAIN"
	ensure_env_key SMTP_USERNAME ""
	ensure_env_key SMTP_PASSWORD ""
	ensure_env_key SMTP_TLS "0"
	ensure_env_key SMTP_STARTTLS "0"
	ensure_env_key JITSI_IMAGE_TAG "$JITSI_TAG"
	ensure_env_key AUTH_TYPE "$AUTH_TYPE"
	ensure_env_key ENABLE_GUESTS "1"
	ensure_env_key JICOFO_AUTH_USER "focus"
	ensure_env_key JVB_AUTH_USER "jvb"
	ensure_env_key JVB_UDP_PORT "10000"
	ensure_env_key JVB_TCP_HARVESTER_DISABLED "true"
	# Branding
	ensure_env_key APP_NAME "$APP_NAME"
	ensure_env_key NATIVE_APP_NAME "$NATIVE_APP_NAME"
	ensure_env_key PROVIDER_NAME "$PROVIDER_NAME"
	ensure_env_key DEFAULT_LANGUAGE "$DEFAULT_LANGUAGE"
	# Features
	ensure_env_key ENABLE_WELCOME_PAGE "$ENABLE_WELCOME_PAGE"
	ensure_env_key ENABLE_PREJOIN_PAGE "$ENABLE_PREJOIN_PAGE"
	ensure_env_key ENABLE_LOBBY "$ENABLE_LOBBY"
	ensure_env_key ENABLE_CLOSE_PAGE "$ENABLE_CLOSE_PAGE"
	ensure_env_key DISABLE_AUDIO_LEVELS "$DISABLE_AUDIO_LEVELS"
	ensure_env_key ENABLE_NOISY_MIC_DETECTION "$ENABLE_NOISY_MIC_DETECTION"
	ensure_env_key ENABLE_BREAKOUT_ROOMS "$ENABLE_BREAKOUT_ROOMS"
	ensure_env_key ENABLE_REGISTRATION "$ENABLE_REGISTRATION"
	# Jibri
	ensure_env_key ENABLE_JIBRI "$ENABLE_JIBRI"
	ensure_env_key JIBRI_RECORDER_USER "recorder"
	ensure_env_key JIBRI_XMPP_USER "jibri"
	# Recording
	ensure_env_key ENABLE_RECORDING "$ENABLE_RECORDING"
	ensure_env_key ENABLE_LIVESTREAMING "$ENABLE_LIVESTREAMING"
	ensure_env_key ENABLE_FILE_RECORDING_SERVICE "$ENABLE_FILE_RECORDING_SERVICE"
	# Quality
	ensure_env_key RESOLUTION "$RESOLUTION"
	ensure_env_key RESOLUTION_MIN "$RESOLUTION_MIN"
	ensure_env_key RESOLUTION_WIDTH "$RESOLUTION_WIDTH"
	ensure_env_key RESOLUTION_WIDTH_MIN "$RESOLUTION_WIDTH_MIN"
	# Watermark
	ensure_env_key SHOW_JITSI_WATERMARK "$SHOW_JITSI_WATERMARK"
	ensure_env_key JITSI_WATERMARK_LINK "$JITSI_WATERMARK_LINK"
	ensure_env_key SHOW_BRAND_WATERMARK "$SHOW_BRAND_WATERMARK"
	ensure_env_key BRAND_WATERMARK_LINK "$BRAND_WATERMARK_LINK"

	fill_missing_secrets
	write_compose
	start_stack
	wait_for_prosody
	register_admin_user
	post_summary
}

main "$@"
