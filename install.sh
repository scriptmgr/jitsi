#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC1090
# =============================================================================
# Jitsi Meet Docker Installer
# =============================================================================
# POSIX-compliant installer for running Jitsi Meet in Docker containers
# Supports Debian/Ubuntu, RHEL/CentOS/Fedora, openSUSE, and Arch Linux
# Uses official Docker CE repositories for consistent installations
#
# Repository: https://github.com/scriptmgr/jitsi
# License: MIT
# =============================================================================

# Enable strict error handling
# -e: Exit on any command failure
# -u: Treat unset variables as errors
set -eu

VERSION="1.0.0"

# =============================================================================
# Utility Functions
# =============================================================================
# Common helper functions used throughout the script for consistent
# output formatting, command detection, and password generation

# Check if a command exists in PATH
need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Print error message and exit with failure status
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Print informational message to stdout
info() { printf 'INFO: %s\n' "$*"; }

# Print warning message to stderr
warn() { printf 'WARN: %s\n' "$*" >&2; }

# Generate timestamp for backup file naming
timestamp() { date +%Y%m%d-%H%M%S; }

# Generate a random 24-character alphanumeric password
# Uses openssl if available, falls back to /dev/urandom
randpass() {
	if need_cmd openssl; then
		openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 24
	else
		dd if=/dev/urandom bs=1 count=48 2>/dev/null | od -An -tx1 | tr -dc 'A-Za-z0-9' | head -c 24
	fi
}

# Ensure script is running as root, re-exec with sudo if needed
# Preserves environment variables with -E flag
require_root() {
	if [ "$(id -u)" -ne 0 ]; then
		if need_cmd sudo; then
			exec sudo -E -- "$0" "$@"
		else
			die "Must be run as root or with sudo."
		fi
	fi
}

# =============================================================================
# Configuration
# =============================================================================
# Initialize all configuration variables with sensible defaults
# Values can be overridden via environment variables before running

