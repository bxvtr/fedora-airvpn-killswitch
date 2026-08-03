#!/usr/bin/env bash
# Network probe helpers and switch-observation classification (pure logic).
# shellcheck shell=bash

# Default public-IP lookup URLs (short timeout; tried in order).
IT_DEFAULT_IPV4_URLS=(
  "https://ipv4.icanhazip.com"
  "https://api.ipify.org"
  "https://ifconfig.me/ip"
)

IT_DEFAULT_IPV6_URLS=(
  "https://ipv6.icanhazip.com"
  "https://api64.ipify.org"
)

# Bounded public-IPv4 discovery (overridable in tests).
: "${IT_PUBLIC_IP_MAX_ROUNDS:=3}"
: "${IT_PUBLIC_IP_RETRY_DELAY_SEC:=2}"
: "${IT_PUBLIC_IP_CONNECT_TIMEOUT:=3}"
: "${IT_PUBLIC_IP_MAX_TIME:=5}"

# Results from the last it_lookup_public_ipv4 invocation.
IT_LAST_PUBLIC_IP=""
IT_LAST_PUBLIC_IP_STATUS=""
IT_LAST_PUBLIC_IP_FAILURE_CLASS=""
IT_LAST_PUBLIC_IP_ATTEMPTS=0
IT_LAST_PUBLIC_IP_DIAG=""

# Short stable provider id for artifacts (hostname only).
it_provider_id_from_url() {
  local url="${1:-}"
  local host="${url#*://}"
  host="${host%%/*}"
  printf '%s' "${host:-unknown}"
}

# Trim leading/trailing whitespace only.
it_trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

# Exact single-token IPv4 validation (reuses airvpn_valid_ipv4 when available).
it_is_exact_ipv4() {
  local s
  s="$(it_trim "${1-}")"
  [[ -n "${s}" ]] || return 1
  [[ "${s}" != *[[:space:]]* ]] || return 1
  if declare -F airvpn_valid_ipv4 >/dev/null 2>&1; then
    airvpn_valid_ipv4 "${s}"
    return $?
  fi
  local IFS=.
  # shellcheck disable=SC2206
  local octets=(${s})
  ((${#octets[@]} == 4)) || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "${o}" =~ ^[0-9]+$ ]] || return 1
    ((10#${o} >= 0 && 10#${o} <= 255)) || return 1
  done
  return 0
}

# Map curl exit codes to a stable failure class.
it_classify_curl_exit() {
  local rc="${1:-1}"
  case "${rc}" in
    0) printf 'ok\n' ;;
    6) printf 'dns\n' ;;
    7) printf 'connect\n' ;;
    28) printf 'timeout\n' ;;
    22) printf 'http\n' ;;
    35 | 51 | 53 | 54 | 58 | 59 | 60 | 77 | 82) printf 'tls\n' ;;
    *) printf 'curl_%s\n' "${rc}" ;;
  esac
}

# Evaluate one provider response.
# Args: curl_exit body
# Prints: ok|<ipv4>  OR  fail|<class>
# Does not echo the body.
it_evaluate_public_ipv4_response() {
  local curl_rc="${1:-1}"
  local body="${2-}"
  local trimmed class
  if [[ "${curl_rc}" != "0" ]]; then
    class="$(it_classify_curl_exit "${curl_rc}")"
    printf 'fail|%s\n' "${class}"
    return 1
  fi
  trimmed="$(it_trim "${body}")"
  if [[ -z "${trimmed}" ]]; then
    printf 'fail|empty_body\n'
    return 1
  fi
  if [[ "${trimmed}" == *[[:space:]]* ]]; then
    printf 'fail|invalid_body\n'
    return 1
  fi
  if [[ "${trimmed}" == *'<'* || "${trimmed}" == *'{'* ]]; then
    printf 'fail|invalid_body\n'
    return 1
  fi
  if it_is_exact_ipv4 "${trimmed}"; then
    printf 'ok|%s\n' "${trimmed}"
    return 0
  fi
  if declare -F airvpn_valid_ipv6 >/dev/null 2>&1 && airvpn_valid_ipv6 "${trimmed}"; then
    printf 'fail|invalid_ipv6\n'
    return 1
  fi
  printf 'fail|invalid_ipv4\n'
  return 1
}

