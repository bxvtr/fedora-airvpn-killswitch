#!/usr/bin/env bash
# Non-destructive unit tests for the VM integration-test orchestrator logic.
# Does not call live NetworkManager, firewalld, WireGuard, or ansible-playbook install.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${ROOT}/tests/integration/lib"

# shellcheck source=../integration/lib/report.sh
source "${LIB}/report.sh"
# shellcheck source=../integration/lib/diagnostics.sh
source "${LIB}/diagnostics.sh"
# shellcheck source=../integration/lib/network-probes.sh
source "${LIB}/network-probes.sh"
# shellcheck source=../integration/lib/assertions.sh
source "${LIB}/assertions.sh"
# shellcheck source=../../roles/airvpn_client/files/lib/airvpn-common.sh
source "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILS=$((FAILS + 1))
}

# --- consent / option validation ---
msg="$(it_validate_option_combo 0 /tmp/x '' 0 '' '')" && fail "consent should be required" || {
  [[ "${msg}" == *consent* ]] && pass "consent required" || fail "consent message: ${msg}"
}

msg="$(it_validate_option_combo 1 '' '' 0 '' '')" && fail "config required" || {
  [[ "${msg}" == *config* ]] && pass "config required" || fail "config message: ${msg}"
}

msg="$(it_validate_option_combo 1 /tmp/a /tmp/b 0 '' '')" && fail "mutex config paths" || {
  [[ "${msg}" == *"mutually exclusive"* ]] && pass "config-source/file mutex" || fail "mutex message: ${msg}"
}

msg="$(it_validate_option_combo 1 /tmp/a '' 0 'A' 'A')" && fail "same profiles" || {
  [[ "${msg}" == *differ* ]] && pass "first/second profile differ" || fail "profile message: ${msg}"
}

msg="$(it_validate_option_combo 1 /tmp/a '' 0 'A' 'B')" && {
  [[ "${msg}" == "OK" ]] && pass "valid option combo" || fail "expected OK got ${msg}"
} || fail "valid combo rejected"

# --- virt decision ---
[[ "$(it_virt_decision none 0 0)" == "refuse_non_vm" ]] && pass "refuse bare metal" || fail "bare metal"
[[ "$(it_virt_decision kvm 0 0)" == "allow" ]] && pass "allow kvm" || fail "kvm"
[[ "$(it_virt_decision none 1 0)" == "allow" ]] && pass "allow-non-vm override" || fail "allow-non-vm"
[[ "$(it_virt_decision kvm 0 1)" == "refuse_container" ]] && pass "refuse container" || fail "container"

# --- path outside repo ---
it_path_outside_repo "/secure/airvpn" "${ROOT}" && pass "path outside repo" || fail "outside repo"
it_path_outside_repo "${ROOT}/configs" "${ROOT}" && fail "should reject inside repo" || pass "reject path inside repo"

# --- hostname endpoints ---
if it_endpoint_looks_like_hostname "vpn.example.invalid:1637"; then
  pass "hostname endpoint detected"
else
  fail "hostname endpoint not detected"
fi
if it_endpoint_looks_like_hostname "192.0.2.10:1637"; then
  fail "numeric IPv4 misclassified as hostname"
else
  pass "numeric IPv4 not hostname"
fi

# --- profile selection ---
sel="$(it_select_profiles $'AirVPN - One\nAirVPN - Two\n' '' '')"
[[ "${sel}" == "AirVPN - One|AirVPN - Two" ]] && pass "default profile selection" || fail "selection=${sel}"

sel="$(it_select_profiles $'AirVPN - One\nAirVPN - Two\n' 'AirVPN - Two' 'AirVPN - One')"
[[ "${sel}" == "AirVPN - Two|AirVPN - One" ]] && pass "hinted profile selection" || fail "hinted=${sel}"

if it_select_profiles $'AirVPN - One\n' 'missing' ''; then
  fail "should reject missing first hint"
else
  pass "reject missing first hint"
fi

# Single managed profile is OK when second is optional
sel="$(it_select_profiles $'AirVPN - One\n' '' '')"
[[ "${sel}" == "AirVPN - One|" ]] && pass "single profile without require_second" || fail "single optional=${sel}"

if it_select_profiles $'AirVPN - One\n' '' '' 1; then
  fail "require_second should fail with one profile"
else
  pass "require_second rejects single profile"
fi

if it_select_profiles $'Custom - A\nCustom - B\n' '' '' 1 >/dev/null; then
  sel="$(it_select_profiles $'Custom - A\nCustom - B\n' '' '' 1)"
  [[ "${sel}" == "Custom - A|Custom - B" ]] && pass "require_second with two profiles" || fail "require_second two=${sel}"
else
  fail "require_second should succeed with two profiles"
fi