# Initialize all configuration variables with defaults
# Sets up directory paths, URLs, authentication, branding, and feature flags
init_config() {
	# Directory structure for installation
	JITSI_BASE_DIR="${JITSI_BASE_DIR:-/opt/jitsi}"
	ENV_FILE="$JITSI_BASE_DIR/.env"
	COMPOSE_FILE="$JITSI_BASE_DIR/docker-compose.yml"
	JITSI_DATA_DIR="$JITSI_BASE_DIR/rootfs/data"
	JITSI_CONFIG_DIR="$JITSI_BASE_DIR/rootfs/config"
	CREDS_FILE="$JITSI_BASE_DIR/credentials.txt"
	BACKUP_DIR="$JITSI_BASE_DIR/backup"

	# Extract public URL and domain from environment or hostname
	PUBLIC_URL="${PUBLIC_URL:-http://$(hostname -f 2>/dev/null || hostname)}"
	PUBLIC_DOMAIN=$(printf '%s' "$PUBLIC_URL" | sed -e 's|^https\?://||' -e 's|/.*||' -e 's|:.*||')

	# Auto-detect timezone from system configuration
	HOST_TZ="America/New_York"
	[ -f /etc/timezone ] && HOST_TZ=$(cat /etc/timezone)
	[ -L /etc/localtime ] && HOST_TZ=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
	TZ="${TZ:-$HOST_TZ}"

	# Core server settings
	# HTTP_PORT: Internal port for reverse proxy to connect to
	# ENABLE_AUTH: 0=open (anyone can create rooms), 1=auth required
	HTTP_PORT="${HTTP_PORT:-64453}"
	ENABLE_AUTH="${ENABLE_AUTH:-0}"
	AUTH_TYPE="${AUTH_TYPE:-internal}"
	ADMIN_USER="${ADMIN_USER:-administrator}"
	# Strip domain part if provided (user@domain -> user)
	ADMIN_USER=$(printf '%s' "$ADMIN_USER" | sed 's/@.*//')
	ADMIN_PASS="${ADMIN_PASS:-}"
	JITSI_TAG="${JITSI_TAG:-unstable}"

	# SMTP defaults for email delivery via host MTA
	SMTP_SERVER_DEFAULT="host.docker.internal"
	SMTP_PORT_DEFAULT="25"

	# Generate random passwords for internal component authentication
	JVB_AUTH_PASSWORD="$(randpass)"
	JICOFO_AUTH_PASSWORD="$(randpass)"

	# Branding customization
	APP_NAME="${APP_NAME:-CasjaysDev Meet}"
	PROVIDER_NAME="${PROVIDER_NAME:-CasjaysDev}"
	NATIVE_APP_NAME="${NATIVE_APP_NAME:-$APP_NAME}"
	DEFAULT_LANGUAGE="${DEFAULT_LANGUAGE:-en}"

	# UI feature toggles
	ENABLE_WELCOME_PAGE="${ENABLE_WELCOME_PAGE:-true}"
	ENABLE_PREJOIN_PAGE="${ENABLE_PREJOIN_PAGE:-true}"
	ENABLE_LOBBY="${ENABLE_LOBBY:-true}"
	ENABLE_CLOSE_PAGE="${ENABLE_CLOSE_PAGE:-false}"
	DISABLE_AUDIO_LEVELS="${DISABLE_AUDIO_LEVELS:-false}"
	ENABLE_NOISY_MIC_DETECTION="${ENABLE_NOISY_MIC_DETECTION:-true}"
	ENABLE_BREAKOUT_ROOMS="${ENABLE_BREAKOUT_ROOMS:-true}"
	ENABLE_REGISTRATION="${ENABLE_REGISTRATION:-true}"

	# Jibri recording/streaming configuration
	# Auto-enable recording features when Jibri is enabled
	ENABLE_JIBRI="${ENABLE_JIBRI:-0}"
	if [ "$ENABLE_JIBRI" = "1" ]; then
		ENABLE_RECORDING="${ENABLE_RECORDING:-true}"
		ENABLE_LIVESTREAMING="${ENABLE_LIVESTREAMING:-true}"
		ENABLE_FILE_RECORDING_SERVICE="${ENABLE_FILE_RECORDING_SERVICE:-true}"
	else
		ENABLE_RECORDING="${ENABLE_RECORDING:-false}"
		ENABLE_LIVESTREAMING="${ENABLE_LIVESTREAMING:-false}"
		ENABLE_FILE_RECORDING_SERVICE="${ENABLE_FILE_RECORDING_SERVICE:-false}"
	fi

	# Video quality constraints
	RESOLUTION="${RESOLUTION:-720}"
	RESOLUTION_MIN="${RESOLUTION_MIN:-180}"
	RESOLUTION_WIDTH="${RESOLUTION_WIDTH:-1280}"
	RESOLUTION_WIDTH_MIN="${RESOLUTION_WIDTH_MIN:-320}"

	# Watermark/branding overlay settings
	SHOW_JITSI_WATERMARK="${SHOW_JITSI_WATERMARK:-false}"
	JITSI_WATERMARK_LINK="${JITSI_WATERMARK_LINK:-}"
	SHOW_BRAND_WATERMARK="${SHOW_BRAND_WATERMARK:-false}"
	BRAND_WATERMARK_LINK="${BRAND_WATERMARK_LINK:-}"
}

# Load existing .env file and export variables to environment
# Preserves previous configuration when re-running installer
load_existing_env() {
	[ -f "$ENV_FILE" ] || return 0
	while IFS='=' read -r key value; do
		# Skip comments and empty lines
		case "$key" in \#*|"") continue ;; esac
		export "$key=$value" 2>/dev/null || true
	done < "$ENV_FILE"
}

# =============================================================================
# Docker Installation
# =============================================================================
# Install Docker CE from official repositories for each distribution
# Avoids distro-packaged docker.io which may be outdated

# Detect the system's package manager
# Returns: apt, dnf, yum, zypper, or pacman
detect_pkg_mgr() {
	for pm in apt-get dnf yum zypper pacman; do
		need_cmd "$pm" && echo "${pm%-get}" && return
	done
	die "No supported package manager found (apt/dnf/yum/zypper/pacman)."
}

