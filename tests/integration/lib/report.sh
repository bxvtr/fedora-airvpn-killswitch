#!/usr/bin/env bash
# Integration-test report helpers (PASS/FAIL/SKIP/WARN). Sourced by the VM runner
# and by non-destructive unit tests. Does not mutate host networking.
# shellcheck shell=bash

IT_PASS_N=0
IT_FAIL_N=0
IT_SKIP_N=0
IT_WARN_N=0
IT_PHASE_RESULTS=()

it_report_reset() {
  IT_PASS_N=0
  IT_FAIL_N=0
  IT_SKIP_N=0
  IT_WARN_N=0
  IT_PHASE_RESULTS=()
}

it_phase_record() {
  local status="$1"
  local name="$2"
  local detail="${3:-}"
  IT_PHASE_RESULTS+=("${status}|${name}|${detail}")
  case "${status}" in
    PASS) IT_PASS_N=$((IT_PASS_N + 1)) ;;
    FAIL) IT_FAIL_N=$((IT_FAIL_N + 1)) ;;
    SKIP) IT_SKIP_N=$((IT_SKIP_N + 1)) ;;
    WARN) IT_WARN_N=$((IT_WARN_N + 1)) ;;
    *)
      IT_FAIL_N=$((IT_FAIL_N + 1))
      IT_PHASE_RESULTS[-1]="FAIL|${name}|unknown status ${status}"
      ;;
  esac
}

it_summary_lines() {
  local entry status name detail
  printf 'PASS: %s\n' "${IT_PASS_N}"
  printf 'FAIL: %s\n' "${IT_FAIL_N}"
  printf 'SKIP: %s\n' "${IT_SKIP_N}"
  printf 'WARN: %s\n' "${IT_WARN_N}"
  printf '\nPhases:\n'
  for entry in "${IT_PHASE_RESULTS[@]}"; do
    IFS='|' read -r status name detail <<<"${entry}"
    if [[ -n "${detail}" ]]; then
      printf '  %s  %s — %s\n' "${status}" "${name}" "${detail}"
    else
      printf '  %s  %s\n' "${status}" "${name}"
    fi
  done
}

it_exit_code_from_summary() {
  if ((IT_FAIL_N > 0)); then
    return 1
  fi
  return 0
}
