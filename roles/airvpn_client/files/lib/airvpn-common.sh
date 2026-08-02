#!/usr/bin/env bash
# Shared helpers for airvpn-client runtime commands.
# shellcheck shell=bash
# This file is sourced; it must not execute main logic on its own.

# Guard against double-sourcing
if [[ -n "${AIRVPN_COMMON_LOADED:-}" ]]; then
  return 0
fi
AIRVPN_COMMON_LOADED=1

# Defaults (overridden by /etc/airvpn-client/airvpn-client.conf when present)
: "${AIRVPN_CONFIG_DIR:=/etc/airvpn-client}"
: "${AIRVPN_MANAGED_CONFIG_DIR:=/etc/airvpn-client/configs}"
: "${AIRVPN_INSTALL_DIR:=/usr/local/libexec/airvpn-client}"
: "${AIRVPN_BIN_DIR:=/usr/local/bin}"
: "${AIRVPN_CONNECTION_PREFIX:=AirVPN - }"
: "${AIRVPN_ZONE:=airvpn}"
: "${AIRVPN_UNDERLAY_ZONE:=vpn-underlay}"
: "${AIRVPN_POLICY_TO_VPN:=airvpn-host-to-vpn}"
: "${AIRVPN_POLICY_TO_UNDERLAY:=airvpn-host-to-underlay}"
: "${AIRVPN_DNS_PRIORITY:=-100}"
: "${AIRVPN_ENABLE_IPV6:=true}"
: "${AIRVPN_RESTORE_ZONE:=public}"
: "${AIRVPN_LOCK_FILE:=/run/airvpn-client.lock}"
: "${AIRVPN_STATE_DIR:=/var/lib/airvpn-client}"

airvpn_load_config() {
  local conf="${AIRVPN_CONFIG_DIR}/airvpn-client.conf"
  if [[ -f "${conf}" ]]; then
    # shellcheck disable=SC1090
    source "${conf}"
  fi
}

airvpn_log() {
  local level="$1"
  shift
  printf '%s\n' "[airvpn-client] ${level}: $*" >&2
}

airvpn_die() {
  airvpn_log "ERROR" "$*"
  exit 1
}

airvpn_require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    airvpn_die "This command must be run as root (try: sudo $0)"
  fi
}

airvpn_require_cmds() {
  local missing=()
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done
  if ((${#missing[@]} > 0)); then
    airvpn_die "Missing required command(s): ${missing[*]}"
  fi
}

# Redact lines that may contain private key material before printing.
airvpn_redact() {
  sed -E \
    -e 's/(PrivateKey[[:space:]]*=[[:space:]]*).*/\1<redacted>/Ig' \
    -e 's/(PresharedKey[[:space:]]*=[[:space:]]*).*/\1<redacted>/Ig'
}

# Acquire an exclusive lock for mutating operations.
# Usage: airvpn_with_lock <lock_name> <command> [args...]
airvpn_with_lock() {
  local lock_name="$1"
  shift
  local lock_path="${AIRVPN_LOCK_FILE}.${lock_name}"
  mkdir -p "$(dirname "${lock_path}")"
  exec 9>"${lock_path}"
  if ! flock -n 9; then
    airvpn_die "Another airvpn-client operation holds the '${lock_name}' lock (${lock_path})"
  fi
  "$@"
}

# ---------------------------------------------------------------------------
# Endpoint parsing
# Accepts: 192.0.2.10:1637  or  [2001:db8::10]:1637
# Rejects: hostnames, bare IPv6 without brackets, malformed values
# Sets: AIRVPN_PARSE_IP AIRVPN_PARSE_PORT AIRVPN_PARSE_FAMILY
# ---------------------------------------------------------------------------
airvpn_parse_endpoint() {
  local endpoint="${1:-}"
  AIRVPN_PARSE_IP=""
  AIRVPN_PARSE_PORT=""
  AIRVPN_PARSE_FAMILY=""

  if [[ -z "${endpoint}" ]]; then
    return 1
  fi

  # Bracketed IPv6: [addr]:port
  if [[ "${endpoint}" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]{1,5})$ ]]; then
    AIRVPN_PARSE_IP="${BASH_REMATCH[1]}"
    AIRVPN_PARSE_PORT="${BASH_REMATCH[2]}"
    AIRVPN_PARSE_FAMILY="ipv6"
    if ! airvpn_valid_ipv6 "${AIRVPN_PARSE_IP}"; then
      return 1
    fi
    if ! airvpn_valid_port "${AIRVPN_PARSE_PORT}"; then
      return 1
    fi
    return 0
  fi

  # IPv4: a.b.c.d:port  (reject hostnames by requiring dotted-quad only)
  if [[ "${endpoint}" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}):([0-9]{1,5})$ ]]; then
    AIRVPN_PARSE_IP="${BASH_REMATCH[1]}"
    AIRVPN_PARSE_PORT="${BASH_REMATCH[2]}"
    AIRVPN_PARSE_FAMILY="ipv4"
    if ! airvpn_valid_ipv4 "${AIRVPN_PARSE_IP}"; then
      return 1
    fi
    if ! airvpn_valid_port "${AIRVPN_PARSE_PORT}"; then
      return 1
    fi
    return 0
  fi

  # Hostname or unsupported form
  return 2
}