# Install Docker CE from official Docker repositories
# Handles apt (Debian/Ubuntu), dnf (Fedora), yum (CentOS/RHEL),
# zypper (openSUSE), and pacman (Arch)
setup_docker_official() {
	PM="$(detect_pkg_mgr)"
	info "Installing Docker Engine using: $PM"

	case "$PM" in
	apt)
		need_cmd gpg || { apt-get update && apt-get install -y gpg; }
		apt-get update
		apt-get install -y ca-certificates gnupg curl
		install -m 0755 -d /etc/apt/keyrings
		if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
			. /etc/os-release
			curl -fsSL "https://download.docker.com/linux/$ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
			chmod a+r /etc/apt/keyrings/docker.gpg
		fi
		. /etc/os-release
		echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$ID $VERSION_CODENAME stable" \
			>/etc/apt/sources.list.d/docker.list
		apt-get update
		apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		;;
	dnf)
		dnf -y install dnf-plugins-core curl
		. /etc/os-release
		case "$ID" in
			fedora) dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo ;;
			*) dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo ;;
		esac
		dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		;;
	yum)
		yum -y install yum-utils curl
		yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
		yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
		;;
	zypper)
		zypper refresh
		zypper -n install ca-certificates curl
		. /etc/os-release
		zypper -n addrepo "https://download.docker.com/linux/$ID/docker-ce.repo" docker-ce || true
		zypper refresh
		zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin ||
			zypper -n install docker docker-compose
		;;
	pacman)
		pacman -Sy --noconfirm --needed docker docker-compose
		;;
	esac
	systemctl enable --now docker
}

# Check for Docker and Docker Compose, install if missing
# Supports both new plugin (docker compose) and legacy (docker-compose)
ensure_docker() {
	if ! need_cmd docker; then
		setup_docker_official
	else
		info "Docker already installed."
		need_cmd systemctl && systemctl start docker 2>/dev/null || true
	fi

	# Check for Docker Compose (plugin or standalone)
	if docker compose version >/dev/null 2>&1; then
		info "Docker Compose plugin available."
	elif need_cmd docker-compose; then
		info "Legacy docker-compose available."
	else
		warn "Docker Compose not found; installing..."
		setup_docker_official
	fi
}

# Wrapper to call docker compose with the correct syntax
# Uses plugin syntax if available, falls back to legacy
docker_compose() {
	if docker compose version >/dev/null 2>&1; then
		docker compose -f "$COMPOSE_FILE" "$@"
	else
		docker-compose -f "$COMPOSE_FILE" "$@"
	fi
}

# =============================================================================
# Environment & Compose Generation
# =============================================================================
# Generate .env and docker-compose.yml files for the Jitsi stack
# Handles backups, idempotent updates, and secret generation

# Create timestamped backup of a file before modification
backup_file() {
	[ -f "$1" ] || return 0
	mkdir -p "$BACKUP_DIR"
	cp -p "$1" "$BACKUP_DIR/$(basename "$1").$(timestamp)"
}

# Create required directory structure for installation
init_dirs() {
	mkdir -p "$JITSI_BASE_DIR" "$JITSI_CONFIG_DIR" "$JITSI_DATA_DIR" "$BACKUP_DIR"
}

# Add a key=value pair to .env if it doesn't already exist
# Used for adding new config options without overwriting existing ones
ensure_env_key() {
	grep -qE "^$1=" "$ENV_FILE" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"
}

