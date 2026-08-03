#!/usr/bin/env bash
# Unit tests for project-owned firewall rich-rule validation (no firewalld).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../roles/airvpn_client/files/lib/airvpn-common.sh
source "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILS=$((FAILS + 1))
}

good4="$(airvpn_endpoint_rich_rule ipv4 192.0.2.10 1637)"
good6="$(airvpn_endpoint_rich_rule ipv6 2001:db8::10 1637)"

if airvpn_validate_endpoint_rich_rule "${good4}"; then
  pass "accept generated IPv4 endpoint rich rule"
else
  fail "reject generated IPv4 endpoint rich rule"
fi

if airvpn_validate_endpoint_rich_rule "${good6}"; then
  pass "accept generated IPv6 endpoint rich rule"
else
  fail "reject generated IPv6 endpoint rich rule"
fi

# Admin-looking UDP accept rule that is NOT project-shaped (service-based).
admin='rule family="ipv4" source address="192.0.2.1" port port="53" protocol="udp" accept'
if airvpn_validate_endpoint_rich_rule "${admin}"; then
  fail "should reject non-destination UDP accept rule"
else
  pass "reject non-project UDP accept rule"
fi

# Injection / shell metacharacters must not validate.
evil='rule family="ipv4" destination address="192.0.2.10" port port="1637" protocol="udp" accept; rm -rf /'
if airvpn_validate_endpoint_rich_rule "${evil}"; then
  fail "should reject rule with shell metacharacters"
else
  pass "reject rule with shell metacharacters"
fi

evil2='$(reboot)'
if airvpn_validate_endpoint_rich_rule "${evil2}"; then
  fail "should reject arbitrary string"
else
  pass "reject arbitrary string"
fi

# Whitespace / prefix tampering
if airvpn_validate_endpoint_rich_rule " ${good4}"; then
  fail "should reject leading whitespace"
else
  pass "reject leading whitespace"
fi

# Hostname destination must fail validation via parse
bad_host='rule family="ipv4" destination address="vpn.example.invalid" port port="1637" protocol="udp" accept'
if airvpn_validate_endpoint_rich_rule "${bad_host}"; then
  fail "should reject hostname destination"
else
  pass "reject hostname destination"
fi

# Filter: comments, blanks, invalid lines dropped; valid kept
filtered="$(
  printf '%s\n' \
    '# airvpn-client-endpoint — comment' \
    '' \
    "${good4}" \
    "${admin}" \
    "${evil}" \
    "${good6}" |
    airvpn_filter_owned_endpoint_rules | sort
)"
expected="$(printf '%s\n' "${good4}" "${good6}" | sort)"
if [[ "${filtered}" == "${expected}" ]]; then
  pass "filter keeps only validated owned rules"
else
  fail "filter output mismatch"
fi

# Removal set: owned+present, not desired; unrelated current rules untouched
tmpdir="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${tmpdir}'" EXIT
printf '%s\n' "${good4}" >"${tmpdir}/desired"
printf '%s\n' "${good4}" "${good6}" >"${tmpdir}/owned"
{
  printf '%s\n' "${good4}"
  printf '%s\n' "${good6}"
  printf '%s\n' "${admin}"
} >"${tmpdir}/current"

mapfile -t removals < <(airvpn_owned_rules_to_remove "${tmpdir}/desired" "${tmpdir}/owned" "${tmpdir}/current" | sort)
if [[ "${#removals[@]}" -eq 1 && "${removals[0]}" == "${good6}" ]]; then
  pass "owned removal targets only obsolete project rule"
else
  fail "owned removal set unexpected: ${removals[*]-}"
fi

# Migration: empty owned file still removes project-shaped orphans on the policy
: >"${tmpdir}/owned_empty"
mapfile -t removals2 < <(airvpn_owned_rules_to_remove "${tmpdir}/desired" "${tmpdir}/owned_empty" "${tmpdir}/current" | sort)
if [[ "${#removals2[@]}" -eq 1 && "${removals2[0]}" == "${good6}" ]]; then
  pass "migration empty owned file still removes project-shaped orphans"
else
  fail "migration orphan removal unexpected: ${removals2[*]-}"
fi

# Missing owned file path behaves like empty for candidate seeding from current
mapfile -t removals_missing < <(airvpn_owned_rules_to_remove "${tmpdir}/desired" "${tmpdir}/no-such-owned" "${tmpdir}/current" | sort)
if [[ "${#removals_missing[@]}" -eq 1 && "${removals_missing[0]}" == "${good6}" ]]; then
  pass "missing owned file still removes project-shaped orphans from policy"
else
  fail "missing owned file orphan removal unexpected: ${removals_missing[*]-}"
fi