# Aggregate attempt failure classes into a phase-level failure class.
# Args: space/newline separated class tokens from failed attempts
it_aggregate_public_ip_failure_class() {
  local tokens="${1-}"
  local t
  local has_dns=0 has_connect=0 has_timeout=0 has_tls=0 has_http=0
  local has_empty=0 has_invalid=0 has_other=0
  for t in ${tokens}; do
    [[ -n "${t}" ]] || continue
    case "${t}" in
      dns) has_dns=1 ;;
      connect) has_connect=1 ;;
      timeout) has_timeout=1 ;;
      tls) has_tls=1 ;;
      http) has_http=1 ;;
      empty_body) has_empty=1 ;;
      invalid_ipv4 | invalid_ipv6 | invalid_body) has_invalid=1 ;;
      *) has_other=1 ;;
    esac
  done
  if ((has_dns && has_connect == 0 && has_timeout == 0 && has_tls == 0 && has_http == 0 && has_invalid == 0 && has_empty == 0)); then
    printf 'dns_unavailable\n'
    return 0
  fi
  if ((has_connect || has_timeout || has_tls)) && ((has_invalid == 0 && has_empty == 0)); then
    if ((has_dns == 0 && has_http == 0 && has_other == 0)); then
      printf 'https_egress_unavailable\n'
      return 0
    fi
  fi
  if ((has_invalid || has_empty)) && ((has_dns == 0 && has_connect == 0 && has_timeout == 0 && has_tls == 0)); then
    printf 'invalid_provider_responses\n'
    return 0
  fi
  printf 'lookup_inconclusive\n'
}

# Perform one HTTP GET of a public-IP URL into body_file. Returns curl exit code.
# Override with IT_MOCK_CURL_IPV4_GET for unit tests (same args/return contract).
it_curl_ipv4_get() {
  local url="$1"
  local body_file="$2"
  if [[ -n "${IT_MOCK_CURL_IPV4_GET:-}" ]]; then
    "${IT_MOCK_CURL_IPV4_GET}" "${url}" "${body_file}"
    return $?
  fi
  curl -4 -fsS \
    --connect-timeout "${IT_PUBLIC_IP_CONNECT_TIMEOUT}" \
    --max-time "${IT_PUBLIC_IP_MAX_TIME}" \
    -o "${body_file}" \
    "${url}"
}

# Human-readable First-VPN failure reason for an empty or leaking public IPv4.
# Args: vpn_ipv4 baseline_ipv4 dns_ok(0|1) https_ok(0|1) failure_class
it_first_vpn_public_ip_failure_message() {
  local vpn_ip="${1-}"
  local baseline="${2-}"
  local dns_ok="${3:-0}"
  local https_ok="${4:-0}"
  local failure_class="${5:-lookup_inconclusive}"

  if [[ -n "${vpn_ip}" && -n "${baseline}" && "${vpn_ip}" == "${baseline}" ]]; then
    printf '%s\n' "VPN public IPv4 matches baseline (possible underlay leak)"
    return 0
  fi
  if [[ -n "${vpn_ip}" ]]; then
    printf '%s\n' "unexpected public IP classification with a valid address"
    return 0
  fi
  if ((dns_ok == 0)); then
    printf '%s\n' "DNS resolution unavailable"
    return 0
  fi
  if ((https_ok == 0)); then
    printf '%s\n' "generic IPv4 HTTPS egress unavailable"
    return 0
  fi
  case "${failure_class}" in
    dns_unavailable)
      printf '%s\n' "DNS resolution unavailable"
      ;;
    https_egress_unavailable)
      printf '%s\n' "generic IPv4 HTTPS egress unavailable"
      ;;
    invalid_provider_responses)
      printf '%s\n' "invalid public-IP provider responses"
      ;;
    *)
      printf '%s\n' "public IPv4 lookup inconclusive after retries"
      ;;
  esac
}