# Generate the main .env configuration file
# Only creates if not exists; preserves existing configuration
gen_env_file() {
	[ -f "$ENV_FILE" ] && { info "Found existing .env (preserving)."; return; }

	info "Creating default .env"
	cat >"$ENV_FILE" <<EOF
# Jitsi Meet Configuration
# Re-run install.sh to safely update

# Core
JITSI_DATA_DIR=$JITSI_DATA_DIR
JITSI_CONFIG_DIR=$JITSI_CONFIG_DIR
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=0
ENABLE_HTTP_REDIRECT=0
ENABLE_LETSENCRYPT=0
PUBLIC_URL=$PUBLIC_URL
PUBLIC_DOMAIN=$PUBLIC_DOMAIN
TZ=$TZ

# Authentication
ENABLE_AUTH=$ENABLE_AUTH
ENABLE_GUESTS=1
AUTH_TYPE=$AUTH_TYPE

# Component Credentials
JICOFO_AUTH_USER=focus
JICOFO_AUTH_PASSWORD=$JICOFO_AUTH_PASSWORD
JVB_AUTH_USER=jvb
JVB_AUTH_PASSWORD=$JVB_AUTH_PASSWORD

# Videobridge
JVB_UDP_PORT=10000
JVB_TCP_HARVESTER_DISABLED=true

# SMTP
SMTP_SERVER=${SMTP_SERVER:-$SMTP_SERVER_DEFAULT}
SMTP_PORT=${SMTP_PORT:-$SMTP_PORT_DEFAULT}
SMTP_FROM=${SMTP_FROM:-no-reply@$PUBLIC_DOMAIN}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
SMTP_TLS=${SMTP_TLS:-0}
SMTP_STARTTLS=${SMTP_STARTTLS:-0}

# Docker Images
JITSI_IMAGE_TAG=$JITSI_TAG

# Branding
APP_NAME="$APP_NAME"
PROVIDER_NAME="$PROVIDER_NAME"
NATIVE_APP_NAME="$NATIVE_APP_NAME"
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

# Jibri (Recording)
ENABLE_JIBRI=$ENABLE_JIBRI
JIBRI_RECORDER_USER=recorder
JIBRI_RECORDER_PASSWORD=
JIBRI_XMPP_USER=jibri
JIBRI_XMPP_PASSWORD=

# Recording/Streaming
ENABLE_RECORDING=$ENABLE_RECORDING
ENABLE_LIVESTREAMING=$ENABLE_LIVESTREAMING
ENABLE_FILE_RECORDING_SERVICE=$ENABLE_FILE_RECORDING_SERVICE

# Video Quality
RESOLUTION=$RESOLUTION
RESOLUTION_MIN=$RESOLUTION_MIN
RESOLUTION_WIDTH=$RESOLUTION_WIDTH
RESOLUTION_WIDTH_MIN=$RESOLUTION_WIDTH_MIN

# Watermark
SHOW_JITSI_WATERMARK=$SHOW_JITSI_WATERMARK
JITSI_WATERMARK_LINK=$JITSI_WATERMARK_LINK
SHOW_BRAND_WATERMARK=$SHOW_BRAND_WATERMARK
BRAND_WATERMARK_LINK=$BRAND_WATERMARK_LINK
EOF
}

# Ensure all configuration keys exist in .env
# Adds any new keys introduced in updates without overwriting existing values
ensure_all_env_keys() {
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
	ensure_env_key APP_NAME "$APP_NAME"
	ensure_env_key NATIVE_APP_NAME "$NATIVE_APP_NAME"
	ensure_env_key PROVIDER_NAME "$PROVIDER_NAME"
	ensure_env_key DEFAULT_LANGUAGE "$DEFAULT_LANGUAGE"
	ensure_env_key ENABLE_WELCOME_PAGE "$ENABLE_WELCOME_PAGE"
	ensure_env_key ENABLE_PREJOIN_PAGE "$ENABLE_PREJOIN_PAGE"
	ensure_env_key ENABLE_LOBBY "$ENABLE_LOBBY"
	ensure_env_key ENABLE_CLOSE_PAGE "$ENABLE_CLOSE_PAGE"
	ensure_env_key DISABLE_AUDIO_LEVELS "$DISABLE_AUDIO_LEVELS"
	ensure_env_key ENABLE_NOISY_MIC_DETECTION "$ENABLE_NOISY_MIC_DETECTION"
	ensure_env_key ENABLE_BREAKOUT_ROOMS "$ENABLE_BREAKOUT_ROOMS"
	ensure_env_key ENABLE_REGISTRATION "$ENABLE_REGISTRATION"
	ensure_env_key ENABLE_JIBRI "$ENABLE_JIBRI"
	ensure_env_key JIBRI_RECORDER_USER "recorder"
	ensure_env_key JIBRI_XMPP_USER "jibri"
	ensure_env_key ENABLE_RECORDING "$ENABLE_RECORDING"
	ensure_env_key ENABLE_LIVESTREAMING "$ENABLE_LIVESTREAMING"
	ensure_env_key ENABLE_FILE_RECORDING_SERVICE "$ENABLE_FILE_RECORDING_SERVICE"
	ensure_env_key RESOLUTION "$RESOLUTION"
	ensure_env_key RESOLUTION_MIN "$RESOLUTION_MIN"
	ensure_env_key RESOLUTION_WIDTH "$RESOLUTION_WIDTH"
	ensure_env_key RESOLUTION_WIDTH_MIN "$RESOLUTION_WIDTH_MIN"
	ensure_env_key SHOW_JITSI_WATERMARK "$SHOW_JITSI_WATERMARK"
	ensure_env_key JITSI_WATERMARK_LINK "$JITSI_WATERMARK_LINK"
	ensure_env_key SHOW_BRAND_WATERMARK "$SHOW_BRAND_WATERMARK"
	ensure_env_key BRAND_WATERMARK_LINK "$BRAND_WATERMARK_LINK"
}