# Admin non-project rule never scheduled even when owned is empty
if printf '%s\n' "${removals2[@]}" | grep -Fqx "${admin}"; then
  fail "admin non-project rule must not be removal candidate"
else
  pass "admin non-project rule not a removal candidate"
fi

# Corrupted owned entries ignored; live project-shaped orphan still removed
printf '%s\n' 'not-a-rule' "${evil}" "${good6}" >"${tmpdir}/owned_corrupt"
mapfile -t removals3 < <(airvpn_owned_rules_to_remove "${tmpdir}/desired" "${tmpdir}/owned_corrupt" "${tmpdir}/current" | sort)
if [[ "${#removals3[@]}" -eq 1 && "${removals3[0]}" == "${good6}" ]]; then
  pass "corrupt owned lines ignored safely"
else
  fail "corrupt owned handling unexpected: ${removals3[*]-}"
fi

# Owned obsolete rule still present on policy is removed even if also listed only in owned
orphan4="$(airvpn_endpoint_rich_rule ipv4 198.51.100.10 1637)"
printf '%s\n' "${good4}" >"${tmpdir}/desired2"
printf '%s\n' "${orphan4}" >"${tmpdir}/owned2"
{
  printf '%s\n' "${good4}"
  printf '%s\n' "${orphan4}"
  printf '%s\n' "${admin}"
} >"${tmpdir}/current2"
mapfile -t removals4 < <(airvpn_owned_rules_to_remove "${tmpdir}/desired2" "${tmpdir}/owned2" "${tmpdir}/current2" | sort)
if [[ "${#removals4[@]}" -eq 1 && "${removals4[0]}" == "${orphan4}" ]]; then
  pass "owned-only tracking still removes present obsolete rule"
else
  fail "owned-only removal unexpected: ${removals4[*]-}"
fi

# Static check: remove_owned_rule must not ignore firewall-cmd failures
if grep -A20 '^remove_owned_rule()' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync" |
  grep -q 'airvpn_die "Failed to remove'; then
  pass "remove_owned_rule aborts when firewall-cmd remove fails"
else
  fail "remove_owned_rule must die on firewall-cmd remove failure"
fi

if grep -A20 '^add_endpoint_rule()' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync" |
  grep -q 'airvpn_die "Failed to add'; then
  pass "add_endpoint_rule aborts when firewall-cmd add fails"
else
  fail "add_endpoint_rule must die on firewall-cmd add failure"
fi

if grep -n 'Removing obsolete project-owned endpoint rule' -A5 "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync" |
  grep -q 'remove_owned_rule'; then
  pass "removal loop invokes remove_owned_rule before continuing"
else
  fail "removal loop missing remove_owned_rule"
fi

# write_owned_rules after successful mutations must follow reload (not precede it)
reload_line="$(awk '/^sync_main\(\)/{p=1} p && /firewall-cmd --reload/{print NR; exit}' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync")"
write_after_reload_line="$(awk '/^sync_main\(\)/{p=1} p && /firewall-cmd --reload/{r=1} r && /^[[:space:]]*write_owned_rules /{print NR; exit}' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync")"
if [[ -n "${reload_line}" && -n "${write_after_reload_line}" && "${reload_line}" -lt "${write_after_reload_line}" ]]; then
  pass "owned-rules rewritten only after successful reload path"
else
  fail "owned-rules must be written after reload (reload=${reload_line-} write=${write_after_reload_line-})"
fi

if grep -q 'pending-firewalld-reload' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync" &&
  grep -q 'mark_pending_reload' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync" &&
  grep -q 'pending_reload_is_set' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync"; then
  pass "pending firewalld reload marker is implemented"
else
  fail "pending firewalld reload marker missing"
fi

if grep -A15 'if ((changed == 0 && needs_reload == 0))' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync" |
  grep -q 'already in sync'; then
  pass "already-in-sync path requires no pending reload"
else
  fail "already-in-sync path must require needs_reload == 0"
fi

# --- Exact endpoint coverage evaluation (no live firewalld) ---
cov4="$(airvpn_endpoint_rich_rule ipv4 192.0.2.10 1637)"
cov6="$(airvpn_endpoint_rich_rule ipv6 2001:db8::10 1637)"
wrong_port="$(airvpn_endpoint_rich_rule ipv4 192.0.2.10 9999)"
wrong_dest="$(airvpn_endpoint_rich_rule ipv4 198.51.100.1 1637)"
broad='rule protocol="udp" accept'
admin_udp='rule family="ipv4" source address="192.0.2.50" port port="53" protocol="udp" accept'
keys=$'ipv4|192.0.2.10|1637\nipv6|2001:db8::10|1637'

