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
# Empty baseline => unknown (return 2). Same => 1. Different => 0.
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