# Generate missing passwords and secrets
# Preserves existing secrets from .env or credentials file
# Generates new random passwords for any empty fields
fill_missing_secrets() {
	. "$ENV_FILE"
	changed=0

	# Generate component authentication passwords if missing
	if [ -z "${JICOFO_AUTH_PASSWORD:-}" ]; then
		sed -i "s/^JICOFO_AUTH_PASSWORD=.*/JICOFO_AUTH_PASSWORD=$(randpass)/" "$ENV_FILE"
		changed=1
	fi
	if [ -z "${JVB_AUTH_PASSWORD:-}" ]; then
		sed -i "s/^JVB_AUTH_PASSWORD=.*/JVB_AUTH_PASSWORD=$(randpass)/" "$ENV_FILE"
		changed=1
	fi

	# Generate Jibri passwords if Jibri is enabled
	if [ "${ENABLE_JIBRI:-0}" = "1" ]; then
		[ -z "${JIBRI_RECORDER_PASSWORD:-}" ] && sed -i "s/^JIBRI_RECORDER_PASSWORD=.*/JIBRI_RECORDER_PASSWORD=$(randpass)/" "$ENV_FILE" && changed=1
		[ -z "${JIBRI_XMPP_PASSWORD:-}" ] && sed -i "s/^JIBRI_XMPP_PASSWORD=.*/JIBRI_XMPP_PASSWORD=$(randpass)/" "$ENV_FILE" && changed=1
	fi

	# Get admin password from credentials file or generate new one
	if [ -z "${ADMIN_PASS:-}" ]; then
		if [ -f "$CREDS_FILE" ] && grep -q "^ADMIN_USER=$ADMIN_USER$" "$CREDS_FILE"; then
			ADMIN_PASS="$(grep '^ADMIN_PASS=' "$CREDS_FILE" | head -1 | cut -d= -f2-)"
		else
			ADMIN_PASS="$(randpass)"
		fi
	fi

	[ "$changed" -eq 1 ] && info "Generated missing credentials."
}