out=""
rc=0
out="$(airvpn_eval_endpoint_rule_coverage "${keys}" "$(printf '%s\n' "${cov4}" "${cov6}")")" || rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"covered=2"* && "${out}" == *"missing=0"* && "${out}" == *"stale=0"* ]] &&
  pass "exact IPv4+IPv6 endpoint match" || fail "exact match out=${out} rc=${rc}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage "${keys}" "$(printf '%s\n' "${cov4}")")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"MISSING ${cov6}"* ]] && pass "missing IPv6 endpoint detected" || fail "missing out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage $'ipv4|192.0.2.10|1637' "$(printf '%s\n' "${wrong_port}")")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"MISSING ${cov4}"* && "${out}" == *"STALE ${wrong_port}"* ]] &&
  pass "wrong port detected as missing+stale" || fail "wrong port out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage $'ipv4|192.0.2.10|1637' "$(printf '%s\n' "${wrong_dest}")")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"MISSING ${cov4}"* && "${out}" == *"STALE ${wrong_dest}"* ]] &&
  pass "wrong destination detected" || fail "wrong dest out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage $'ipv4|192.0.2.10|1637' "$(printf '%s\n' "${broad}" "${admin_udp}")")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"unrelated_udp=2"* && "${out}" == *"missing=1"* && "${out}" != *"STALE ${broad}"* ]] &&
  pass "broad/unrelated UDP rules do not satisfy coverage" || fail "broad out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage $'ipv4|192.0.2.10|1637' "$(printf '%s\n' "${cov4}" "${cov6}")")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"STALE ${cov6}"* ]] && pass "stale project rule detected" || fail "stale out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage $'ipv4|192.0.2.10|1637\nipv4|198.51.100.20|51820' \
  "$(printf '%s\n' "${cov4}" "$(airvpn_endpoint_rich_rule ipv4 198.51.100.20 51820)")")" || rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"covered=2"* ]] && pass "multiple managed endpoints covered" || fail "multi out=${out}"

# Empty expected set: success only when no project-shaped rules remain
rc=0
out="$(airvpn_eval_endpoint_rule_coverage '' '')" || rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"stale=0"* && "${out}" == *"missing=0"* ]] &&
  pass "empty expected and empty rules succeed" || fail "empty/empty out=${out} rc=${rc}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage '' "$(printf '%s\n' "${cov4}")")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"STALE ${cov4}"* && "${out}" == *"stale=1"* ]] &&
  pass "empty expected with stale project rule fails" || fail "empty/stale out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage '' "$(printf '%s\n' "${admin_udp}")")" || rc=$?
[[ "${rc}" -eq 0 && "${out}" == *"unrelated_udp=1"* && "${out}" != *"STALE"* ]] &&
  pass "empty expected ignores unrelated admin UDP" || fail "empty/unrelated out=${out}"

rc=0
out="$(airvpn_eval_endpoint_rule_coverage $'not-a-key\nipv4|bad' "${cov4}")" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == *"INVALID_KEY"* && "${out}" == *"invalid_keys="* ]] &&
  pass "malformed endpoint keys rejected" || fail "invalid keys out=${out}"

# airvpn-check must evaluate coverage even when discovery count is zero
if grep -A40 'check_endpoint_exceptions()' "${ROOT}/roles/airvpn_client/files/airvpn-check" |
  grep -q 'Always evaluate coverage'; then
  pass "airvpn-check evaluates coverage when endpoint set is empty"
else
  fail "airvpn-check empty-endpoint early return still present"
fi
if grep -A25 'failed to collect endpoints' "${ROOT}/roles/airvpn_client/files/airvpn-check" |
  grep -q 'fail "failed to collect endpoints from managed configs"'; then
  pass "airvpn-check fails closed on endpoint discovery failure"
else
  fail "airvpn-check discovery failure path missing"
fi

# --- Runtime device classification (no live nmcli/firewalld) ---
[[ "$(airvpn_classify_runtime_zone_device 'wlp3s0')" == "applicable" ]] &&
  pass "classify valid wifi device" || fail "classify wlp3s0"
[[ "$(airvpn_classify_runtime_zone_device 'lo')" == "skip" ]] &&
  pass "classify lo as skip" || fail "classify lo"
[[ "$(airvpn_classify_runtime_zone_device '--')" == "skip" ]] &&
  pass "classify -- as skip" || fail "classify --"
[[ "$(airvpn_classify_runtime_zone_device '')" == "skip" ]] &&
  pass "classify empty as skip" || fail "classify empty"
[[ "$(airvpn_classify_runtime_zone_device 'wg0')" == "unexpected" ]] &&
  pass "classify wg as unexpected" || fail "classify wg"

rc=0
out="$(airvpn_list_applicable_runtime_devices 'wlp3s0')" || rc=$?
[[ "${rc}" -eq 0 && "${out}" == "wlp3s0" ]] && pass "list one valid device" || fail "list one out=${out}"