# --- escape-aware active managed counting ---
terse=$'uuid-1:AirVPN - Plain:wireguard::activated\nuuid-2:AirVPN - Name\\:with\\:colons:wireguard:avpn0:activated\nuuid-3:Other VPN:wireguard::activated\nuuid-4:AirVPN - Idle:wireguard::'
[[ "$(it_count_active_managed_from_terse 'AirVPN - ' "${terse}")" == "2" ]] &&
  pass "count active with escaped colons" ||
  fail "active count=$(it_count_active_managed_from_terse 'AirVPN - ' "${terse}")"

names="$(it_managed_names_from_terse 'Custom - ' $'u1:Custom - One:wireguard::\nu2:AirVPN - X:wireguard::\nu3:Custom - Two:wireguard::')"
[[ "${names}" == $'Custom - One\nCustom - Two' ]] && pass "managed names honor custom prefix" || fail "names=${names}"

# firewall info absence classification (uninstall assertions)
[[ "$(it_classify_firewall_info_absence 0 'zone airvpn')" == "present" ]] && pass "firewall present" || fail "present"
[[ "$(it_classify_firewall_info_absence 1 'Error: INVALID_POLICY: ...')" == "absent" ]] && pass "firewall absent INVALID_POLICY" || fail "absent policy"
[[ "$(it_classify_firewall_info_absence 1 'sudo: a password is required')" == "error" ]] && pass "firewall sudo error not absent" || fail "sudo error"
[[ "$(it_classify_firewall_info_absence 127 'command not found')" == "error" ]] && pass "firewall unknown error not absent" || fail "unknown error"

# Marker-driven probe stop
marker="$(mktemp)"
pidfile="$(mktemp)"
touch "${marker}"
(
  while [[ -f "${marker}" ]]; do
    sleep 0.2
  done
) &
echo $! >"${pidfile}"
it_stop_probe_loop "${marker}" "${pidfile}" 5
[[ ! -f "${marker}" && ! -f "${pidfile}" ]] && pass "probe loop stop cleans marker/pids" || fail "probe stop cleanup"

# --- baseline IP comparison ---
rc=0
it_public_ip_differs_from_baseline "203.0.113.10" "198.51.100.1" || rc=$?
[[ "${rc}" -eq 0 ]] && pass "IP differs from baseline" || fail "differs rc=${rc}"
rc=0
it_public_ip_differs_from_baseline "198.51.100.1" "198.51.100.1" || rc=$?
[[ "${rc}" -eq 1 ]] && pass "IP matches baseline" || fail "match rc=${rc}"
rc=0
it_public_ip_differs_from_baseline "203.0.113.10" "" || rc=$?
[[ "${rc}" -eq 2 ]] && pass "unknown baseline" || fail "unknown rc=${rc}"

# --- switch observation classification ---
[[ "$(it_classify_switch_observation fail '1.1.1.1' '2.2.2.2' '3.3.3.3')" == "failure" ]] && pass "class failure" || fail "class failure"
[[ "$(it_classify_switch_observation '1.1.1.1' '1.1.1.1' '2.2.2.2' '3.3.3.3')" == "baseline_leak" ]] && pass "class leak" || fail "class leak"
[[ "$(it_classify_switch_observation '2.2.2.2' '1.1.1.1' '2.2.2.2' '3.3.3.3')" == "first_vpn" ]] && pass "class first" || fail "class first"
[[ "$(it_classify_switch_observation '3.3.3.3' '1.1.1.1' '2.2.2.2' '3.3.3.3')" == "second_vpn" ]] && pass "class second" || fail "class second"

# --- redaction ---
red="$(it_redact_text 'PrivateKey = abcdefghijklmnopqrstuvwxyz0123456789abcd=')"
[[ "${red}" == *'[REDACTED]'* && "${red}" != *abcdefghijklmnopqrstuvwxyz* ]] && pass "redact PrivateKey" || fail "redact=${red}"

# --- artifact path safety ---
it_artifact_path_is_safe "/tmp/fedora-airvpn-live-test-x" "${ROOT}" && pass "safe artifact path" || fail "safe artifact"
it_artifact_path_is_safe "${ROOT}/out" "${ROOT}" && fail "artifact in repo" || pass "reject artifact in repo"
it_artifact_path_is_safe "/etc/passwd" "${ROOT}" && fail "artifact in /etc" || pass "reject /etc artifact"

# --- report summary ---
it_report_reset
it_phase_record PASS "a"
it_phase_record FAIL "b" "x"
it_phase_record SKIP "c"
it_phase_record WARN "d"
sum="$(it_summary_lines)"
[[ "${sum}" == *"PASS: 1"* && "${sum}" == *"FAIL: 1"* && "${sum}" == *"SKIP: 1"* && "${sum}" == *"WARN: 1"* ]] &&
  pass "summary counts" || fail "summary=${sum}"
it_exit_code_from_summary && fail "summary should exit non-zero" || pass "summary exit non-zero on FAIL"