# Generate docker-compose.yml with all services
# Creates backups before overwriting existing file
write_compose() {
	backup_file "$COMPOSE_FILE"
	info "Writing docker-compose.yml"

	cat >"$COMPOSE_FILE" <<'YAML'
services:
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
      - $JITSI_CONFIG_DIR/prosody:/config:Z
    environment:
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_GUEST_DOMAIN=guest.meet.jitsi
      - XMPP_MUC_DOMAIN=muc.meet.jitsi
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
      - XMPP_RECORDER_DOMAIN=recorder.meet.jitsi
      - ENABLE_AUTH=${ENABLE_AUTH}
      - AUTH_TYPE=${AUTH_TYPE}
      - ENABLE_GUESTS=${ENABLE_GUESTS}
      - PUBLIC_URL=${PUBLIC_URL}
      - JICOFO_AUTH_USER=${JICOFO_AUTH_USER}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - JIBRI_XMPP_USER=${JIBRI_XMPP_USER}
      - JIBRI_XMPP_PASSWORD=${JIBRI_XMPP_PASSWORD}
      - JIBRI_RECORDER_USER=${JIBRI_RECORDER_USER}
      - JIBRI_RECORDER_PASSWORD=${JIBRI_RECORDER_PASSWORD}
      - ENABLE_REGISTRATION=${ENABLE_REGISTRATION}
    networks:
      meet:
        aliases:
          - xmpp.meet.jitsi

  jicofo:
    container_name: jitsi-jicofo
    image: jitsi/jicofo:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    pull_policy: always
    depends_on: [prosody]
    volumes:
      - $JITSI_CONFIG_DIR/jicofo:/config:Z
    environment:
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_MUC_DOMAIN=muc.meet.jitsi
      - XMPP_INTERNAL_MUC_DOMAIN=internal-muc.meet.jitsi
      - XMPP_SERVER=xmpp.meet.jitsi
      - JICOFO_AUTH_USER=${JICOFO_AUTH_USER}
      - JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
      - JIBRI_BREWERY_MUC=jibribrewery
      - JIBRI_PENDING_TIMEOUT=90
      - ENABLE_AUTH=${ENABLE_AUTH}
    networks: [meet]

  jvb:
    container_name: jitsi-jvb
    image: jitsi/jvb:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    pull_policy: always
    depends_on: [prosody]
    ports:
      - "10000:10000/udp"
    volumes:
      - $JITSI_CONFIG_DIR/jvb:/config:Z
    environment:
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_SERVER=xmpp.meet.jitsi
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - JVB_UDP_PORT=${JVB_UDP_PORT}
      - JVB_TCP_HARVESTER_DISABLED=${JVB_TCP_HARVESTER_DISABLED}
    networks: [meet]

  web:
    container_name: jitsi-web
    image: casjaysdevdocker/jitsi-web:latest
    restart: unless-stopped
    pull_policy: always
    depends_on: [prosody, jicofo]
    ports:
      - "${HTTP_PORT:-64453}:80"
    volumes:
      - $JITSI_DATA_DIR/web:/config:Z
    environment:
      - ENABLE_LETSENCRYPT=0
      - ENABLE_HTTP_REDIRECT=0
      - PUBLIC_URL=${PUBLIC_URL}
      - XMPP_DOMAIN=meet.jitsi
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_GUEST_DOMAIN=guest.meet.jitsi
      - XMPP_SERVER=xmpp.meet.jitsi
      - ENABLE_AUTH=${ENABLE_AUTH}
      - ENABLE_GUESTS=${ENABLE_GUESTS}
      - SMTP_SERVER=${SMTP_SERVER}
      - SMTP_PORT=${SMTP_PORT}
      - SMTP_FROM=${SMTP_FROM}
      - SMTP_USERNAME=${SMTP_USERNAME}
      - SMTP_PASSWORD=${SMTP_PASSWORD}
      - SMTP_TLS=${SMTP_TLS}
      - SMTP_STARTTLS=${SMTP_STARTTLS}
      - APP_NAME=${APP_NAME}
      - NATIVE_APP_NAME=${NATIVE_APP_NAME}
      - PROVIDER_NAME=${PROVIDER_NAME}
      - DEFAULT_LANGUAGE=${DEFAULT_LANGUAGE}
      - ENABLE_WELCOME_PAGE=${ENABLE_WELCOME_PAGE}
      - ENABLE_PREJOIN_PAGE=${ENABLE_PREJOIN_PAGE}
      - ENABLE_LOBBY=${ENABLE_LOBBY}
      - ENABLE_CLOSE_PAGE=${ENABLE_CLOSE_PAGE}
      - DISABLE_AUDIO_LEVELS=${DISABLE_AUDIO_LEVELS}
      - ENABLE_NOISY_MIC_DETECTION=${ENABLE_NOISY_MIC_DETECTION}
      - ENABLE_BREAKOUT_ROOMS=${ENABLE_BREAKOUT_ROOMS}
      - ENABLE_RECORDING=${ENABLE_RECORDING}
      - ENABLE_LIVESTREAMING=${ENABLE_LIVESTREAMING}
      - ENABLE_FILE_RECORDING_SERVICE=${ENABLE_FILE_RECORDING_SERVICE}
      - RESOLUTION=${RESOLUTION}
      - RESOLUTION_MIN=${RESOLUTION_MIN}
      - RESOLUTION_WIDTH=${RESOLUTION_WIDTH}
      - RESOLUTION_WIDTH_MIN=${RESOLUTION_WIDTH_MIN}
      - SHOW_JITSI_WATERMARK=${SHOW_JITSI_WATERMARK}
      - JITSI_WATERMARK_LINK=${JITSI_WATERMARK_LINK}
      - SHOW_BRAND_WATERMARK=${SHOW_BRAND_WATERMARK}
      - BRAND_WATERMARK_LINK=${BRAND_WATERMARK_LINK}
    networks: [meet]
YAML

	# Add Jibri if enabled
	if [ "${ENABLE_JIBRI:-0}" = "1" ]; then
		info "Adding Jibri to compose..."
		cat >>"$COMPOSE_FILE" <<'JIBRI_YAML'

  jibri:
    container_name: jitsi-jibri
    image: jitsi/jibri:${JITSI_IMAGE_TAG}
    restart: unless-stopped
    pull_policy: always
    depends_on: [prosody, jicofo]
    privileged: true
    volumes:
      - /dev/shm:/dev/shm
      - $JITSI_CONFIG_DIR/jibri:/config:Z
      - $JITSI_DATA_DIR/recordings:/recordings:Z
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
    networks: [meet]
JIBRI_YAML
	fi

	cat >>"$COMPOSE_FILE" <<'NET_YAML'

networks:
  meet:
    driver: bridge
NET_YAML
}

