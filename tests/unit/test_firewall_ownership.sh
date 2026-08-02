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

echo
if ((FAILS > 0)); then
  echo "FIREWALL OWNERSHIP TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "FIREWALL OWNERSHIP TESTS OK"
exit 0