airvpn_valid_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

airvpn_valid_ipv4() {
  local ip="$1"
  local IFS=.
  # shellcheck disable=SC2206
  local octets=(${ip})
  ((${#octets[@]} == 4)) || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "${o}" =~ ^[0-9]+$ ]] || return 1
    ((o >= 0 && o <= 255)) || return 1
  done
  return 0
}

# Conservative IPv6 validation (syntax only; rejects empty and clearly invalid).
airvpn_valid_ipv6() {
  local ip="$1"
  [[ -n "${ip}" ]] || return 1
  # Must contain at least one colon and only hex/colon characters
  [[ "${ip}" == *:* ]] || return 1
  [[ "${ip}" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  # Reject more than one '::'
  local compressed="${ip//::/%}"
  if [[ "${compressed}" == *%*%* ]]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Deterministic WireGuard interface name (Linux IFNAMSIZ-1 = 15 chars)
# Format: avpn + 11 hex chars from sha256(public_key|endpoint)
# ---------------------------------------------------------------------------
airvpn_iface_name() {
  local public_key="$1"
  local endpoint="$2"
  local digest
  digest="$(printf '%s|%s' "${public_key}" "${endpoint}" | sha256sum | awk '{print $1}')"
  printf 'avpn%s' "${digest:0:11}"
}

# Extract a WireGuard field value from a conf file without printing secrets.
# Usage: airvpn_wg_field <file> <FieldName>
airvpn_wg_field() {
  local file="$1"
  local field="$2"
  # Match Field = value (case-insensitive field name)
  local line
  line="$(grep -E -i "^[[:space:]]*${field}[[:space:]]*=" "${file}" | head -n1 || true)"
  if [[ -z "${line}" ]]; then
    return 1
  fi
  # Strip key and optional quotes/spaces
  line="${line#*=}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  line="${line#\"}"
  line="${line%\"}"
  printf '%s' "${line}"
}

# List managed NetworkManager connection UUIDs (name starts with prefix).
# Prints: uuid|name|type|device|state  using machine-readable nmcli fields.
airvpn_list_managed_connections() {
  local prefix="${AIRVPN_CONNECTION_PREFIX}"
  local uuid name ctype device state
  while IFS=: read -r uuid name ctype device state; do
    [[ -n "${uuid}" ]] || continue
    if [[ "${name}" == "${prefix}"* ]]; then
      printf '%s|%s|%s|%s|%s\n' "${uuid}" "${name}" "${ctype}" "${device}" "${state}"
    fi
  done < <(nmcli -t -f UUID,NAME,TYPE,DEVICE,STATE connection show 2>/dev/null || true)
}

airvpn_list_active_managed() {
  local uuid name ctype device state
  while IFS='|' read -r uuid name ctype device state; do
    if [[ "${state}" == "activated" || "${state}" == "activating" ]]; then
      printf '%s|%s|%s|%s|%s\n' "${uuid}" "${name}" "${ctype}" "${device}" "${state}"
    fi
  done < <(airvpn_list_managed_connections)
}

airvpn_count_active_managed() {
  local count=0
  local _uuid _name _ctype _device _state
  while IFS='|' read -r _uuid _name _ctype _device _state; do
    [[ -n "${_uuid}" ]] || continue
    count=$((count + 1))
  done < <(airvpn_list_active_managed)
  printf '%s' "${count}"
}

# Wait until a connection UUID is fully inactive.
airvpn_wait_inactive() {
  local uuid="$1"
  local timeout="${2:-30}"
  local i state
  for ((i = 0; i < timeout; i++)); do
    state="$(nmcli -t -f GENERAL.STATE connection show "${uuid}" 2>/dev/null | cut -d: -f2- || true)"
    # Inactive connections often have empty GENERAL.STATE or report as such via device
    if ! nmcli -t -f UUID,STATE connection show --active 2>/dev/null | grep -q "^${uuid}:"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

airvpn_wait_active() {
  local uuid="$1"
  local timeout="${2:-45}"
  local i
  for ((i = 0; i < timeout; i++)); do
    if nmcli -t -f UUID,STATE connection show --active 2>/dev/null | grep -q "^${uuid}:activated$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Return latest handshake age in seconds for interface, or empty if unavailable.
airvpn_handshake_age_seconds() {
  local iface="$1"
  local latest=0
  local line ts
  while IFS= read -r line; do
    [[ "${line}" == *latest*handshake* ]] || continue
    # wg show dump is preferred when available
    true
  done < <(wg show "${iface}" 2>/dev/null || true)

  # Machine-readable: wg show <iface> latest-handshakes
  while IFS=$'\t' read -r _pubkey ts; do
    [[ -n "${ts}" ]] || continue
    if ((ts > latest)); then
      latest="${ts}"
    fi
  done < <(wg show "${iface}" latest-handshakes 2>/dev/null || true)

  if ((latest <= 0)); then
    return 1
  fi
  local now
  now="$(date +%s)"
  printf '%s' "$((now - latest))"
}

airvpn_wait_handshake() {
  local iface="$1"
  local max_age="${2:-180}"
  local timeout="${3:-45}"
  local i age
  for ((i = 0; i < timeout; i++)); do
    if age="$(airvpn_handshake_age_seconds "${iface}")"; then
      if ((age <= max_age)); then
        return 0
      fi
    fi
    sleep 1
  done
  return 1
}

# Validate source directory permissions (not world-readable).
airvpn_validate_source_dir() {
  local dir="$1"
  [[ -d "${dir}" ]] || airvpn_die "Configuration source directory does not exist: ${dir}"
  [[ -r "${dir}" ]] || airvpn_die "Configuration source directory is not readable: ${dir}"

  local mode
  mode="$(stat -c '%a' "${dir}")"
  # Reject world-readable directories (other read or execute bits)
  if [[ "${mode}" =~ [0-9][0-9][2367] ]]; then
    airvpn_die "Refusing world-readable configuration directory ${dir} (mode ${mode}). chmod 700 recommended."
  fi

  local confs=()
  local f
  while IFS= read -r -d '' f; do
    confs+=("${f}")
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.conf' -print0 | sort -z)

  if ((${#confs[@]} == 0)); then
    airvpn_die "No .conf files found in ${dir}"
  fi

  for f in "${confs[@]}"; do
    mode="$(stat -c '%a' "${f}")"
    if [[ "${mode}" =~ [0-9][0-9][2367] ]]; then
      airvpn_log "WARN" "World-readable config file ${f} (mode ${mode}); chmod 600 recommended."
    fi
    if ! grep -q -E -i '^[[:space:]]*\[Interface\]' "${f}"; then
      airvpn_die "Missing [Interface] section in $(basename "${f}")"
    fi
    if ! grep -q -E -i '^[[:space:]]*\[Peer\]' "${f}"; then
      airvpn_die "Missing [Peer] section in $(basename "${f}")"
    fi
    if ! airvpn_wg_field "${f}" "PrivateKey" >/dev/null; then
      airvpn_die "Missing PrivateKey in $(basename "${f}") (value will never be logged)"
    fi
    if ! airvpn_wg_field "${f}" "Endpoint" >/dev/null; then
      airvpn_die "Missing Endpoint in $(basename "${f}")"
    fi
  done
}

# Build the rich rule text for a WireGuard endpoint exception.
airvpn_endpoint_rich_rule() {
  local family="$1"
  local ip="$2"
  local port="$3"
  printf 'rule family="%s" destination address="%s" port port="%s" protocol="udp" accept' \
    "${family}" "${ip}" "${port}"
}

# Collect unique endpoints from managed config dir. Prints: family|ip|port
airvpn_collect_endpoints_from_dir() {
  local dir="$1"
  local f endpoint rc
  declare -A seen=()
  while IFS= read -r -d '' f; do
    endpoint="$(airvpn_wg_field "${f}" "Endpoint" || true)"
    [[ -n "${endpoint}" ]] || continue
    airvpn_parse_endpoint "${endpoint}"
    rc=$?
    if ((rc == 2)); then
      airvpn_die "Hostname-based Endpoint not supported in version 1 (file $(basename "${f}")): use numeric IP endpoints from AirVPN"
    fi
    if ((rc != 0)); then
      airvpn_die "Malformed Endpoint in $(basename "${f}")"
    fi
    local key="${AIRVPN_PARSE_FAMILY}|${AIRVPN_PARSE_IP}|${AIRVPN_PARSE_PORT}"
    if [[ -z "${seen[${key}]+x}" ]]; then
      seen["${key}"]=1
      printf '%s\n' "${key}"
    fi
  done < <(find "${dir}" -maxdepth 1 -type f -name '*.conf' -print0 | sort -z)
}

airvpn_firewall_check_config() {
  if ! firewall-cmd --check-config >/dev/null; then
    airvpn_die "firewall-cmd --check-config failed; refusing to reload"
  fi
}

airvpn_is_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}