# =============================================================================
# Stack Management
# =============================================================================
# Functions for managing the Docker container stack lifecycle
# Includes prerequisite checks, startup, and health monitoring

# Check and setup Jibri prerequisites (ALSA loopback module)
# Jibri requires snd-aloop kernel module for audio capture
check_jibri_prereqs() {
	[ "${ENABLE_JIBRI:-0}" = "1" ] || return 0

	info "Checking Jibri prerequisites..."
	# Load ALSA loopback module if not already loaded
	if ! lsmod | grep -q snd_aloop; then
		warn "ALSA loopback module (snd-aloop) not loaded."
		modprobe snd-aloop 2>/dev/null || warn "Could not load snd-aloop."
		# Make it persistent across reboots
		[ -d /etc/modules-load.d ] && echo "snd-aloop" >/etc/modules-load.d/jibri.conf
	fi
	# Create recordings directory with open permissions for Jibri
	mkdir -p "${JITSI_DATA_DIR}/recordings"
	chmod 777 "${JITSI_DATA_DIR}/recordings"
}

# Pull latest images and start all containers
start_stack() {
	info "Pulling images..."
	docker_compose pull
	info "Starting stack..."
	docker_compose up -d
}

# Wait for Prosody XMPP server to be ready
# Polls for up to 60 seconds before giving up
wait_for_prosody() {
	info "Waiting for Prosody..."
	i=0
	while [ "$i" -lt 30 ]; do
		# Check if prosodyctl reports running status
		docker exec jitsi-prosody prosodyctl status >/dev/null 2>&1 && return
		# Also check logs for ready indicators
		docker logs jitsi-prosody 2>&1 | grep -qE "(Prosody is ready|Started|Activated)" && return
		i=$((i + 1))
		sleep 2
	done
	warn "Prosody readiness not confirmed; continuing."
}

# Register or update the admin user in Prosody
# Uses meet.jitsi domain (where web clients authenticate)
register_admin_user() {
	. "$ENV_FILE"
	# Users must be registered on meet.jitsi (not auth.meet.jitsi)
	# because the web client authenticates to this domain
	domain="meet.jitsi"

	info "Registering admin user '${ADMIN_USER}'..."
	# Try passwd first (for existing users), then register (for new users)
	docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua passwd "$ADMIN_USER" "$domain" "$ADMIN_PASS" >/dev/null 2>&1 ||
		docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua register "$ADMIN_USER" "$domain" "$ADMIN_PASS" >/dev/null 2>&1 ||
		warn "Could not register admin user."

	# Save credentials with restricted permissions
	umask 077
	cat >"$CREDS_FILE" <<EOF
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS
UPDATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF
	info "Credentials saved: $CREDS_FILE"
}

# Display installation summary with important details
post_summary() {
	. "$ENV_FILE"
	cat <<EOF

============================================================
Jitsi Meet Installation Complete
============================================================
Public URL:      ${PUBLIC_URL}
HTTP Port:       ${HTTP_PORT}
Auth Enabled:    ${ENABLE_AUTH} (0=open, 1=required)
Admin User:      ${ADMIN_USER}
Credentials:     ${CREDS_FILE}
Jibri:           ${ENABLE_JIBRI:-0}
------------------------------------------------------------
Reverse proxy should forward to: http://127.0.0.1:${HTTP_PORT}
------------------------------------------------------------
EOF
}

# =============================================================================
# User Management
# =============================================================================
# CLI interface for managing Jitsi user accounts
# Users are stored in Prosody on the meet.jitsi domain