rc=0
out="$(airvpn_list_applicable_runtime_devices 'wlp3s0,--,lo')" || rc=$?
[[ "${rc}" -eq 0 && "${out}" == "wlp3s0" ]] &&
  pass "list valid plus skipped placeholders" || fail "list mixed out=${out}"

rc=0
out="$(airvpn_list_applicable_runtime_devices 'lo')" || rc=$?
[[ "${rc}" -eq 0 && -z "${out}" ]] && pass "list only lo yields none" || fail "list lo out=${out}"

rc=0
out="$(airvpn_list_applicable_runtime_devices '--')" || rc=$?
[[ "${rc}" -eq 0 && -z "${out}" ]] && pass "list only -- yields none" || fail "list -- out=${out}"

rc=0
out="$(airvpn_list_applicable_runtime_devices '')" || rc=$?
[[ "${rc}" -eq 0 && -z "${out}" ]] && pass "list empty field yields none" || fail "list empty out=${out}"

rc=0
out="$(airvpn_list_applicable_runtime_devices 'wg0')" || rc=$?
[[ "${rc}" -ne 0 && "${out}" == "wg0" ]] &&
  pass "list unexpected virtual fails" || fail "list wg out=${out} rc=${rc}"

# Mixed physical+virtual: nameref fill must preserve helper failure (mapfile does not).
applicable=()
rc=0
airvpn_fill_applicable_runtime_devices applicable 'wlp3s0,wg0' || rc=$?
[[ "${rc}" -ne 0 && "${applicable[0]}" == "wg0" && "${#applicable[@]}" -eq 1 ]] &&
  pass "fill mixed physical+virtual fails on unexpected" ||
  fail "fill mixed rc=${rc} arr=${applicable[*]}"

applicable=()
rc=0
airvpn_fill_applicable_runtime_devices applicable 'wg0,wlp3s0' || rc=$?
[[ "${rc}" -ne 0 && "${applicable[0]}" == "wg0" ]] &&
  pass "fill unexpected-first still fails" ||
  fail "fill unexpected-first rc=${rc} arr=${applicable[*]}"

applicable=()
rc=0
airvpn_fill_applicable_runtime_devices applicable 'wlp3s0,--,lo' || rc=$?
[[ "${rc}" -eq 0 && "${#applicable[@]}" -eq 1 && "${applicable[0]}" == "wlp3s0" ]] &&
  pass "fill valid plus placeholders" ||
  fail "fill placeholders rc=${rc} arr=${applicable[*]}"

# Guard: mapfile+process-substitution hides helper rc (must not be reintroduced in callers).
mapfile -t applicable < <(airvpn_list_applicable_runtime_devices 'wlp3s0,wg0')
map_rc=$?
if [[ "${map_rc}" -eq 0 && "${applicable[0]}" == "wg0" ]]; then
  pass "mapfile hides helper rc (callers must use airvpn_fill_*)"
else
  fail "mapfile pitfall probe unexpected map_rc=${map_rc} arr=${applicable[*]}"
fi
if ! grep -n 'mapfile -t applicable < <(airvpn_list_applicable_runtime_devices' \
  "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh" \
  "${ROOT}/roles/airvpn_client/files/airvpn-check"; then
  pass "callers no longer use mapfile with list_applicable helper"
else
  fail "mapfile+list_applicable still present in callers"
fi

# Active connection with only skipped devices must fail closed (unit-level contract)
if grep -q 'reason=no-applicable-device' "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh" &&
  grep -q 'has no applicable device for runtime zone check' "${ROOT}/roles/airvpn_client/files/airvpn-check"; then
  pass "active connection requires applicable runtime device"
else
  fail "no-applicable-device fail-closed path missing"
fi
if grep -q "inactive uuid=" "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"; then
  pass "inactive connections are distinct from active runtime checks"
else
  fail "inactive status line missing"
fi

if airvpn_firewall_absence_ok 'Error: INVALID_POLICY: x' &&
  airvpn_firewall_absence_ok 'NOT_ENABLED' &&
  ! airvpn_firewall_absence_ok 'sudo: a password is required'; then
  pass "firewall absence classifier for uninstall delete-policy"
else
  fail "firewall absence classifier"
fi

# airvpn-check documents IPv6 DNS expectations when enabled
if grep -q 'ipv6.dns-priority' "${ROOT}/roles/airvpn_client/files/airvpn-check" &&
  grep -q 'ipv6.method disabled' "${ROOT}/roles/airvpn_client/files/airvpn-check"; then
  pass "airvpn-check covers ipv6 DNS enabled and disabled paths"
else
  fail "airvpn-check ipv6 DNS path coverage missing"
fi

echo
if ((FAILS > 0)); then
  echo "FIREWALL OWNERSHIP TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "FIREWALL OWNERSHIP TESTS OK"
exit 0
