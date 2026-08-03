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

# Acquire the single project-wide exclusive lock for all mutating operations.
# Nested same-process calls and child processes re-enter safely only when FD 9
# already refers to the lock file and flock succeeds on that inherited OFD
# (import → airvpn-firewall-sync). Environment variables are never trusted to
# skip locking: AIRVPN_LOCK_HELD is ignored if set by a caller.
# Usage: airvpn_with_lock <lock_name> <command> [args...]
# Lock FD: 9 (must stay open across nested exec of project helpers).
airvpn_with_lock() {
  local lock_name="$1"
  shift
  local lock_path="${AIRVPN_LOCK_FILE}"
  local lock_dir lock_realpath fd_target
  lock_dir="$(dirname "${lock_path}")"
  mkdir -p "${lock_dir}"
  # Ensure the lock file exists so readlink -f resolves a stable path.
  : >>"${lock_path}" || true
  chmod 0600 "${lock_path}" 2>/dev/null || true
  lock_realpath="$(readlink -f "${lock_path}")"

  if [[ -e /proc/self/fd/9 ]]; then
    fd_target="$(readlink -f /proc/self/fd/9 2>/dev/null || true)"
    if [[ -n "${fd_target}" && "${fd_target}" == "${lock_realpath}" ]]; then
      # FD 9 already open on our lock file (nested call or inherited OFD).
      if flock -n 9; then
        "$@"
        return
      fi
      airvpn_die "Another airvpn-client mutating operation holds the lock (${lock_path}; while starting '${lock_name}')"
    fi
  fi

  # One lock file for import/switch/firewall/killswitch/protect.
  exec 9>"${lock_path}"
  chmod 0600 "${lock_path}" 2>/dev/null || true
  if ! flock -n 9; then
    airvpn_die "Another airvpn-client mutating operation holds the lock (${lock_path}; while starting '${lock_name}')"
  fi
  "$@"
}

