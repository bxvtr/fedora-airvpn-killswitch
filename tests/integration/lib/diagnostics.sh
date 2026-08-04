#!/usr/bin/env bash
# Redaction helpers for integration-test artifacts.
# shellcheck shell=bash

# Redact WireGuard private keys and common secret assignment forms from text.
# Prints redacted text on stdout.
it_redact_text() {
  local text="${1-}"
  # PrivateKey = <base64...>
  text="$(printf '%s' "${text}" | sed -E \
    -e 's/(PrivateKey[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(PresharedKey[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1[REDACTED]/g' \
    -e 's/(password[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi' \
    -e 's/(token[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi' \
    -e 's/(Authorization:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/gi')"
  printf '%s' "${text}"
}

# Return 0 if path looks like a safe artifact directory root (absolute, not repo).
# Args: path repo_root
it_artifact_path_is_safe() {
  local path="${1:-}"
  local repo="${2:-}"
  [[ -n "${path}" && "${path}" == /* ]] || return 1
  [[ "${path}" != "/" ]] || return 1
  case "${path}" in
    /etc | /etc/* | /usr | /usr/* | /boot | /boot/* | /root | /root/*) return 1 ;;
  esac
  if [[ -n "${repo}" ]]; then
    case "${path}" in
      "${repo}" | "${repo}"/*) return 1 ;;
    esac
  fi
  return 0
}
