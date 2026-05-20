#!/usr/bin/env bash
# shellcheck shell=bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
##@Version           :  202605190929-git
# @@Author           :  Jason Hempstead
# @@Contact          :  git-admin@casjaysdev.pro
# @@License          :  MIT or LICENSE.md
# @@ReadME           :  install.sh --help
# @@Copyright        :  Copyright: (c) 2026 Jason Hempstead, Casjays Developments
# @@Created          :  Tuesday, May 19, 2026 09:29 EDT
# @@File             :  install.sh
# @@Description      :  POSIX-compliant installer for Jitsi Meet on Docker
# @@Changelog        :  Convert to bash; extract operational scripts; use standard utility functions
# @@TODO             :
# @@Other            :
# @@Resource         :
# @@Terminal App     :  yes
# @@sudo/root        :  yes
# @@Template         :  shell/bash
# - - - - - - - - - - - - - - - - - - - - - - - - -
# shellcheck disable=SC1001,SC1003,SC2001,SC2003,SC2016,SC2031,SC2090,SC2115,SC2120,SC2155,SC2199,SC2229,SC2317,SC2329
# - - - - - - - - - - - - - - - - - - - - - - - - -

APPNAME="${0##*/}"
VERSION="202605190929-git"
RUN_USER="${USER}"
SET_UID="${UID}"
SCRIPT_SRC_DIR="${BASH_SOURCE%/*}"

set -euo pipefail

INSTALL_DEBUG="${INSTALL_DEBUG:-0}"
NO_COLOR="${NO_COLOR:-}"

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Standard utility functions (from script_conventions.md)
# - - - - - - - - - - - - - - - - - - - - - - - - -

__determine_hostname_name() {
  local fqdn
  fqdn="$(hostname -f 2>/dev/null)"
  if [[ -n "$fqdn" ]]; then
    printf '%s\n' "$fqdn"
    return 0
  fi
  return 1
}

__is_ip4_public() {
  local ip="${1:-}"
  [[ -z "$ip" ]] && return 1
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS='.' read -r a b c d <<< "$ip"
  (( a == 0 )) && return 1
  (( a == 10 )) && return 1
  (( a == 127 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 0 && c == 0 )) && return 1
  (( a == 192 && b == 0 && c == 2 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 198 && b == 51 && c == 100 )) && return 1
  (( a == 203 && b == 0 && c == 113 )) && return 1
  (( a >= 224 )) && return 1
  return 0
}

__get_hosts_ip4_address() {
  if [[ -n "${IP4_ADDRESS:-}" ]]; then
    printf '%s\n' "$IP4_ADDRESS"
    return 0
  fi
  local ip url
  for url in "https://ifcfg.us/ip" "https://ifconfig.co/ip" "https://checkip.amazonaws.com"; do
    ip="$(curl -4 -q -LSs --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$ip" ]] && __is_ip4_public "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