# Split a NetworkManager terse (-t) line on unescaped ':' fields.
# NM escapes ':' as '\:' and '\' as '\\' inside field values.
# Result: AIRVPN_NM_FIELDS array
airvpn_nmcli_split_terse() {
  local line="$1"
  AIRVPN_NM_FIELDS=()
  local field=""
  local i=0
  local len=${#line}
  local c
  while ((i < len)); do
    c="${line:i:1}"
    if [[ "${c}" == '\' ]]; then
      i=$((i + 1))
      if ((i < len)); then
        field+="${line:i:1}"
      fi
    elif [[ "${c}" == ':' ]]; then
      AIRVPN_NM_FIELDS+=("${field}")
      field=""
    else
      field+="${c}"
    fi
    i=$((i + 1))
  done
  AIRVPN_NM_FIELDS+=("${field}")
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
  local line uuid name ctype device state
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    airvpn_nmcli_split_terse "${line}"
    ((${#AIRVPN_NM_FIELDS[@]} >= 5)) || continue
    uuid="${AIRVPN_NM_FIELDS[0]}"
    name="${AIRVPN_NM_FIELDS[1]}"
    ctype="${AIRVPN_NM_FIELDS[2]}"
    device="${AIRVPN_NM_FIELDS[3]}"
    state="${AIRVPN_NM_FIELDS[4]}"
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

# Return 0 if rule text is exactly a project-generated endpoint rich rule.
# Rejects arbitrary strings before they are passed to firewall-cmd.
airvpn_validate_endpoint_rich_rule() {
  local rule="$1"
  local family ip port expected rc
  if [[ ! "${rule}" =~ ^rule\ family=\"(ipv4|ipv6)\"\ destination\ address=\"([^\"]+)\"\ port\ port=\"([0-9]{1,5})\"\ protocol=\"udp\"\ accept$ ]]; then
    return 1
  fi
  family="${BASH_REMATCH[1]}"
  ip="${BASH_REMATCH[2]}"
  port="${BASH_REMATCH[3]}"
  ((10#${port} >= 1 && 10#${port} <= 65535)) || return 1
  expected="$(airvpn_endpoint_rich_rule "${family}" "${ip}" "${port}")"
  [[ "${rule}" == "${expected}" ]] || return 1
  if [[ "${family}" == "ipv4" ]]; then
    airvpn_parse_endpoint "${ip}:${port}"
    rc=$?
  else
    airvpn_parse_endpoint "[${ip}]:${port}"
    rc=$?
  fi
  ((rc == 0))
}

# Filter stdin lines: emit only validated endpoint rich rules (skip comments/blank/invalid).
airvpn_filter_owned_endpoint_rules() {
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    if airvpn_validate_endpoint_rich_rule "${line}"; then
      printf '%s\n' "${line}"
    fi
  done
}

# Compute endpoint rich rules that should be removed from the underlay policy.
# Usage: airvpn_owned_rules_to_remove <desired_file> <owned_file> <current_file>
#
# Candidates are the union of:
#   - validated entries from the owned state file, and
#   - validated project-shaped rules currently present on the policy
#     (covers migration when the state file is missing or incomplete).
# Non-project-shaped UDP rules on the policy are never candidates.
# Emits rules that are candidates, currently present, and no longer desired.
airvpn_owned_rules_to_remove() {
  local desired_file="$1"
  local owned_file="$2"
  local current_file="$3"
  local r
  declare -A want=() have=() candidates=()
  while IFS= read -r r || [[ -n "${r}" ]]; do
    [[ -n "${r}" ]] || continue
    airvpn_validate_endpoint_rich_rule "${r}" || continue
    want["${r}"]=1
  done <"${desired_file}"
  while IFS= read -r r || [[ -n "${r}" ]]; do
    [[ -n "${r}" ]] || continue
    have["${r}"]=1
    if airvpn_validate_endpoint_rich_rule "${r}"; then
      candidates["${r}"]=1
    fi
  done <"${current_file}"
  if [[ -f "${owned_file}" ]]; then
    while IFS= read -r r || [[ -n "${r}" ]]; do
      [[ -n "${r}" ]] || continue
      airvpn_validate_endpoint_rich_rule "${r}" || continue
      candidates["${r}"]=1
    done <"${owned_file}"
  fi
  if ((${#candidates[@]} > 0)); then
    for r in "${!candidates[@]}"; do
      if [[ -z "${want[${r}]+x}" && -n "${have[${r}]+x}" ]]; then
        printf '%s\n' "${r}"
      fi
    done
  fi
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

# Return 0 when a firewall-cmd delete/info failure indicates the object is already gone.
# Args: combined stdout+stderr text
airvpn_firewall_absence_ok() {
  local out="${1:-}"
  grep -qiE 'NOT_ENABLED|INVALID_POLICY|INVALID_ZONE|does not exist|not present' <<<"${out}"
}

# Build expected underlay endpoint rich rules from family|ip|port lines on stdin.
airvpn_rules_from_endpoint_keys() {
  local line family ip port
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r family ip port <<<"${line}"
    [[ -n "${family}" && -n "${ip}" && -n "${port}" ]] || continue
    airvpn_endpoint_rich_rule "${family}" "${ip}" "${port}"
    printf '\n'
  done
}

# Evaluate coverage of expected endpoint keys against listed rich rules.
# Args: expected_keys_text current_rules_text
# Prints summary lines:
#   missing=<n> stale=<n> covered=<n> unrelated_udp=<n> invalid_keys=<n>
#   MISSING <rule>
#   STALE <rule>
#   INVALID_KEY <line>
# Exit 0 iff missing=0, stale=0, and invalid_keys=0.
# Empty expected keys with no project rules succeed; empty expected with
# project-shaped rules fail as stale. Unrelated UDP admin rules are counted
# but never classified as project stale/missing.
airvpn_eval_endpoint_rule_coverage() {
  local expected_keys="$1"
  local current_rules="$2"
  local -A want=()
  local -A have_project=()
  local line rule family ip port missing=0 stale=0 covered=0 unrelated=0 invalid=0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r family ip port <<<"${line}"
    if [[ -z "${family}" || -z "${ip}" || -z "${port}" ]] ||
      [[ "${family}" != "ipv4" && "${family}" != "ipv6" ]] ||
      [[ ! "${port}" =~ ^[0-9]{1,5}$ ]]; then
      invalid=$((invalid + 1))
      printf 'INVALID_KEY %s\n' "${line}"
      continue
    fi
    rule="$(airvpn_endpoint_rich_rule "${family}" "${ip}" "${port}")"
    if ! airvpn_validate_endpoint_rich_rule "${rule}"; then
      invalid=$((invalid + 1))
      printf 'INVALID_KEY %s\n' "${line}"
      continue
    fi
    want["${rule}"]=1
  done <<<"${expected_keys}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -n "${line}" ]] || continue
    if airvpn_validate_endpoint_rich_rule "${line}"; then
      have_project["${line}"]=1
    elif grep -q 'protocol="udp"' <<<"${line}"; then
      unrelated=$((unrelated + 1))
    fi
  done <<<"${current_rules}"

  if ((${#want[@]} > 0)); then
    for rule in "${!want[@]}"; do
      if [[ -n "${have_project[${rule}]+x}" ]]; then
        covered=$((covered + 1))
      else
        missing=$((missing + 1))
        printf 'MISSING %s\n' "${rule}"
      fi
    done
  fi
  if ((${#have_project[@]} > 0)); then
    for rule in "${!have_project[@]}"; do
      if [[ -z "${want[${rule}]+x}" ]]; then
        stale=$((stale + 1))
        printf 'STALE %s\n' "${rule}"
      fi
    done
  fi
  printf 'missing=%s stale=%s covered=%s unrelated_udp=%s invalid_keys=%s\n' \
    "${missing}" "${stale}" "${covered}" "${unrelated}" "${invalid}"
  ((missing == 0 && stale == 0 && invalid == 0))
}

# Classify a NetworkManager device name for runtime firewall zone binding.
# Prints: applicable | skip | unexpected
airvpn_classify_runtime_zone_device() {
  local device="${1:-}"
  if [[ -z "${device}" || "${device}" == "--" || "${device}" == "lo" ]]; then
    printf 'skip\n'
    return 0
  fi
  case "${device}" in
    veth* | docker* | br-* | virbr* | tun* | tap* | wg*)
      printf 'unexpected\n'
      ;;
    *)
      printf 'applicable\n'
      ;;
  esac
}

# Fill a nameref array with applicable device names from a GENERAL.DEVICES field.
# Args: nameref_array_name devices_field
# On unexpected virtual device: array contains that name only; return 1.
# On success: array contains applicable devices (possibly empty); return 0.
# Prefer this over mapfile+process-substitution: mapfile's $? is not the helper rc.
airvpn_fill_applicable_runtime_devices() {
  local -n _airvpn_dev_out="$1"
  local devices_field="${2:-}"
  local devices device kind
  local -a good=()
  _airvpn_dev_out=()
  devices="${devices_field//,/ }"
  for device in ${devices}; do
    kind="$(airvpn_classify_runtime_zone_device "${device}")"
    case "${kind}" in
      skip) continue ;;
      unexpected)
        _airvpn_dev_out=("${device}")
        return 1
        ;;
      applicable)
        good+=("${device}")
        ;;
    esac
  done
  if ((${#good[@]} > 0)); then
    _airvpn_dev_out=("${good[@]}")
  fi
  return 0
}

# Expand a GENERAL.DEVICES field into applicable device names (one per line).
# Args: devices_field (comma- or space-separated)
# On unexpected virtual devices: print that device name and return 1.
# On success: print applicable devices (possibly none) and return 0.
airvpn_list_applicable_runtime_devices() {
  local devices_field="${1:-}"
  local -a devices_out=()
  local rc=0
  airvpn_fill_applicable_runtime_devices devices_out "${devices_field}" || rc=$?
  if ((${#devices_out[@]} > 0)); then
    printf '%s\n' "${devices_out[@]}"
  fi
  return "${rc}"
}

# If connection UUID is active, reapply its device(s) and require the runtime
# firewalld zone to match want_zone. Inactive connections return 0 (profile-only).
# Args: uuid want_zone
# Prints machine-readable status lines on stdout for Ansible capture; logs on stderr.
airvpn_ensure_runtime_zone() {
  local uuid="$1"
  local want_zone="$2"
  local line active=0 devices_field device zone list_rc=0
  local -a applicable=()

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    airvpn_nmcli_split_terse "${line}"
    ((${#AIRVPN_NM_FIELDS[@]} >= 1)) || continue
    if [[ "${AIRVPN_NM_FIELDS[0]}" == "${uuid}" ]]; then
      active=1
      break
    fi
  done < <(nmcli -t -f UUID connection show --active 2>/dev/null || true)

  if ((active == 0)); then
    printf 'inactive uuid=%s\n' "${uuid}"
    return 0
  fi

  devices_field="$(nmcli -g GENERAL.DEVICES connection show "${uuid}" 2>/dev/null || true)"
  if [[ -z "${devices_field}" || "${devices_field}" == "--" ]]; then
    airvpn_log "ERROR" "Active connection ${uuid} has no device; cannot bind firewall zone ${want_zone}"
    printf 'error uuid=%s reason=no-device\n' "${uuid}"
    return 1
  fi

  applicable=()
  set +e
  airvpn_fill_applicable_runtime_devices applicable "${devices_field}"
  list_rc=$?
  set -e
  if ((list_rc != 0)); then
    device="${applicable[0]:-unknown}"
    airvpn_log "ERROR" "Refusing runtime zone apply on unexpected device ${device}"
    printf 'error uuid=%s device=%s reason=unexpected-device\n' "${uuid}" "${device}"
    return 1
  fi
  if ((${#applicable[@]} == 0)); then
    airvpn_log "ERROR" "Active connection ${uuid} has no applicable device for firewall zone ${want_zone}"
    printf 'error uuid=%s reason=no-applicable-device\n' "${uuid}"
    return 1
  fi

  for device in "${applicable[@]}"; do
    if ! nmcli device reapply "${device}"; then
      airvpn_log "ERROR" "nmcli device reapply ${device} failed for ${uuid}"
      printf 'error uuid=%s device=%s reason=reapply-failed\n' "${uuid}" "${device}"
      return 1
    fi
    zone="$(firewall-cmd --get-zone-of-interface="${device}" 2>/dev/null || true)"
    if [[ "${zone}" != "${want_zone}" ]]; then
      airvpn_log "ERROR" "Interface ${device} runtime zone is '${zone:-unset}', expected '${want_zone}'"
      printf 'error uuid=%s device=%s runtime_zone=%s expected=%s\n' \
        "${uuid}" "${device}" "${zone:-unset}" "${want_zone}"
      return 1
    fi
    printf 'applied uuid=%s device=%s zone=%s\n' "${uuid}" "${device}" "${zone}"
  done
  return 0
}
