#!/usr/bin/env bash
# Assertion helpers for the VM integration runner (and unit tests).
# shellcheck shell=bash

# Require mutual exclusion among a list of enabled flags (name=0|1 pairs via args).
# Usage: it_assert_mutex_flags flag_a=1 flag_b=0 flag_c=1  -> fails if >1 enabled
it_count_enabled_flags() {
  local count=0
  local item name val
  for item in "$@"; do
    name="${item%%=*}"
    val="${item#*=}"
    if [[ "${val}" == "1" || "${val}" == "true" || "${val}" == "yes" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "${count}"
}

# Validate CLI option combinations for the integration runner.
# Args are environment-like: CONSENT SKIP_SWITCH SKIP_UNINSTALL ALLOW_NON_VM ...
# Prints OK or an error message; returns 0/1.
it_validate_option_combo() {
  local consent="${1:-0}"
  local config_source="${2:-}"
  local config_file="${3:-}"
  local skip_switch="${4:-0}"
  local first_profile="${5:-}"
  local second_profile="${6:-}"

  if ((consent != 1)); then
    printf '%s\n' 'missing explicit consent flag --i-understand-this-modifies-networking'
    return 1
  fi
  if [[ -z "${config_source}" && -z "${config_file}" ]]; then
    printf '%s\n' 'require --config-source DIR or --config-file PATH'
    return 1
  fi
  if [[ -n "${config_source}" && -n "${config_file}" ]]; then
    printf '%s\n' '--config-source and --config-file are mutually exclusive'
    return 1
  fi
  if ((skip_switch == 0)) && [[ -n "${first_profile}" && -n "${second_profile}" ]] &&
    [[ "${first_profile}" == "${second_profile}" ]]; then
    printf '%s\n' '--first-profile and --second-profile must differ when switch testing is enabled'
    return 1
  fi
  printf '%s\n' 'OK'
  return 0
}

# Select first/second profile names from a newline-separated managed list.
# Args: list_text first_hint second_hint [require_second=0|1]
# Prints "first|second" or returns 1.
# When require_second=1, fails unless a distinct second profile is available.
it_select_profiles() {
  local list_text="$1"
  local first_hint="${2:-}"
  local second_hint="${3:-}"
  local require_second="${4:-0}"
  local -a names=()
  local line

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    names+=("${line}")
  done <<<"${list_text}"

  if ((${#names[@]} == 0)); then
    return 1
  fi

  local first="" second=""
  local n

  if [[ -n "${first_hint}" ]]; then
    for n in "${names[@]}"; do
      if [[ "${n}" == "${first_hint}" ]]; then
        first="${n}"
        break
      fi
    done
    [[ -n "${first}" ]] || return 1
  else
    first="${names[0]}"
  fi

  if [[ -n "${second_hint}" ]]; then
    for n in "${names[@]}"; do
      if [[ "${n}" == "${second_hint}" ]]; then
        second="${n}"
        break
      fi
    done
    [[ -n "${second}" ]] || return 1
  else
    for n in "${names[@]}"; do
      if [[ "${n}" != "${first}" ]]; then
        second="${n}"
        break
      fi
    done
  fi

  if [[ "${require_second}" == "1" || "${require_second}" == "true" ]]; then
    [[ -n "${second}" && "${second}" != "${first}" ]] || return 1
  fi

  printf '%s|%s\n' "${first}" "${second:-}"
  return 0
}

# Count active managed VPN profiles from nmcli terse UUID,NAME,TYPE,DEVICE,STATE
# lines using escape-aware splitting (requires airvpn_nmcli_split_terse).
# Args: prefix nmcli_text
it_count_active_managed_from_terse() {
  local prefix="$1"
  local text="$2"
  local count=0
  local line name state

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    airvpn_nmcli_split_terse "${line}"
    ((${#AIRVPN_NM_FIELDS[@]} >= 5)) || continue
    name="${AIRVPN_NM_FIELDS[1]}"
    state="${AIRVPN_NM_FIELDS[4]}"
    [[ "${name}" == "${prefix}"* ]] || continue
    if [[ "${state}" == "activated" || "${state}" == "activating" ]]; then
      count=$((count + 1))
    fi
  done <<<"${text}"
  printf '%s\n' "${count}"
}

# List managed profile names from the same terse nmcli format.
# Args: prefix nmcli_text
it_managed_names_from_terse() {
  local prefix="$1"
  local text="$2"
  local line name

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    airvpn_nmcli_split_terse "${line}"
    ((${#AIRVPN_NM_FIELDS[@]} >= 2)) || continue
    name="${AIRVPN_NM_FIELDS[1]}"
    [[ "${name}" == "${prefix}"* ]] || continue
    printf '%s\n' "${name}"
  done <<<"${text}"
}

# Classify firewall-cmd --info-* results when the object is expected to be absent.
# Args: exit_code output_text
# Prints: present | absent | error
# Non-zero exits that are not clearly "missing object" are error (fail closed),
# so sudo/auth failures are not treated as successful removal.
it_classify_firewall_info_absence() {
  local rc="${1:-1}"
  local out="${2:-}"

  if [[ "${rc}" == "0" ]]; then
    printf 'present\n'
    return 0
  fi
  # Privilege / tool failures must never look like successful removal.
  if grep -qiE \
    'a password is required|^sudo:|Authentication failure|permission denied|command not found' \
    <<<"${out}"; then
    printf 'error\n'
    return 0
  fi
  if grep -qiE \
    'NOT_ENABLED|INVALID_ZONE|INVALID_POLICY|does not exist|not present' \
    <<<"${out}"; then
    printf 'absent\n'
    return 0
  fi
  printf 'error\n'
}