# Look up a public IPv4 via providers with bounded retries.
# On success: prints the IPv4 and returns 0.
# On failure: prints nothing, returns 1, sets IT_LAST_PUBLIC_IP_* diagnostics.
it_lookup_public_ipv4() {
  local rounds="${IT_PUBLIC_IP_MAX_ROUNDS}"
  local delay="${IT_PUBLIC_IP_RETRY_DELAY_SEC}"
  local -a urls=("${IT_DEFAULT_IPV4_URLS[@]}")
  local round url body_file body curl_rc eval_line status value
  local attempt=0
  local -a fail_classes=()
  local diag=""
  local restore_errexit=0

  IT_LAST_PUBLIC_IP=""
  IT_LAST_PUBLIC_IP_STATUS="inconclusive"
  IT_LAST_PUBLIC_IP_FAILURE_CLASS="lookup_inconclusive"
  IT_LAST_PUBLIC_IP_ATTEMPTS=0
  IT_LAST_PUBLIC_IP_DIAG=""

  body_file="$(mktemp)"
  [[ $- == *e* ]] && restore_errexit=1

  for ((round = 1; round <= rounds; round++)); do
    for url in "${urls[@]}"; do
      attempt=$((attempt + 1))
      IT_LAST_PUBLIC_IP_ATTEMPTS="${attempt}"
      : >"${body_file}"
      set +e
      it_curl_ipv4_get "${url}" "${body_file}"
      curl_rc=$?
      ((restore_errexit)) && set -e
      body="$(cat "${body_file}" 2>/dev/null || true)"
      eval_line="$(it_evaluate_public_ipv4_response "${curl_rc}" "${body}")"
      status="${eval_line%%|*}"
      value="${eval_line#*|}"
      if [[ "${status}" == "ok" ]]; then
        IT_LAST_PUBLIC_IP="${value}"
        IT_LAST_PUBLIC_IP_STATUS="success"
        IT_LAST_PUBLIC_IP_FAILURE_CLASS=""
        diag+="attempt=${attempt} provider=$(it_provider_id_from_url "${url}") round=${round} result=ok"$'\n'
        IT_LAST_PUBLIC_IP_DIAG="${diag}"
        rm -f -- "${body_file}"
        printf '%s\n' "${value}"
        return 0
      fi
      fail_classes+=("${value}")
      diag+="attempt=${attempt} provider=$(it_provider_id_from_url "${url}") round=${round} result=fail class=${value} curl_exit=${curl_rc} body_bytes=${#body}"$'\n'
    done
    if ((round < rounds)) && [[ "${delay}" != "0" ]]; then
      sleep "${delay}"
    fi
  done

  IT_LAST_PUBLIC_IP_STATUS="failed"
  IT_LAST_PUBLIC_IP_FAILURE_CLASS="$(it_aggregate_public_ip_failure_class "${fail_classes[*]}")"
  IT_LAST_PUBLIC_IP_DIAG="${diag}"
  rm -f -- "${body_file}"
  return 1
}

# Classify an observed public IPv4 during a server-switch leak test.
# Args: observed_ip baseline_ip first_vpn_ip second_vpn_ip
# Prints one of: first_vpn | second_vpn | baseline_leak | failure | unknown
it_classify_switch_observation() {
  local observed="${1:-}"
  local baseline="${2:-}"
  local first="${3:-}"
  local second="${4:-}"

  if [[ -z "${observed}" || "${observed}" == "timeout" || "${observed}" == "fail" ]]; then
    printf 'failure\n'
    return 0
  fi
  if [[ -n "${baseline}" && "${observed}" == "${baseline}" ]]; then
    printf 'baseline_leak\n'
    return 0
  fi
  if [[ -n "${first}" && "${observed}" == "${first}" ]]; then
    printf 'first_vpn\n'
    return 0
  fi
  if [[ -n "${second}" && "${observed}" == "${second}" ]]; then
    printf 'second_vpn\n'
    return 0
  fi
  printf 'unknown\n'
}