# Handle user management commands (add, del, pass, list)
# Interacts directly with Prosody via prosodyctl
user_management() {
	action="${1:-}"
	username="${2:-}"
	password="${3:-}"

	[ -f "$COMPOSE_FILE" ] || die "Jitsi not installed. Run installer first."
	# Strip domain part if provided
	username=$(printf '%s' "$username" | sed 's/@.*//')

	case "$action" in
	add)
		# Add new user with optional password (prompts if not provided)
		[ -z "$username" ] && die "Usage: $0 --user add <username> [password]"
		if [ -z "$password" ]; then
			printf "Password for %s: " "$username"
			stty -echo; read -r password; stty echo; printf "\n"
		fi
		[ -z "$password" ] && die "Password cannot be empty"
		docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua register "$username" meet.jitsi "$password" 2>/dev/null &&
			info "User '$username' created" || die "Failed to create user"
		;;
	del|delete|rm)
		# Delete existing user
		[ -z "$username" ] && die "Usage: $0 --user del <username>"
		docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua deluser "$username@meet.jitsi" 2>/dev/null &&
			info "User '$username' deleted" || die "Failed to delete user"
		;;
	pass|passwd|password)
		# Change user password (always prompts for security)
		[ -z "$username" ] && die "Usage: $0 --user pass <username>"
		printf "New password for %s: " "$username"
		stty -echo; read -r password; stty echo; printf "\n"
		[ -z "$password" ] && die "Password cannot be empty"
		docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua passwd "$username" meet.jitsi "$password" 2>/dev/null &&
			info "Password updated for '$username'" || die "Failed to update password"
		;;
	list|ls)
		# List all registered users
		info "Registered users:"
		docker exec jitsi-prosody ls /config/data/meet%2ejitsi/accounts/ 2>/dev/null | sed 's/\.dat$//' || echo "No users"
		;;
	*)
		die "Unknown action. Use: add, del, pass, list"
		;;
	esac
	exit 0
}

# =============================================================================
# Help & Actions
# =============================================================================
# Command-line interface handling for help, version, and removal

# Display usage information and available options
show_help() {
	cat <<EOF
Jitsi Meet Installer v${VERSION}

Usage: $0 [OPTIONS]

Options:
  -h, --help      Show help
  -v, --version   Show version
  -r, --remove    Remove installation

User Management:
  --user add <name> [pass]   Add user
  --user del <name>          Delete user
  --user pass <name>         Change password
  --user list                List users

Environment Variables:
  PUBLIC_URL          Public URL (default: http://hostname)
  ENABLE_AUTH         0=open, 1=auth required (default: 0)
  ADMIN_USER          Admin username (default: administrator)
  ADMIN_PASS          Admin password (default: generated)
  HTTP_PORT           HTTP port (default: 64453)
  APP_NAME            Application name
  ENABLE_JIBRI        Enable recording (default: 0)

Examples:
  sudo sh $0
  PUBLIC_URL=https://meet.example.com sudo -E sh $0
  sudo sh $0 --user add myuser
  sudo sh $0 --remove
EOF
	exit 0
}

# Display version number
show_version() {
	echo "Jitsi Meet Installer v${VERSION}"
	exit 0
}

# Complete removal of Jitsi installation
# Stops containers, removes images/volumes, and deletes all files
do_remove() {
	require_root "$@"
	[ -d "$JITSI_BASE_DIR" ] || die "Not installed: $JITSI_BASE_DIR"

	info "Removing Jitsi..."
	# Stop and remove all containers, images, and volumes
	[ -f "$COMPOSE_FILE" ] && docker_compose down --rmi all --volumes 2>/dev/null || true
	rm -rf "$JITSI_BASE_DIR"
	info "Jitsi removed."
	exit 0
}

# =============================================================================
# Main
# =============================================================================
# Entry point and orchestration for the installation process

# Main installation workflow
# Executes all steps in order to install/update Jitsi
main() {
	require_root "$@"
	ensure_docker
	check_jibri_prereqs
	init_dirs
	gen_env_file
	ensure_all_env_keys
	fill_missing_secrets
	write_compose
	start_stack
	wait_for_prosody
	register_admin_user
	post_summary
}

# =============================================================================
# Script Entry Point
# =============================================================================

# Initialize all configuration variables with defaults
init_config

# Parse command-line arguments
REMOVE_MODE=0
while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help) show_help ;;
	-v|--version) show_version ;;
	-r|--remove) REMOVE_MODE=1; shift ;;
	--user) shift; user_management "$@" ;;
	*) die "Unknown option: $1" ;;
	esac
done

# Load existing configuration to preserve user settings
[ "$REMOVE_MODE" = "0" ] && load_existing_env

# Handle removal if requested
[ "$REMOVE_MODE" = "1" ] && do_remove "$@"

# Execute main installation
main "$@"
