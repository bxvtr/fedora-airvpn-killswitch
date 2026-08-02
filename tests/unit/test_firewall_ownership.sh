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

# First-run: empty owned file → no removals
: >"${tmpdir}/owned_empty"
mapfile -t removals2 < <(airvpn_owned_rules_to_remove "${tmpdir}/desired" "${tmpdir}/owned_empty" "${tmpdir}/current")
if [[ "${#removals2[@]}" -eq 0 ]]; then
  pass "first-run empty owned file removes nothing"
else
  fail "first-run should remove nothing"
fi

# Corrupted owned entries ignored (not scheduled for firewall-cmd)
printf '%s\n' 'not-a-rule' "${evil}" "${good6}" >"${tmpdir}/owned_corrupt"
mapfile -t removals3 < <(airvpn_owned_rules_to_remove "${tmpdir}/desired" "${tmpdir}/owned_corrupt" "${tmpdir}/current" | sort)
if [[ "${#removals3[@]}" -eq 1 && "${removals3[0]}" == "${good6}" ]]; then
  pass "corrupt owned lines ignored safely"
else
  fail "corrupt owned handling unexpected: ${removals3[*]-}"
fi

echo
if ((FAILS > 0)); then
  echo "FIREWALL OWNERSHIP TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "FIREWALL OWNERSHIP TESTS OK"
exit 0