# Return 0 if observed differs from baseline (when baseline known).
# Empty observed => 1. Empty baseline => unknown (return 2). Same => 1. Different => 0.
it_public_ip_differs_from_baseline() {
  local observed="${1:-}"
  local baseline="${2:-}"
  [[ -n "${observed}" ]] || return 1
  if [[ -z "${baseline}" ]]; then
    return 2
  fi
  if [[ "${observed}" == "${baseline}" ]]; then
    return 1
  fi
  return 0
}

# Return 0 if path is strictly outside repo_root.
it_path_outside_repo() {
  local path="${1:-}"
  local repo="${2:-}"
  [[ -n "${path}" && -n "${repo}" && "${path}" == /* && "${repo}" == /* ]] || return 1
  case "${path}" in
    "${repo}" | "${repo}"/*) return 1 ;;
  esac
  return 0
}

# Decide whether virt detection should allow the live test.
# Args: virt_output allow_non_vm container_like(0|1)
# Prints: allow | refuse_non_vm | refuse_container
# virt_output examples: "none", "kvm", "microsoft", "oracle", "vmware", "qemu"
it_virt_decision() {
  local virt="${1:-none}"
  local allow_non_vm="${2:-0}"
  local container_like="${3:-0}"

  if ((container_like)); then
    printf 'refuse_container\n'
    return 0
  fi
  case "${virt}" in
    none | "")
      if ((allow_non_vm)); then
        printf 'allow\n'
      else
        printf 'refuse_non_vm\n'
      fi
      ;;
    *)
      # systemd-detect-virt returns a tech name for VMs; "none" when bare metal.
      printf 'allow\n'
      ;;
  esac
}

# Return 0 if Endpoint value looks like a hostname form (not numeric IP).
# Uses the same rules as airvpn_parse_endpoint when sourced; otherwise a light check.
it_endpoint_looks_like_hostname() {
  local endpoint="${1:-}"
  if declare -F airvpn_parse_endpoint >/dev/null 2>&1; then
    local rc=0
    airvpn_parse_endpoint "${endpoint}" || rc=$?
    [[ "${rc}" -eq 2 ]]
    return $?
  fi
  # Fallback without common.sh: dotted-quad or bracketed IPv6 are numeric.
  if [[ "${endpoint}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$ ]]; then
    return 1
  fi
  if [[ "${endpoint}" =~ ^\[[0-9A-Fa-f:]+\]:[0-9]{1,5}$ ]]; then
    return 1
  fi
  [[ -n "${endpoint}" ]]
}

# Probe-loop cleanup: kill PIDs listed in a file if still running.
# Args: pidfile
it_cleanup_pidfile() {
  local pidfile="${1:-}"
  [[ -n "${pidfile}" && -f "${pidfile}" ]] || return 0
  local pid
  while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
    fi
  done <"${pidfile}"
  rm -f "${pidfile}"
}

# Stop a marker-driven probe loop, then wait briefly for the worker to exit.
# Args: run_marker_file pidfile [grace_seconds]
it_stop_probe_loop() {
  local marker="${1:-}"
  local pidfile="${2:-}"
  local grace="${3:-3}"
  [[ -n "${marker}" ]] && rm -f "${marker}"
  local i
  for ((i = 0; i < grace; i++)); do
    if [[ -n "${pidfile}" && -f "${pidfile}" ]]; then
      local alive=0 pid
      while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        if kill -0 "${pid}" 2>/dev/null; then
          alive=1
          break
        fi
      done <"${pidfile}"
      ((alive == 0)) && break
    else
      break
    fi
    sleep 1
  done
  it_cleanup_pidfile "${pidfile}"
}
