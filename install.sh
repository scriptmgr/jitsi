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
  local a b c
  IFS='.' read -r a b c _ <<< "$ip"
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
    response="$(curl -q -LSs --max-time 15 "${api_base}?per_page=100&page=${page}")" || return 1
    # Validate JSON shape: GitHub returns an object (e.g. {"message":"rate limit"})
    # on errors rather than the expected array of contents — bail out cleanly.
    if ! printf '%s' "$response" | jq -e 'type=="array"' >/dev/null 2>&1; then
      return 1
    fi
    mapfile -t files < <(printf '%s' "$response" | jq -r '.[] | select(.type=="file") | .name')
    [[ ${#files[@]} -eq 0 ]] && break
    for file in "${files[@]}"; do
      curl -q -LSs --max-time 30 "${raw_base}/${file}" -o "${dest}/${file}" || return 1
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

# Find a free TCP port in [lo, hi]. Snapshots all listening ports once, then
# tries up to 20 random candidates before falling back to a sequential scan.
__find_free_port() {
  local lo="${1:-64000}"
  local hi="${2:-64999}"
  local port attempts=0
  # Extract port numbers from all listening TCP sockets in one pass.
  # 'ss -ltn' local-address is col 4; split on ':' and take the last field.
  local _used
  _used="$(ss -ltn 2>/dev/null | awk 'NR>1 {n=split($4,a,":"); print a[n]}' | sort -un)"
  while [[ "${attempts}" -lt 20 ]]; do
    port=$(( lo + RANDOM % (hi - lo + 1) ))
    if ! printf '%s\n' "${_used}" | grep -qx -- "${port}"; then
      printf '%d\n' "${port}"
      return 0
    fi
    (( attempts++ )) || true
  done
  # Sequential fallback
  local p
  for p in $(seq "${lo}" "${hi}"); do
    if ! printf '%s\n' "${_used}" | grep -qx -- "${p}"; then
      printf '%d\n' "${p}"
      return 0
    fi
  done
  return 1
}

# Scan /etc/letsencrypt/live for a cert directory that covers the given domain.
# Search order:
#   1. /etc/letsencrypt/live/domain (literal default — present on all managed hosts)
#   2. Exact domain name          (meet.example.com)
#   3. Exact name + numeric suffix (meet.example.com-0001)
#   4. Parent domain              (example.com — wildcard *.example.com)
#   5. Parent + numeric suffix    (example.com-0001)
#   6. openssl SAN scan of every cert (catches non-obvious names)
#   7. Returns 1 — caller supplies its own fallback
__find_ssl_cert_dir() {
  local domain="${1:-${PUBLIC_DOMAIN}}"
  local live="/etc/letsencrypt/live"
  local parent="${domain#*.}"   # meet.example.com → example.com
  local d _sans

  [[ -d "${live}" ]] || return 1

  # 1 — literal 'domain' directory (the standard cert location on managed hosts)
  [[ -f "${live}/domain/fullchain.pem" ]] && { printf '%s\n' "${live}/domain"; return 0; }

  # 2 & 3 — exact domain name, with/without numeric suffix
  [[ -f "${live}/${domain}/fullchain.pem" ]] && { printf '%s\n' "${live}/${domain}"; return 0; }
  for d in "${live}/${domain}"-[0-9]*/; do
    [[ -f "${d}fullchain.pem" ]] && { printf '%s\n' "${d%/}"; return 0; }
  done

  # 4 & 5 — parent domain (covers wildcard *.parent certs), skip if no subdomain
  if [[ "${parent}" != "${domain}" ]]; then
    [[ -f "${live}/${parent}/fullchain.pem" ]] && { printf '%s\n' "${live}/${parent}"; return 0; }
    for d in "${live}/${parent}"-[0-9]*/; do
      [[ -f "${d}fullchain.pem" ]] && { printf '%s\n' "${d%/}"; return 0; }
    done
  fi

  # 6 — openssl SAN scan: each DNS: token ends at a comma or whitespace
  __need_cmd openssl || return 1
  for d in "${live}"/*/; do
    [[ -f "${d}fullchain.pem" ]] || continue
    _sans="$(openssl x509 -noout -text -in "${d}fullchain.pem" 2>/dev/null \
              | grep -oE 'DNS:[^, ]+')"
    printf '%s\n' "${_sans}" | grep -qxF -- "DNS:${domain}" \
      && { printf '%s\n' "${d%/}"; return 0; }
    [[ "${parent}" != "${domain}" ]] \
      && printf '%s\n' "${_sans}" | grep -qxF -- "DNS:*.${parent}" \
      && { printf '%s\n' "${d%/}"; return 0; }
  done

  return 1
}

# Detect the host's internal proxy IP.
# Priority: docker0 bridge address (172.17.0.1 by default) → any 172.17.x.x →
# any RFC-1918 172.16-31 address.
# The result is the address nginx uses in proxy_pass to reach the prosody container.
__detect_proxy_ip() {
  local ip
  # docker0 is the standard Docker bridge; its host-side address (typically 172.17.0.1)
  # is reachable from all containers on the default bridge network.
  ip="$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {split($2,a,"/"); print a[1]; exit}')"
  [[ -n "${ip}" ]] && printf '%s\n' "${ip}" && return 0
  # Broader 172.17.x.x scan for custom bridge networks
  ip="$(ip -4 addr show 2>/dev/null | awk '/inet 172\.17\./ {split($2,a,"/"); print a[1]; exit}')"
  [[ -n "${ip}" ]] && printf '%s\n' "${ip}" && return 0
  # Any RFC-1918 172.16-31 address as last resort
  ip="$(ip -4 addr show 2>/dev/null | awk '/inet 172\.(1[6-9]|2[0-9]|3[01])\./ {split($2,a,"/"); print a[1]; exit}')"
  [[ -n "${ip}" ]] && printf '%s\n' "${ip}" && return 0
  return 1
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
    _rl="$(readlink -f /etc/localtime 2>/dev/null || readlink /etc/localtime)"
    # Only accept the readlink result when it actually points into a zoneinfo dir,
    # otherwise we would assign a garbage TZ like '/etc/localtime' on some hosts.
    case "${_rl}" in
      */zoneinfo/*) HOST_TZ="${_rl##*/zoneinfo/}" ;;
    esac
  fi
  TZ="${TZ:-${HOST_TZ}}"

  # Internal proxy IP — the address prosody's port is bound to so that the
  # nginx reverse proxy (and other containers on the same network) can reach it.
  # Defaults to the host's 172.17.x.x address; override when using a different network.
  INTERNAL_PROXY_IP="${INTERNAL_PROXY_IP:-$(__detect_proxy_ip 2>/dev/null || true)}"
  [[ -z "${INTERNAL_PROXY_IP}" ]] && __warn "Could not detect internal proxy IP — set INTERNAL_PROXY_IP manually."

  # Core server settings
  # Auto-select a free port in 64000-64999 if not already configured.
  HTTP_PORT="${HTTP_PORT:-$(__find_free_port 64000 64999 2>/dev/null || printf '64453')}"
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

  # nginx vhost generation
  NGINX_VHOST_DIR="${NGINX_VHOST_DIR:-/etc/nginx/vhosts.d}"
  NGINX_VHOST_FILE="${NGINX_VHOST_DIR}/${PUBLIC_DOMAIN}.conf"
  WRITE_NGINX_VHOST="${WRITE_NGINX_VHOST:-1}"
  # SSL cert directory — auto-detected by scanning /etc/letsencrypt/live for a
  # cert that covers PUBLIC_DOMAIN (exact, parent wildcard, or SAN match).
  # Falls back to /etc/letsencrypt/live/domain (the literal template placeholder,
  # which is also a real cert directory on this host).
  # Override at any time:
  #   NGINX_SSL_CERT_DIR=/etc/letsencrypt/live/meet.example.com
  NGINX_SSL_CERT_DIR="${NGINX_SSL_CERT_DIR:-$(__find_ssl_cert_dir "${PUBLIC_DOMAIN}" 2>/dev/null || printf '/etc/letsencrypt/live/domain')}"

  # Watermark/branding overlay settings
  SHOW_JITSI_WATERMARK="${SHOW_JITSI_WATERMARK:-false}"
  JITSI_WATERMARK_LINK="${JITSI_WATERMARK_LINK:-}"
  SHOW_BRAND_WATERMARK="${SHOW_BRAND_WATERMARK:-false}"
  BRAND_WATERMARK_LINK="${BRAND_WATERMARK_LINK:-}"

  # JVB colibri WebSocket — required for reliable audio/video behind a reverse proxy.
  # Prosody's internal nginx routes /colibri-ws/ to JVB:9090 over the Docker network.
  # JVB port 9090 is not exposed; all colibri-WS traffic flows through prosody.
  JVB_WS_DOMAIN="${JVB_WS_DOMAIN:-${PUBLIC_DOMAIN}}"
  JVB_WS_SERVER_ID="${JVB_WS_SERVER_ID:-default-jvb}"
  COLIBRI_WEBSOCKET_PORT="${COLIBRI_WEBSOCKET_PORT:-443}"

  # XMPP WebSocket — required for reliable XMPP signalling behind a reverse proxy
  ENABLE_XMPP_WEBSOCKET="${ENABLE_XMPP_WEBSOCKET:-1}"
}

# Load existing .env file and export variables to environment.
# Strips one layer of surrounding single or double quotes so values written as
# KEY="value with spaces" do not export with literal quote characters.
__load_existing_env() {
  [[ -f "${ENV_FILE}" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "${key}" in \#*|"") continue ;; esac
    # Strip a matching pair of surrounding quotes (single or double)
    case "${value}" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
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
INTERNAL_PROXY_IP=${INTERNAL_PROXY_IP}
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

# nginx vhost generation
# Set WRITE_NGINX_VHOST=0 to skip writing the vhost file
# NGINX_SSL_CERT_DIR defaults to /etc/letsencrypt/live/domain (literal 'domain' —
# matches the nginx template placeholder). Override when the cert is elsewhere, e.g.:
#   NGINX_SSL_CERT_DIR=/etc/letsencrypt/live/meet.example.com
#   NGINX_SSL_CERT_DIR=/etc/letsencrypt/live/example.com
NGINX_VHOST_DIR=${NGINX_VHOST_DIR}
WRITE_NGINX_VHOST=${WRITE_NGINX_VHOST}
NGINX_SSL_CERT_DIR=${NGINX_SSL_CERT_DIR}
EOF
}

__ensure_all_env_keys() {
  __ensure_env_key JITSI_DATA_DIR "${JITSI_DATA_DIR}"
  __ensure_env_key JITSI_CONFIG_DIR "${JITSI_CONFIG_DIR}"
  __ensure_env_key HTTP_PORT "${HTTP_PORT}"
  __ensure_env_key PUBLIC_URL "${PUBLIC_URL}"
  __ensure_env_key PUBLIC_DOMAIN "${PUBLIC_DOMAIN}"
  __ensure_env_key TZ "${TZ}"
  __ensure_env_key ENABLE_AUTH "${ENABLE_AUTH}"
  __ensure_env_key JICOFO_AUTH_PASSWORD "${JICOFO_AUTH_PASSWORD}"
  __ensure_env_key JVB_AUTH_PASSWORD "${JVB_AUTH_PASSWORD}"
  __ensure_env_key JIBRI_RECORDER_PASSWORD ""
  __ensure_env_key JIBRI_XMPP_PASSWORD ""
  __ensure_env_key INTERNAL_PROXY_IP "${INTERNAL_PROXY_IP}"
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
  __ensure_env_key NGINX_VHOST_DIR "${NGINX_VHOST_DIR}"
  __ensure_env_key WRITE_NGINX_VHOST "${WRITE_NGINX_VHOST}"
  __ensure_env_key NGINX_SSL_CERT_DIR "${NGINX_SSL_CERT_DIR}"
}

__fill_missing_secrets() {
  # shellcheck source=/dev/null
  . "${ENV_FILE}"
  local changed=0

  # Set a key in ENV_FILE to a value: replace in place if present, otherwise append.
  # Portable across GNU/BSD sed (BSD requires a backup extension).
  __set_env_key() {
    local key="$1" val="$2"
    if grep -qE -- "^${key}=" "${ENV_FILE}" 2>/dev/null; then
      # Escape replacement for sed: backslash, ampersand, and the delimiter (|)
      local _esc="${val//\\/\\\\}"
      _esc="${_esc//&/\\&}"
      _esc="${_esc//|/\\|}"
      sed -i.bak "s|^${key}=.*|${key}=${_esc}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
    else
      printf '%s=%s\n' "${key}" "${val}" >> "${ENV_FILE}"
    fi
  }

  if [[ -z "${JICOFO_AUTH_PASSWORD:-}" ]]; then
    __set_env_key JICOFO_AUTH_PASSWORD "$(__randpass)"
    changed=1
  fi
  if [[ -z "${JVB_AUTH_PASSWORD:-}" ]]; then
    __set_env_key JVB_AUTH_PASSWORD "$(__randpass)"
    changed=1
  fi

  if [[ "${ENABLE_JIBRI:-0}" == "1" ]]; then
    if [[ -z "${JIBRI_RECORDER_PASSWORD:-}" ]]; then
      __set_env_key JIBRI_RECORDER_PASSWORD "$(__randpass)"
      changed=1
    fi
    if [[ -z "${JIBRI_XMPP_PASSWORD:-}" ]]; then
      __set_env_key JIBRI_XMPP_PASSWORD "$(__randpass)"
      changed=1
    fi
  fi

  if [[ -z "${ADMIN_PASS:-}" ]]; then
    if [[ -f "${CREDS_FILE}" ]] && grep -q -- "^ADMIN_USER=${ADMIN_USER}@" "${CREDS_FILE}"; then
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
      # Prosody's internal web server (reverse proxy) entry point.
      # Bound to INTERNAL_PROXY_IP:HTTP_PORT so the nginx frontend proxy and
      # other containers on the same network can reach it; not 127.0.0.1 which
      # would be invisible to containers even on the host network.
      # prosody routes web, BOSH, XMPP-WS, and colibri-WS internally.
      - "${INTERNAL_PROXY_IP}:${HTTP_PORT}:80"
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
  # Skip when auth is disabled: prosody has no internal_hashed store configured
  # and the register call would fail noisily without serving any purpose.
  if [[ "${ENABLE_AUTH:-0}" != "1" ]]; then
    __info "ENABLE_AUTH=0 — skipping admin user registration."
    return 0
  fi
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
ADMIN_USER=${ADMIN_USER}@${PUBLIC_DOMAIN}
ADMIN_PASS=${ADMIN_PASS}
UPDATED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF
  __info "Credentials saved: ${CREDS_FILE}"
}

__write_nginx_vhost() {
  [[ "${WRITE_NGINX_VHOST}" == "1" ]] || return 0
  __need_cmd nginx || return 0

  local _template="/usr/local/share/CasjaysDev/scripts/templates/nginx/reverseproxy.conf"
  local _sentinel="# nginx configuration for ${PUBLIC_DOMAIN}"
  local _first_line=""

  # Skip when the file already carries our sentinel on line 1
  if [[ -f "${NGINX_VHOST_FILE}" ]]; then
    read -r _first_line < "${NGINX_VHOST_FILE}" 2>/dev/null || true
    [[ "${_first_line}" == "${_sentinel}" ]] && return 0
  fi

  mkdir -p "${NGINX_VHOST_DIR}"
  __backup_file "${NGINX_VHOST_FILE}"

  if [[ -f "${_template}" ]]; then
    sed \
      -e "s|GEN_NGINX_REPLACE_DOMAIN|${PUBLIC_DOMAIN}|g" \
      -e "s|REPLACE_NGINX_HOST|${PUBLIC_DOMAIN}|g" \
      -e "s| REPLACE_NGINX_VHOSTS||g" \
      -e "s|REPLACE_NGINX_PORT|443|g" \
      -e "s|REPLACE_SERVER_LISTEN_OPTS|ssl|g" \
      -e "s|REPLACE_HOST_PROXY|http://${INTERNAL_PROXY_IP}:${HTTP_PORT}|g" \
      -e "s|/etc/letsencrypt/live/domain/|${NGINX_SSL_CERT_DIR}/|g" \
      -e 's|\$connection_upgrade|"upgrade"|g' \
      "${_template}" > "${NGINX_VHOST_FILE}"
  else
    # Fallback when template is absent
    cat > "${NGINX_VHOST_FILE}" <<NGINX
${_sentinel}
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name ${PUBLIC_DOMAIN} *.${PUBLIC_DOMAIN};
  ssl_certificate                 ${NGINX_SSL_CERT_DIR}/fullchain.pem;
  ssl_certificate_key             ${NGINX_SSL_CERT_DIR}/privkey.pem;
  ssl_protocols                   TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers       off;
  add_header                      Strict-Transport-Security "max-age=7200";
  client_max_body_size            0;

  location / {
    proxy_http_version            1.1;
    proxy_pass                    http://${INTERNAL_PROXY_IP}:${HTTP_PORT};
    proxy_buffering               off;
    proxy_request_buffering       off;
    proxy_set_header              Host              \$host;
    proxy_set_header              X-Real-IP         \$remote_addr;
    proxy_set_header              X-Forwarded-Proto https;
    proxy_set_header              X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header              Upgrade           \$http_upgrade;
    proxy_set_header              Connection        "upgrade";
    proxy_read_timeout            3600;
    proxy_send_timeout            3600;
  }
}
NGINX
  fi

  if [[ "${ENABLE_SUBDOMAIN_ROOMS}" == "1" ]]; then
    local _domain_escaped="${PUBLIC_DOMAIN//./\\.}"
    cat >> "${NGINX_VHOST_FILE}" <<NGINX

# nginx configuration for *.${PUBLIC_DOMAIN} (wildcard conference rooms)
# <room>.${PUBLIC_DOMAIN}/ → same-domain 302 → <room>.${PUBLIC_DOMAIN}/<room> → proxy
# Requires a *.${PUBLIC_DOMAIN} wildcard SSL cert. Regex server_name takes priority
# over the wildcard in the main block, so each subdomain is handled here first.
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  server_name ~^(?P<room>[^.]+)\\.${_domain_escaped}\$;
  ssl_certificate                 ${NGINX_SSL_CERT_DIR}/fullchain.pem;
  ssl_certificate_key             ${NGINX_SSL_CERT_DIR}/privkey.pem;
  ssl_protocols                   TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers       off;
  client_max_body_size            0;

  location = / {
    return 302 /\$room;
  }

  location / {
    proxy_http_version            1.1;
    proxy_pass                    http://${INTERNAL_PROXY_IP}:${HTTP_PORT};
    proxy_buffering               off;
    proxy_request_buffering       off;
    proxy_set_header              Host              ${PUBLIC_DOMAIN};
    proxy_set_header              X-Real-IP         \$remote_addr;
    proxy_set_header              X-Forwarded-Proto https;
    proxy_set_header              X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header              Upgrade           \$http_upgrade;
    proxy_set_header              Connection        "upgrade";
    proxy_read_timeout            3600;
    proxy_send_timeout            3600;
  }
}
NGINX
  fi

  if ! grep -rq -- 'vhosts\.d' /etc/nginx/ 2>/dev/null; then
    local _include_file="/etc/nginx/conf.d/jitsi-vhosts.conf"
    printf 'include %s/*.conf;\n' "${NGINX_VHOST_DIR}" > "${_include_file}"
    __warn "Added: include ${NGINX_VHOST_DIR}/*.conf; → ${_include_file}"
    __warn "Verify this does not conflict with your existing nginx includes."
  fi

  local _test_out
  if _test_out="$(nginx -t 2>&1)"; then
    systemctl reload nginx 2>/dev/null || nginx -s reload 2>/dev/null || true
  else
    __warn "nginx config test failed — check ${NGINX_VHOST_FILE}"
    __warn "${_test_out}"
  fi
}

__post_summary() {
  # shellcheck source=/dev/null
  . "${ENV_FILE}"

  cat <<EOF

============================================================
Jitsi Meet Installation Complete
============================================================
Public URL:      ${PUBLIC_URL}
Auth Enabled:    ${ENABLE_AUTH} (0=open, 1=required)
Admin User:      ${ADMIN_USER}@${PUBLIC_DOMAIN}
Credentials:     ${CREDS_FILE}
Jibri:           ${ENABLE_JIBRI:-0}
Subdomain Rooms: ${ENABLE_SUBDOMAIN_ROOMS} (*.${PUBLIC_DOMAIN} -> room redirect)
NGINX_VHOST_DIR: ${NGINX_VHOST_DIR}
------------------------------------------------------------
Operational scripts installed to: /usr/local/bin
  meet-admin   — manage users, rooms, tokens, config, and logs
  jitsi-stack  — start/stop/restart/status/logs/update/backup
------------------------------------------------------------

NGINX VHOST
===========
$(if __need_cmd nginx; then printf 'Written to: %s\n' "${NGINX_VHOST_FILE}"; printf 'See docs/reverse.md for Apache, Caddy, HAProxy, and Traefik examples.\n'; else printf 'nginx not found on this host — see docs/reverse.md for all proxy examples.\n'; printf 'When ready: set NGINX_VHOST_DIR and re-run install.sh, or copy from docs/.\n'; fi)

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
  APP_NAME                Application name (default: 'CasjaysDev Meet')
  PROVIDER_NAME           Provider name (default: CasjaysDev)
  ENABLE_JIBRI            Enable recording (default: 0)
  ENABLE_SUBDOMAIN_ROOMS  1=redirect <room>.domain -> domain/<room> (default: 1)
                          Requires a wildcard SSL cert on the frontend proxy.
  DOCKER_HOST_ADDRESS     Public IP for JVB ICE (auto-detected if not set)
  GITHUB_RAW_REPO         GitHub repo for scripts (default: scriptmgr/jitsi)
  JITSI_BASE_DIR          Installation directory (default: /opt/jitsi)
  JITSI_TAG               Jitsi Docker image tag (default: unstable)
  TZ                      Timezone (default: auto-detected from host)
  HTTP_PORT               Internal port for prosody (default: random 64000-64999)
  INTERNAL_PROXY_IP       Bind IP for internal HTTP_PORT (default: docker0 addr)
  NGINX_VHOST_DIR         nginx vhost directory (default: /etc/nginx/vhosts.d)
  NGINX_SSL_CERT_DIR      Letsencrypt cert dir (default: auto-detect for PUBLIC_DOMAIN)
  WRITE_NGINX_VHOST       1=write nginx vhost file, 0=skip (default: 1)
  SMTP_SERVER             SMTP relay host (default: host.docker.internal)
  SMTP_PORT               SMTP port (default: 25)
  SMTP_FROM               From address (default: no-reply@PUBLIC_DOMAIN)
  IP4_ADDRESS             Override detected public IPv4
  INSTALL_DEBUG           1=enable set -x trace (same as --debug)
  NO_COLOR                Disable colored output (same as --no-color)

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
  # Safety: never run rm -rf on a short/blank/root-ish path.
  # JITSI_BASE_DIR must be a real, absolute path at least 5 chars long
  # and not equal to '/' or any top-level system directory.
  case "${JITSI_BASE_DIR:-}" in
    ""|"/"|"/."|"/.."|"/root"|"/home"|"/etc"|"/usr"|"/var"|"/opt"|"/bin"|"/sbin"|"/lib"|"/lib64"|"/boot"|"/dev"|"/proc"|"/sys"|"/run"|"/srv"|"/tmp")
      __die "Refusing to remove unsafe JITSI_BASE_DIR='${JITSI_BASE_DIR:-}'"
      ;;
  esac
  [[ "${JITSI_BASE_DIR}" = /* ]] || __die "JITSI_BASE_DIR must be an absolute path: '${JITSI_BASE_DIR}'"
  [[ ${#JITSI_BASE_DIR} -ge 5 ]] || __die "JITSI_BASE_DIR is too short to remove safely: '${JITSI_BASE_DIR}'"
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
  __write_nginx_vhost
  if __need_cmd jq; then
    if ! __download_all_scripts_from_github /usr/local/bin; then
      __warn "Failed to download operational scripts from GitHub — re-run install.sh once network access is restored."
    fi
  else
    __warn "jq not found — skipping operational script install. Install jq and re-run to get meet-admin and jitsi-stack."
  fi
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
