#!/usr/bin/env bash
# List UUIDs of physical NetworkManager connections eligible for underlay protection.
# Intended for Ansible (avoids Jinja interpreting bash ${#...} in inline shells).
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"
# shellcheck source=./airvpn-common.sh
source "${SCRIPT_DIR}/airvpn-common.sh"

include_wifi=0
include_eth=0
declare -a excludes=()
declare -a includes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wifi) include_wifi=1; shift ;;
    --ethernet) include_eth=1; shift ;;
    --exclude=*)
      excludes+=("${1#--exclude=}")
      shift
      ;;
    --include=*)
      includes+=("${1#--include=}")
      shift
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

is_excluded() {
  local uuid="$1" name="$2" item
  for item in "${excludes[@]+"${excludes[@]}"}"; do
    if [[ "${uuid}" == "${item}" || "${name}" == "${item}" ]]; then
      return 0
    fi
  done
  return 1
}

is_included() {
  local uuid="$1" name="$2" item
  if ((${#includes[@]} == 0)); then
    return 0
  fi
  for item in "${includes[@]}"; do
    if [[ "${uuid}" == "${item}" || "${name}" == "${item}" ]]; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  airvpn_nmcli_split_terse "${line}"
  ((${#AIRVPN_NM_FIELDS[@]} >= 3)) || continue
  uuid="${AIRVPN_NM_FIELDS[0]}"
  name="${AIRVPN_NM_FIELDS[1]}"
  ctype="${AIRVPN_NM_FIELDS[2]}"
  case "${ctype}" in
    802-11-wireless)
      ((include_wifi == 1)) || continue
      ;;
    802-3-ethernet)
      ((include_eth == 1)) || continue
      ;;
    *)
      continue
      ;;
  esac
  if is_excluded "${uuid}" "${name}"; then
    continue
  fi
  if ! is_included "${uuid}" "${name}"; then
    continue
  fi
  printf '%s\n' "${uuid}"
done < <(nmcli -t -f UUID,NAME,TYPE connection show 2>/dev/null || true)