__download_all_scripts_from_github() {
  local dest="${1:?Usage: __download_all_scripts_from_github <dest_dir>}"
  local GITHUB_RAW_REPO="${GITHUB_RAW_REPO:-scriptmgr/jitsi}"
  local api_base="https://api.github.com/repos/${GITHUB_RAW_REPO}/contents/scripts"
  local raw_base="https://raw.githubusercontent.com/${GITHUB_RAW_REPO}/main/scripts"
  local page=1
  local files file response

  mkdir -p "$dest" || return 1

  while :; do
    response="$(curl -q -LSs "${api_base}?per_page=100&page=${page}")" || return 1
    mapfile -t files < <(printf '%s' "$response" | jq -r '.[] | select(.type=="file") | .name')
    [[ ${#files[@]} -eq 0 ]] && break
    for file in "${files[@]}"; do
      curl -q -LSs "${raw_base}/${file}" -o "${dest}/${file}" || return 1
      chmod 755 "${dest}/${file}"
    done
    (( ${#files[@]} < 100 )) && break
    (( page++ ))
  done
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Utility functions
# - - - - - - - - - - - - - - - - - - - - - - - - -

__need_cmd() { command -v "$1" &>/dev/null; }
__die()      { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
__info()     { printf 'INFO:  %s\n' "$*"; }
__warn()     { printf 'WARN:  %s\n' "$*" >&2; }
__timestamp() { date +%Y%m%d-%H%M%S; }

# Generate a random 24-character alphanumeric password
__randpass() {
  if __need_cmd openssl; then
    openssl rand -base64 36 | tr -dc 'A-Za-z0-9' | head -c 24
  else
    dd if=/dev/urandom bs=1 count=48 2>/dev/null | od -An -tx1 | tr -dc 'A-Za-z0-9' | head -c 24
  fi
}

# Re-exec with sudo when not root, preserving environment
__require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    if __need_cmd sudo; then
      exec sudo -E -- "$0" "$@"
    else
      __die "Must be run as root or with sudo."
    fi
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Configuration
# - - - - - - - - - - - - - - - - - - - - - - - - -

__init_config() {
  # Directory structure for installation
  JITSI_BASE_DIR="${JITSI_BASE_DIR:-/opt/jitsi}"
  ENV_FILE="${JITSI_BASE_DIR}/.env"
  COMPOSE_FILE="${JITSI_BASE_DIR}/docker-compose.yml"
  JITSI_DATA_DIR="${JITSI_BASE_DIR}/rootfs/data"
  JITSI_CONFIG_DIR="${JITSI_BASE_DIR}/rootfs/config"
  CREDS_FILE="${JITSI_BASE_DIR}/credentials.txt"
  BACKUP_DIR="${JITSI_BASE_DIR}/backup"

  # Resolve public URL: use env var or fall back to detected FQDN
  local _host
  _host="$(__determine_hostname_name 2>/dev/null || hostname)"
  PUBLIC_URL="${PUBLIC_URL:-http://${_host}}"
  # Public IP for JVB ICE candidate mapping — critical for NAT/Docker deployments
  DOCKER_HOST_ADDRESS="${DOCKER_HOST_ADDRESS:-$(__get_hosts_ip4_address 2>/dev/null || true)}"
  [[ -z "${DOCKER_HOST_ADDRESS}" ]] && __warn "Could not detect public IPv4 — set DOCKER_HOST_ADDRESS manually or JVB ICE will be broken."
  # Strip trailing slash — a common paste error that breaks BOSH/WebSocket URLs
  PUBLIC_URL="${PUBLIC_URL%/}"
  # Validate scheme — must be http:// or https://
  case "${PUBLIC_URL}" in
    http://*|https://*) ;;
    *) __die "PUBLIC_URL must start with http:// or https:// (got: ${PUBLIC_URL})" ;;
  esac
  # Warn when scheme is http: the reverse proxy must serve HTTPS and send
  # X-Forwarded-Proto: https, otherwise Jitsi generates mixed-content URLs.
  case "${PUBLIC_URL}" in
    http://*) __warn "PUBLIC_URL uses http://. Ensure your reverse proxy sends X-Forwarded-Proto: https when terminating TLS, or set PUBLIC_URL=https://..." ;;
  esac
  PUBLIC_DOMAIN="${PUBLIC_URL#*://}"
  PUBLIC_DOMAIN="${PUBLIC_DOMAIN%%/*}"
  PUBLIC_DOMAIN="${PUBLIC_DOMAIN%%:*}"

  # Auto-detect timezone from system configuration
  HOST_TZ="America/New_York"
  [[ -f /etc/timezone ]] && read -r HOST_TZ < /etc/timezone
  if [[ -L /etc/localtime ]]; then
    local _rl
    _rl="$(readlink /etc/localtime)"
    HOST_TZ="${_rl##*/zoneinfo/}"
  fi
  TZ="${TZ:-${HOST_TZ}}"

  # Core server settings
  HTTP_PORT="${HTTP_PORT:-64453}"
  ENABLE_AUTH="${ENABLE_AUTH:-0}"
  AUTH_TYPE="${AUTH_TYPE:-internal}"
  ADMIN_USER="${ADMIN_USER:-administrator}"
  # Strip domain part if provided (user@domain -> user)
  ADMIN_USER="${ADMIN_USER%%@*}"
  ADMIN_PASS="${ADMIN_PASS:-}"
  JITSI_TAG="${JITSI_TAG:-unstable}"

  # SMTP defaults for email delivery via host MTA
  SMTP_SERVER_DEFAULT="host.docker.internal"
  SMTP_PORT_DEFAULT="25"

  # Generate random passwords for internal component authentication
  JVB_AUTH_PASSWORD="$(__randpass)"
  JICOFO_AUTH_PASSWORD="$(__randpass)"

  # Branding customization
  APP_NAME="${APP_NAME:-CasjaysDev Meet}"
  PROVIDER_NAME="${PROVIDER_NAME:-CasjaysDev}"
  NATIVE_APP_NAME="${NATIVE_APP_NAME:-${APP_NAME}}"
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
  ENABLE_JIBRI="${ENABLE_JIBRI:-0}"
  if [[ "${ENABLE_JIBRI}" == "1" ]]; then
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

  # Wildcard subdomain → conference room redirect
  # When enabled, <room>.yourdomain.com redirects to yourdomain.com/<room>
  # Requires a wildcard SSL cert (*.yourdomain.com) on the frontend proxy.
  ENABLE_SUBDOMAIN_ROOMS="${ENABLE_SUBDOMAIN_ROOMS:-1}"

  # Watermark/branding overlay settings
  SHOW_JITSI_WATERMARK="${SHOW_JITSI_WATERMARK:-false}"
  JITSI_WATERMARK_LINK="${JITSI_WATERMARK_LINK:-}"
  SHOW_BRAND_WATERMARK="${SHOW_BRAND_WATERMARK:-false}"
  BRAND_WATERMARK_LINK="${BRAND_WATERMARK_LINK:-}"

  # JVB colibri WebSocket — required for reliable audio/video behind a reverse proxy.
  # Prosody's internal nginx routes /colibri-ws/ to JVB:9090 over the Docker network.
  # JVB port 9090 is bound to 127.0.0.1 only (loopback) for local debugging if needed.
  JVB_WS_DOMAIN="${JVB_WS_DOMAIN:-${PUBLIC_DOMAIN}}"
  JVB_WS_SERVER_ID="${JVB_WS_SERVER_ID:-default-jvb}"
  COLIBRI_WEBSOCKET_PORT="${COLIBRI_WEBSOCKET_PORT:-443}"

  # XMPP WebSocket — required for reliable XMPP signalling behind a reverse proxy
  ENABLE_XMPP_WEBSOCKET="${ENABLE_XMPP_WEBSOCKET:-1}"
}

# Load existing .env file and export variables to environment
__load_existing_env() {
  [[ -f "${ENV_FILE}" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "${key}" in \#*|"") continue ;; esac
    export "${key}=${value}" 2>/dev/null || true
  done < "${ENV_FILE}"
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Docker installation
# - - - - - - - - - - - - - - - - - - - - - - - - -

__detect_pkg_mgr() {
  local pm
  for pm in apt-get dnf yum zypper pacman; do
    if __need_cmd "${pm}"; then
      printf '%s\n' "${pm%-get}"
      return
    fi
  done
  __die "No supported package manager found (apt/dnf/yum/zypper/pacman)."
}

__setup_docker_official() {
  local PM
  PM="$(__detect_pkg_mgr)"
  __info "Installing Docker Engine using: ${PM}"

  case "${PM}" in
  apt)
    __need_cmd gpg || { apt-get update && apt-get install -y gpg; }
    apt-get update
    apt-get install -y ca-certificates gnupg curl
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/docker.gpg ]]; then
      . /etc/os-release
      curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
    fi
    . /etc/os-release
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "${ID}" "${VERSION_CODENAME}" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    ;;
  dnf)
    dnf -y install dnf-plugins-core curl
    . /etc/os-release
    case "${ID}" in
      fedora) dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo ;;
      *)      dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo ;;
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
    zypper -n addrepo "https://download.docker.com/linux/${ID}/docker-ce.repo" docker-ce || true
    zypper refresh
    zypper -n install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
      || zypper -n install docker docker-compose
    ;;
  pacman)
    pacman -Sy --noconfirm --needed docker docker-compose
    ;;
  esac
  systemctl enable --now docker
}

__ensure_docker() {
  if ! __need_cmd docker; then
    __setup_docker_official
  else
    __info "Docker already installed."
    __need_cmd systemctl && systemctl start docker 2>/dev/null || true
  fi

  if docker compose version >/dev/null 2>&1; then
    __info "Docker Compose plugin available."
  elif __need_cmd docker-compose; then
    __info "Legacy docker-compose available."
  else
    __warn "Docker Compose not found; installing..."
    __setup_docker_official
  fi
}

__docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "${COMPOSE_FILE}" "$@"
  else
    docker-compose -f "${COMPOSE_FILE}" "$@"
  fi
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Environment and compose generation
# - - - - - - - - - - - - - - - - - - - - - - - - -

__backup_file() {
  [[ -f "$1" ]] || return 0
  mkdir -p "${BACKUP_DIR}"
  cp -p "$1" "${BACKUP_DIR}/${1##*/}.$(__timestamp)"
}

__init_dirs() {
  mkdir -p "${JITSI_BASE_DIR}" "${JITSI_CONFIG_DIR}" "${JITSI_DATA_DIR}" "${BACKUP_DIR}"
}

__ensure_env_key() {
  grep -qE -- "^$1=" "${ENV_FILE}" 2>/dev/null || printf '%s=%s\n' "$1" "$2" >> "${ENV_FILE}"
}

__gen_env_file() {
  [[ -f "${ENV_FILE}" ]] && { __info "Found existing .env (preserving)."; return; }

  __info "Creating default .env"
  cat > "${ENV_FILE}" <<EOF
# Jitsi Meet Configuration
# Re-run install.sh to safely update

# Core
JITSI_DATA_DIR=${JITSI_DATA_DIR}
JITSI_CONFIG_DIR=${JITSI_CONFIG_DIR}
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=0
ENABLE_HTTP_REDIRECT=0
ENABLE_LETSENCRYPT=0
PUBLIC_URL=${PUBLIC_URL}
PUBLIC_DOMAIN=${PUBLIC_DOMAIN}
TZ=${TZ}

# Authentication
ENABLE_AUTH=${ENABLE_AUTH}
ENABLE_GUESTS=1
AUTH_TYPE=${AUTH_TYPE}

# Component Credentials
JICOFO_AUTH_USER=focus
JICOFO_AUTH_PASSWORD=${JICOFO_AUTH_PASSWORD}
JVB_AUTH_USER=jvb
JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}

# Videobridge
JVB_UDP_PORT=10000
JVB_TCP_HARVESTER_DISABLED=true
DOCKER_HOST_ADDRESS=${DOCKER_HOST_ADDRESS}

# JVB colibri WebSocket — routed internally by prosody's web server to jvb:9090
JVB_WS_DOMAIN=${JVB_WS_DOMAIN}
JVB_WS_SERVER_ID=${JVB_WS_SERVER_ID}
COLIBRI_WEBSOCKET_PORT=${COLIBRI_WEBSOCKET_PORT}

# XMPP WebSocket — routed internally by prosody's web server
ENABLE_XMPP_WEBSOCKET=${ENABLE_XMPP_WEBSOCKET}

# SMTP
SMTP_SERVER=${SMTP_SERVER:-${SMTP_SERVER_DEFAULT}}
SMTP_PORT=${SMTP_PORT:-${SMTP_PORT_DEFAULT}}
SMTP_FROM=${SMTP_FROM:-no-reply@${PUBLIC_DOMAIN}}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
SMTP_TLS=${SMTP_TLS:-0}
SMTP_STARTTLS=${SMTP_STARTTLS:-0}

# Docker Images
JITSI_IMAGE_TAG=${JITSI_TAG}

# Branding
APP_NAME="${APP_NAME}"
PROVIDER_NAME="${PROVIDER_NAME}"
NATIVE_APP_NAME="${NATIVE_APP_NAME}"
DEFAULT_LANGUAGE=${DEFAULT_LANGUAGE}

# Features
ENABLE_WELCOME_PAGE=${ENABLE_WELCOME_PAGE}
ENABLE_PREJOIN_PAGE=${ENABLE_PREJOIN_PAGE}
ENABLE_LOBBY=${ENABLE_LOBBY}
ENABLE_CLOSE_PAGE=${ENABLE_CLOSE_PAGE}
DISABLE_AUDIO_LEVELS=${DISABLE_AUDIO_LEVELS}
ENABLE_NOISY_MIC_DETECTION=${ENABLE_NOISY_MIC_DETECTION}
ENABLE_BREAKOUT_ROOMS=${ENABLE_BREAKOUT_ROOMS}
ENABLE_REGISTRATION=${ENABLE_REGISTRATION}

# Jibri (Recording)
ENABLE_JIBRI=${ENABLE_JIBRI}
JIBRI_RECORDER_USER=recorder
JIBRI_RECORDER_PASSWORD=
JIBRI_XMPP_USER=jibri
JIBRI_XMPP_PASSWORD=

# Recording/Streaming
ENABLE_RECORDING=${ENABLE_RECORDING}
ENABLE_LIVESTREAMING=${ENABLE_LIVESTREAMING}
ENABLE_FILE_RECORDING_SERVICE=${ENABLE_FILE_RECORDING_SERVICE}

# Video Quality
RESOLUTION=${RESOLUTION}
RESOLUTION_MIN=${RESOLUTION_MIN}
RESOLUTION_WIDTH=${RESOLUTION_WIDTH}
RESOLUTION_WIDTH_MIN=${RESOLUTION_WIDTH_MIN}

# Watermark
SHOW_JITSI_WATERMARK=${SHOW_JITSI_WATERMARK}
JITSI_WATERMARK_LINK=${JITSI_WATERMARK_LINK}
SHOW_BRAND_WATERMARK=${SHOW_BRAND_WATERMARK}
BRAND_WATERMARK_LINK=${BRAND_WATERMARK_LINK}

# Wildcard subdomain room redirect (1=enabled)
# <room>.${PUBLIC_DOMAIN} -> ${PUBLIC_URL}/<room>
# Requires *.${PUBLIC_DOMAIN} SSL cert on the frontend proxy
ENABLE_SUBDOMAIN_ROOMS=${ENABLE_SUBDOMAIN_ROOMS}
EOF
}

__ensure_all_env_keys() {
  __ensure_env_key JITSI_DATA_DIR "${JITSI_DATA_DIR}"
  __ensure_env_key JITSI_CONFIG_DIR "${JITSI_CONFIG_DIR}"
  __ensure_env_key SMTP_SERVER "${SMTP_SERVER_DEFAULT}"
  __ensure_env_key SMTP_PORT "${SMTP_PORT_DEFAULT}"
  __ensure_env_key SMTP_FROM "no-reply@${PUBLIC_DOMAIN}"
  __ensure_env_key SMTP_USERNAME ""
  __ensure_env_key SMTP_PASSWORD ""
  __ensure_env_key SMTP_TLS "0"
  __ensure_env_key SMTP_STARTTLS "0"
  __ensure_env_key JITSI_IMAGE_TAG "${JITSI_TAG}"
  __ensure_env_key AUTH_TYPE "${AUTH_TYPE}"
  __ensure_env_key ENABLE_GUESTS "1"
  __ensure_env_key JICOFO_AUTH_USER "focus"
  __ensure_env_key JVB_AUTH_USER "jvb"
  __ensure_env_key JVB_UDP_PORT "10000"
  __ensure_env_key JVB_TCP_HARVESTER_DISABLED "true"
  __ensure_env_key DOCKER_HOST_ADDRESS "${DOCKER_HOST_ADDRESS}"
  __ensure_env_key JVB_WS_DOMAIN "${JVB_WS_DOMAIN}"
  __ensure_env_key JVB_WS_SERVER_ID "${JVB_WS_SERVER_ID}"
  __ensure_env_key COLIBRI_WEBSOCKET_PORT "${COLIBRI_WEBSOCKET_PORT}"
  __ensure_env_key ENABLE_XMPP_WEBSOCKET "${ENABLE_XMPP_WEBSOCKET}"
  __ensure_env_key APP_NAME "${APP_NAME}"
  __ensure_env_key NATIVE_APP_NAME "${NATIVE_APP_NAME}"
  __ensure_env_key PROVIDER_NAME "${PROVIDER_NAME}"
  __ensure_env_key DEFAULT_LANGUAGE "${DEFAULT_LANGUAGE}"
  __ensure_env_key ENABLE_WELCOME_PAGE "${ENABLE_WELCOME_PAGE}"
  __ensure_env_key ENABLE_PREJOIN_PAGE "${ENABLE_PREJOIN_PAGE}"
  __ensure_env_key ENABLE_LOBBY "${ENABLE_LOBBY}"
  __ensure_env_key ENABLE_CLOSE_PAGE "${ENABLE_CLOSE_PAGE}"
  __ensure_env_key DISABLE_AUDIO_LEVELS "${DISABLE_AUDIO_LEVELS}"
  __ensure_env_key ENABLE_NOISY_MIC_DETECTION "${ENABLE_NOISY_MIC_DETECTION}"
  __ensure_env_key ENABLE_BREAKOUT_ROOMS "${ENABLE_BREAKOUT_ROOMS}"
  __ensure_env_key ENABLE_REGISTRATION "${ENABLE_REGISTRATION}"
  __ensure_env_key ENABLE_JIBRI "${ENABLE_JIBRI}"
  __ensure_env_key JIBRI_RECORDER_USER "recorder"
  __ensure_env_key JIBRI_XMPP_USER "jibri"
  __ensure_env_key ENABLE_RECORDING "${ENABLE_RECORDING}"
  __ensure_env_key ENABLE_LIVESTREAMING "${ENABLE_LIVESTREAMING}"
  __ensure_env_key ENABLE_FILE_RECORDING_SERVICE "${ENABLE_FILE_RECORDING_SERVICE}"
  __ensure_env_key RESOLUTION "${RESOLUTION}"
  __ensure_env_key RESOLUTION_MIN "${RESOLUTION_MIN}"
  __ensure_env_key RESOLUTION_WIDTH "${RESOLUTION_WIDTH}"
  __ensure_env_key RESOLUTION_WIDTH_MIN "${RESOLUTION_WIDTH_MIN}"
  __ensure_env_key SHOW_JITSI_WATERMARK "${SHOW_JITSI_WATERMARK}"
  __ensure_env_key JITSI_WATERMARK_LINK "${JITSI_WATERMARK_LINK}"
  __ensure_env_key SHOW_BRAND_WATERMARK "${SHOW_BRAND_WATERMARK}"
  __ensure_env_key BRAND_WATERMARK_LINK "${BRAND_WATERMARK_LINK}"
  __ensure_env_key ENABLE_SUBDOMAIN_ROOMS "${ENABLE_SUBDOMAIN_ROOMS}"
}

__fill_missing_secrets() {
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  local changed=0

  # __sed_inplace: portable in-place sed (BSD sed requires a backup extension)
  __sed_inplace() { sed -i.bak "$1" "$2" && rm -f "$2.bak"; }

  if [[ -z "${JICOFO_AUTH_PASSWORD:-}" ]]; then
    __sed_inplace "s/^JICOFO_AUTH_PASSWORD=.*/JICOFO_AUTH_PASSWORD=$(__randpass)/" "${ENV_FILE}"
    changed=1
  fi
  if [[ -z "${JVB_AUTH_PASSWORD:-}" ]]; then
    __sed_inplace "s/^JVB_AUTH_PASSWORD=.*/JVB_AUTH_PASSWORD=$(__randpass)/" "${ENV_FILE}"
    changed=1
  fi

  if [[ "${ENABLE_JIBRI:-0}" == "1" ]]; then
    [[ -z "${JIBRI_RECORDER_PASSWORD:-}" ]] && __sed_inplace "s/^JIBRI_RECORDER_PASSWORD=.*/JIBRI_RECORDER_PASSWORD=$(__randpass)/" "${ENV_FILE}" && changed=1
    [[ -z "${JIBRI_XMPP_PASSWORD:-}" ]] && __sed_inplace "s/^JIBRI_XMPP_PASSWORD=.*/JIBRI_XMPP_PASSWORD=$(__randpass)/" "${ENV_FILE}" && changed=1
  fi

  if [[ -z "${ADMIN_PASS:-}" ]]; then
    if [[ -f "${CREDS_FILE}" ]] && grep -q -- "^ADMIN_USER=${ADMIN_USER}$" "${CREDS_FILE}"; then
      ADMIN_PASS="$(grep -m1 -- '^ADMIN_PASS=' "${CREDS_FILE}" | sed 's/^ADMIN_PASS=//')"
    else
      ADMIN_PASS="$(__randpass)"
    fi
  fi

  [[ "${changed}" -ne 1 ]] || __info "Generated missing credentials."
}

__write_compose() {
  __backup_file "${COMPOSE_FILE}"
  __info "Writing docker-compose.yml"

  cat > "${COMPOSE_FILE}" <<'YAML'
services:
  prosody:
    container_name: jitsi-prosody
    image: ghcr.io/casjaysdevdocker/prosody:latest
    restart: unless-stopped
    pull_policy: always
    ports:
      # Port 80: the internal web server (reverse proxy) entry point.
      # The external frontend proxy creates a vhost pointing to http://{host}:80;
      # prosody's internal server routes web, BOSH, XMPP-WS, and colibri-WS to
      # the correct backend containers over the 'meet' Docker network.
      # Bind to 127.0.0.1 — external proxy is on the same host.
      - "127.0.0.1:80:80"
      # Ports 5222/5347/5280 are internal XMPP protocol ports — NOT exposed.
      # All inter-service XMPP flows over the 'meet' Docker network.
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
      # UDP 10000: JVB media (audio/video RTP/RTCP) — must be open in the firewall
      - "10000:10000/udp"
      # Port 9090 (colibri WebSocket) is NOT exposed — prosody's internal
      # web server proxies /colibri-ws/ to jvb:9090 over the 'meet' Docker network.
    volumes:
      - $JITSI_CONFIG_DIR/jvb:/config:Z
    environment:
      - XMPP_AUTH_DOMAIN=auth.meet.jitsi
      - XMPP_SERVER=xmpp.meet.jitsi
      - JVB_AUTH_USER=${JVB_AUTH_USER}
      - JVB_AUTH_PASSWORD=${JVB_AUTH_PASSWORD}
      - JVB_UDP_PORT=${JVB_UDP_PORT}
      - JVB_TCP_HARVESTER_DISABLED=${JVB_TCP_HARVESTER_DISABLED}
      - DOCKER_HOST_ADDRESS=${DOCKER_HOST_ADDRESS}
      - JVB_WS_DOMAIN=${JVB_WS_DOMAIN}
      - JVB_WS_SERVER_ID=${JVB_WS_SERVER_ID}
    networks: [meet]

  web:
    container_name: jitsi-web
    image: casjaysdevdocker/jitsi-web:latest
    restart: unless-stopped
    pull_policy: always
    depends_on: [prosody, jicofo]
    # No host port binding — prosody's internal web server routes to this
    # container over the 'meet' Docker network (web:80).
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
      # BOSH and WebSocket endpoints — required for signalling behind a reverse proxy
      - XMPP_BOSH_URL_BASE=http://xmpp.meet.jitsi:5280
      - ENABLE_XMPP_WEBSOCKET=${ENABLE_XMPP_WEBSOCKET}
      # Colibri WebSocket — clients connect to wss://<domain>/colibri-ws/...
      - JVB_WS_DOMAIN=${JVB_WS_DOMAIN}
      - COLIBRI_WEBSOCKET_PORT=${COLIBRI_WEBSOCKET_PORT}
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

  if [[ "${ENABLE_JIBRI:-0}" == "1" ]]; then
    __info "Adding Jibri to compose..."
    cat >> "${COMPOSE_FILE}" <<'JIBRI_YAML'

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

  cat >> "${COMPOSE_FILE}" <<'NET_YAML'

networks:
  meet:
    driver: bridge
NET_YAML
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Stack management
# - - - - - - - - - - - - - - - - - - - - - - - - -

__check_jibri_prereqs() {
  [[ "${ENABLE_JIBRI:-0}" == "1" ]] || return 0

  __info "Checking Jibri prerequisites..."
  if ! lsmod | grep -q -- snd_aloop; then
    __warn "ALSA loopback module (snd-aloop) not loaded."
    modprobe snd-aloop 2>/dev/null || __warn "Could not load snd-aloop."
    [[ -d /etc/modules-load.d ]] && printf 'snd-aloop\n' > /etc/modules-load.d/jibri.conf
  fi
  mkdir -p "${JITSI_DATA_DIR}/recordings"
  chmod 777 "${JITSI_DATA_DIR}/recordings"
}

__start_stack() {
  __info "Pulling images..."
  __docker_compose pull
  __info "Starting stack..."
  __docker_compose up -d
}

__wait_for_prosody() {
  __info "Waiting for Prosody..."
  local i=0
  while [[ "${i}" -lt 30 ]]; do
    docker exec jitsi-prosody prosodyctl status >/dev/null 2>&1 && return
    docker logs jitsi-prosody 2>&1 | grep -qE -- "(Prosody is ready|Started|Activated)" && return
    i=$(( i + 1 ))
    sleep 2
  done
  __warn "Prosody readiness not confirmed; continuing."
}

__register_admin_user() {
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  # Admin accounts must be registered on auth.meet.jitsi, not meet.jitsi.
  # meet.jitsi uses jitsi-anonymous authentication and has no password storage.
  # auth.meet.jitsi uses internal_hashed and is the correct credentials domain.
  local domain="auth.meet.jitsi"

  __info "Registering admin user '${ADMIN_USER}'..."
  # Try passwd first (for existing users), then register (for new users)
  docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua passwd "${ADMIN_USER}" "${domain}" "${ADMIN_PASS}" >/dev/null 2>&1 \
    || docker exec jitsi-prosody prosodyctl --config /config/prosody.cfg.lua register "${ADMIN_USER}" "${domain}" "${ADMIN_PASS}" >/dev/null 2>&1 \
    || __warn "Could not register admin user."

  umask 077
  cat > "${CREDS_FILE}" <<EOF
ADMIN_USER=${ADMIN_USER}
ADMIN_PASS=${ADMIN_PASS}
UPDATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF
  __info "Credentials saved: ${CREDS_FILE}"
}

__post_summary() {
  # shellcheck source=/dev/null
  . "${ENV_FILE}"

  # Shared proxy location block — used in both vhost snippets below
  local _proxy_block
  _proxy_block="        location / {
            proxy_pass         http://127.0.0.1:80;
            proxy_http_version 1.1;

            # WebSocket upgrade — required for XMPP-WS and colibri-WS
            proxy_set_header Upgrade    \$http_upgrade;
            proxy_set_header Connection \"upgrade\";

            # Pass real client identity to the internal web server
            proxy_set_header Host              \$host;
            proxy_set_header X-Real-IP         \$remote_addr;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto  https;

            # Long timeouts for persistent WebSocket connections
            proxy_read_timeout 900s;
            proxy_send_timeout 900s;
        }"

  local _security_headers
  _security_headers="        # Security headers
        add_header X-Frame-Options SAMEORIGIN always;
        add_header X-Content-Type-Options nosniff always;
        add_header X-XSS-Protection \"1; mode=block\" always;
        add_header Referrer-Policy no-referrer always;"

  cat <<EOF

============================================================
Jitsi Meet Installation Complete
============================================================
Public URL:      ${PUBLIC_URL}
Auth Enabled:    ${ENABLE_AUTH} (0=open, 1=required)
Admin User:      ${ADMIN_USER}
Credentials:     ${CREDS_FILE}
Jibri:           ${ENABLE_JIBRI:-0}
Subdomain Rooms: ${ENABLE_SUBDOMAIN_ROOMS} (*.${PUBLIC_DOMAIN} -> room redirect)
------------------------------------------------------------
Operational scripts installed to: /usr/local/bin
  jitsi-user   — manage user accounts
  jitsi-stack  — start/stop/restart/status/logs/update/backup
------------------------------------------------------------

REVERSE PROXY SETUP
===================
Prosody's internal web server (port 80) handles ALL Jitsi routing:
  web app, /http-bind (BOSH), /xmpp-websocket, /colibri-ws/ (JVB)

Point your frontend proxy at: http://127.0.0.1:80
Works for any domain: ${PUBLIC_DOMAIN}, *.${PUBLIC_DOMAIN}, teams.lan, etc.

--- /etc/nginx/sites-available/${PUBLIC_DOMAIN}.conf ---

    # Main Jitsi vhost
    server {
        listen 443 ssl;
        server_name ${PUBLIC_DOMAIN};
        # ssl_certificate / ssl_certificate_key / ssl_protocols — add here

${_security_headers}

${_proxy_block}
    }
EOF

  if [[ "${ENABLE_SUBDOMAIN_ROOMS:-1}" == "1" ]]; then
    cat <<EOF
    # Wildcard subdomain → conference room (proxy, NOT redirect)
    # -------------------------------------------------------
    # room.${PUBLIC_DOMAIN} serves the Jitsi room inline — no URL change.
    # Works in web browsers AND native Jitsi apps (iOS/Android/desktop).
    # A redirect would break native apps by sending them to a different server.
    #
    # Examples:
    #   standup.${PUBLIC_DOMAIN}     loads ${PUBLIC_DOMAIN}/standup
    #   teamcall.${PUBLIC_DOMAIN}    loads ${PUBLIC_DOMAIN}/teamcall
    #
    # Requires a *.${PUBLIC_DOMAIN} wildcard SSL cert on this server.
    server {
        listen 443 ssl;
        server_name ~^(?P<room>[^.]+)\\.${PUBLIC_DOMAIN//./\\.}\$;
        # ssl_certificate / ssl_certificate_key — wildcard cert here

        # Root path: rewrite internally to /{room} on the base domain.
        # proxy_pass with a URI suffix rewrites the path before forwarding.
        location = / {
            proxy_pass         http://127.0.0.1:80/\$room;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade    \$http_upgrade;
            proxy_set_header   Connection "upgrade";
            # Use base domain as Host so prosody serves the right config
            proxy_set_header   Host              ${PUBLIC_DOMAIN};
            proxy_set_header   X-Real-IP         \$remote_addr;
            proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto https;
            proxy_read_timeout 900s;
            proxy_send_timeout 900s;
        }

        # All other paths (static assets, config.js, BOSH, WS, colibri-WS)
        # pass through unchanged so the room page and app connections work.
        location / {
            proxy_pass         http://127.0.0.1:80;
            proxy_http_version 1.1;
            proxy_set_header   Upgrade    \$http_upgrade;
            proxy_set_header   Connection "upgrade";
            proxy_set_header   Host              ${PUBLIC_DOMAIN};
            proxy_set_header   X-Real-IP         \$remote_addr;
            proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto https;
            proxy_read_timeout 900s;
            proxy_send_timeout 900s;
        }
    }

EOF
  fi

  cat <<EOF
--- end of nginx config ---

FIREWALL: open UDP port 10000 for JVB media (audio/video RTP).
          If clients are behind restrictive firewalls, consider a TURN server.
------------------------------------------------------------
EOF
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Help, version, and removal
# - - - - - - - - - - - - - - - - - - - - - - - - -

__show_help() {
  cat <<EOF
Jitsi Meet Installer v${VERSION}

Usage: ${APPNAME} [OPTIONS]

Options:
  -h, --help        Show help
  -v, --version     Show version
  -r, --remove      Remove installation
  --debug           Enable trace output (set -x)
  --no-color        Disable color output (also honoured via NO_COLOR env var)

Environment Variables:
  PUBLIC_URL              Public URL (default: http://hostname)
  ENABLE_AUTH             0=open, 1=auth required (default: 0)
  ADMIN_USER              Admin username (default: administrator)
  ADMIN_PASS              Admin password (default: generated)
  APP_NAME                Application name
  ENABLE_JIBRI            Enable recording (default: 0)
  ENABLE_SUBDOMAIN_ROOMS  1=redirect <room>.domain -> domain/<room> (default: 1)
                          Requires a wildcard SSL cert on the frontend proxy.
  DOCKER_HOST_ADDRESS     Public IP for JVB ICE (auto-detected if not set)
  GITHUB_RAW_REPO         GitHub repo for scripts (default: scriptmgr/jitsi)

Examples:
  sudo bash ${APPNAME}
  PUBLIC_URL=https://casjay.me sudo -E bash ${APPNAME}
  PUBLIC_URL=https://casjay.me ENABLE_SUBDOMAIN_ROOMS=1 sudo -E bash ${APPNAME}
  sudo bash ${APPNAME} --remove
EOF
  exit 0
}

__show_version() {
  printf 'Jitsi Meet Installer v%s\n' "${VERSION}"
  exit 0
}

__do_remove() {
  __require_root "$@"
  [[ -d "${JITSI_BASE_DIR}" ]] || __die "Not installed: ${JITSI_BASE_DIR}"

  __info "Removing Jitsi..."
  [[ -f "${COMPOSE_FILE}" ]] && __docker_compose down --rmi all --volumes 2>/dev/null || true
  rm -rf "${JITSI_BASE_DIR}"
  __info "Jitsi removed."
  exit 0
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Main
# - - - - - - - - - - - - - - - - - - - - - - - - -

__main() {
  __require_root "$@"
  __ensure_docker
  __check_jibri_prereqs
  __init_dirs
  __gen_env_file
  __ensure_all_env_keys
  __fill_missing_secrets
  __write_compose
  __start_stack
  __wait_for_prosody
  __register_admin_user
  __need_cmd jq && __download_all_scripts_from_github /usr/local/bin \
    || __warn "jq not found — skipping operational script install. Install jq and re-run to get jitsi-user and jitsi-stack."
  __post_summary
}

# - - - - - - - - - - - - - - - - - - - - - - - - -
# Script entry point
# - - - - - - - - - - - - - - - - - - - - - - - - -

__init_config

INSTALL_REMOVE_MODE=0

_OPTS="$(getopt -o hvr -l help,version,remove,debug,no-color -n "${APPNAME}" -- "$@")" \
  || { __show_help; exit 1; }
eval set -- "${_OPTS}"
while true; do
  case "$1" in
    -h|--help)    __show_help ;;
    -v|--version) __show_version ;;
    -r|--remove)  INSTALL_REMOVE_MODE=1; shift ;;
    --debug)      INSTALL_DEBUG=1; shift ;;
    --no-color)   NO_COLOR=1; shift ;;
    --)           shift; break ;;
    *)            break ;;
  esac
done

[[ "${INSTALL_DEBUG}" == "1" ]] && set -x

[[ "${INSTALL_REMOVE_MODE}" == "0" ]] && __load_existing_env
[[ "${INSTALL_REMOVE_MODE}" == "1" ]] && __do_remove "$@"

__main "$@"

# ex: ts=2 sw=2 et filetype=sh