# --- pidfile cleanup ---
pidfile="$(mktemp)"
# Start a short sleep in background
sleep 30 &
echo $! >"${pidfile}"
it_cleanup_pidfile "${pidfile}"
if [[ -f "${pidfile}" ]]; then
  fail "pidfile should be removed"
else
  pass "pidfile cleaned"
fi

# --- entry point exists and documents consent ---
[[ -x "${ROOT}/tools/integration-test-vm" ]] && pass "integration-test-vm executable" || fail "not executable"
if "${ROOT}/tools/integration-test-vm" --help | grep -q 'i-understand-this-modifies-networking'; then
  pass "help documents consent flag"
else
  fail "help missing consent flag"
fi

# Refusal without consent (must not mutate networking — exits before preflight virt checks after parse)
set +e
out="$("${ROOT}/tools/integration-test-vm" --config-source /tmp/x 2>&1)"
rc=$?
set -e
if [[ "${rc}" -ne 0 ]] && grep -q 'i-understand-this-modifies-networking' <<<"${out}"; then
  pass "refuses without consent"
else
  fail "consent refusal rc=${rc} out=${out}"
fi

# Root refusal: simulate by checking script contains the guard (cannot become root here safely)
if grep -q 'Refusing to run as root' "${ROOT}/tools/integration-test-vm"; then
  pass "script refuses root"
else
  fail "missing root refusal"
fi

# --- airvpn-switch non-interactive flags present ---
if grep -q -- '--uuid' "${ROOT}/roles/airvpn_client/files/airvpn-switch" &&
  grep -q -- '--name' "${ROOT}/roles/airvpn_client/files/airvpn-switch" &&
  grep -q -- '--disconnect' "${ROOT}/roles/airvpn_client/files/airvpn-switch"; then
  pass "airvpn-switch has non-interactive flags"
else
  fail "airvpn-switch missing non-interactive flags"
fi

# --- static validation / CI must not invoke live integration test ---
live_invoke=0
for f in "${ROOT}/tools/validate-safe" "${ROOT}/.github/workflows/"*.yml; do
  [[ -f "${f}" ]] || continue
  if grep -E -q '^[[:space:]]*(-[[:space:]]+)?(run:[[:space:]]*)?(\./)?tools/integration-test-vm([[:space:]].*)?$' "${f}"; then
    printf 'FAIL: live invocation pattern in %s\n' "${f}"
    live_invoke=1
  fi
done
if [[ -f "${ROOT}/.pre-commit-config.yaml" ]] &&
  grep -q 'integration-test-vm' "${ROOT}/.pre-commit-config.yaml"; then
  printf 'FAIL: integration-test-vm referenced in pre-commit\n'
  live_invoke=1
fi
if ((live_invoke == 0)); then
  pass "validate-safe/CI/pre-commit do not invoke integration-test-vm"
else
  fail "live integration-test-vm referenced from static/CI entry points"
fi

# uninstall-skip option documented
if grep -q -- '--skip-uninstall' "${ROOT}/tools/integration-test-vm"; then
  pass "skip-uninstall option present"
else
  fail "skip-uninstall missing"
fi

# Live ansible invocations must force system Python (like bootstrap.sh)
if grep -q 'ANSIBLE_PYTHON_INTERPRETER="/usr/bin/python3"' "${ROOT}/tools/integration-test-vm" &&
  grep -q 'ansible_python_interpreter=${ANSIBLE_PYTHON_INTERPRETER}' "${ROOT}/tools/integration-test-vm" &&
  grep -q 'run_ansible_capture' "${ROOT}/tools/integration-test-vm" &&
  grep -q 'sudo_firewall_cmd' "${ROOT}/tools/integration-test-vm" &&
  grep -q 'it_count_active_managed_from_terse' "${ROOT}/tools/integration-test-vm" &&
  grep -q 'AIRVPN_CONNECTION_PREFIX' "${ROOT}/tools/integration-test-vm" &&
  grep -q 'switch-probe.run' "${ROOT}/tools/integration-test-vm" &&
  ! grep -E -q 'awk -F:.*AirVPN' "${ROOT}/tools/integration-test-vm"; then
  pass "integration runner uses sudo firewall, prefix, escape-aware counts, marker probes, system python"
else
  fail "integration runner missing required bugfix patterns"
fi

# Empty second profile must FAIL (not SKIP) when switch testing is enabled
if grep -A5 'phase_switch()' "${ROOT}/tools/integration-test-vm" | grep -q 'SKIP_SWITCH'; then
  if grep -n 'no second profile' "${ROOT}/tools/integration-test-vm" | grep -q SKIP; then
    fail "phase_switch still SKIPs missing second profile"
  else
    pass "phase_switch fails closed without second profile"
  fi
else
  fail "phase_switch structure unexpected"
fi

echo
if ((FAILS > 0)); then
  echo "INTEGRATION ORCHESTRATOR TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "INTEGRATION ORCHESTRATOR TESTS OK"
exit 0
