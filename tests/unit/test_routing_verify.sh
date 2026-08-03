#!/usr/bin/env bash
# Unit tests for policy-routing-aware effective route verification.
# Does not invoke real ip/nmcli; uses AIRVPN_TEST_ROUTE_GET_OUTPUT fixtures.
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

IFACE="avpn12345678901"
OTHER="wg-admin"
PHYS="enp1s0"

# Structural: online check must not use main-table-only grep assertion.
check_script="${ROOT}/roles/airvpn_client/files/airvpn-check"
if grep -nE 'ip -[46] route show default \| grep' "${check_script}" >/dev/null; then
  fail "airvpn-check still uses main-table-only default route grep"
else
  pass "airvpn-check no longer uses main-table-only default route grep"
fi
if grep -q 'airvpn_effective_route_uses_iface' "${check_script}"; then
  pass "airvpn-check uses effective route helper"
else
  fail "airvpn-check missing effective route helper"
fi

# Parser: main-table style
if airvpn_parse_route_get_dev "192.0.2.1 dev ${IFACE} src 10.128.0.2 uid 0 cache"; then
  [[ "${AIRVPN_ROUTE_GET_DEV}" == "${IFACE}" && -z "${AIRVPN_ROUTE_GET_TABLE}" ]] &&
    pass "parse main-table route get" || fail "parse main-table values"
else
  fail "parse main-table route get rc"
fi

# Parser: dedicated policy table (NetworkManager Improved Rule-based Routing)
if airvpn_parse_route_get_dev "192.0.2.1 dev ${IFACE} table 51820 src 10.128.0.2 uid 0 cache"; then
  [[ "${AIRVPN_ROUTE_GET_DEV}" == "${IFACE}" && "${AIRVPN_ROUTE_GET_TABLE}" == "51820" ]] &&
    pass "parse policy-table route get" || fail "parse policy-table values"
else
  fail "parse policy-table route get rc"
fi

# Parser: multiline / metric / cache noise
sample=$'192.0.2.1 via 10.0.2.2 dev enp1s0 src 10.0.2.15\n    cache'
if airvpn_parse_route_get_dev "${sample}"; then
  [[ "${AIRVPN_ROUTE_GET_DEV}" == "enp1s0" ]] && pass "parse physical route get" || fail "parse physical values"
else
  fail "parse physical route get rc"
fi

# Exact interface match (no substring)
AIRVPN_TEST_ROUTE_GET_OUTPUT="192.0.2.1 dev ${IFACE} table 51820 src 10.128.0.2"
if airvpn_effective_route_uses_iface 4 192.0.2.1 "${IFACE}"; then
  pass "effective route accepts managed iface with policy table"
else
  fail "effective route should accept policy-table WireGuard path"
fi

AIRVPN_TEST_ROUTE_GET_OUTPUT="default via 10.0.2.2 dev ${IFACE} metric 50"
if airvpn_effective_route_uses_iface 4 192.0.2.1 "${IFACE}"; then
  pass "effective route accepts main-table WireGuard-style path"
else
  fail "effective route should accept main-table WireGuard path"
fi

AIRVPN_TEST_ROUTE_GET_OUTPUT="192.0.2.1 via 10.0.2.2 dev ${PHYS} src 10.0.2.15"
if airvpn_effective_route_uses_iface 4 192.0.2.1 "${IFACE}"; then
  fail "effective route must reject physical underlay"
else
  pass "effective route rejects physical underlay"
fi

AIRVPN_TEST_ROUTE_GET_OUTPUT="192.0.2.1 dev ${OTHER} table 51820"
if airvpn_effective_route_uses_iface 4 192.0.2.1 "${IFACE}"; then
  fail "effective route must reject unrelated WireGuard iface"
else
  pass "effective route rejects unrelated WireGuard iface"
fi

# Substring trap: shorter name must not match longer selected iface
AIRVPN_TEST_ROUTE_GET_OUTPUT="192.0.2.1 dev avpn12345678901 table 9"
if airvpn_effective_route_uses_iface 4 192.0.2.1 "avpn1234567890"; then
  fail "substring interface match must fail"
else
  pass "rejects substring interface match"
fi

# Endpoint-only / empty / unreachable
AIRVPN_TEST_ROUTE_GET_OUTPUT=""
if airvpn_effective_route_uses_iface 4 192.0.2.1 "${IFACE}"; then
  fail "empty route get must fail closed"
else
  pass "empty route get fails closed"
fi

AIRVPN_TEST_ROUTE_GET_OUTPUT="RTNETLINK answers: Network is unreachable"
if airvpn_effective_route_uses_iface 4 192.0.2.1 "${IFACE}"; then
  fail "unreachable route get must fail closed"
else
  pass "unreachable route get fails closed"
fi

# IPv6 valid VPN path
AIRVPN_TEST_ROUTE_GET_OUTPUT="2001:db8::1 dev ${IFACE} table 51821 src fd00:db8:a::2 metric 1024"
if airvpn_effective_route_uses_iface 6 2001:db8::1 "${IFACE}"; then
  pass "effective IPv6 route accepts managed iface"
else
  fail "effective IPv6 route should accept managed iface"
fi

AIRVPN_TEST_ROUTE_GET_OUTPUT="2001:db8::1 via fe80::1 dev ${PHYS}"
if airvpn_effective_route_uses_iface 6 2001:db8::1 "${IFACE}"; then
  fail "effective IPv6 must reject physical underlay"
else
  pass "effective IPv6 rejects physical underlay"
fi

# Invalid iface argument
AIRVPN_TEST_ROUTE_GET_OUTPUT="192.0.2.1 dev ${IFACE}"
rc=0
airvpn_effective_route_uses_iface 4 192.0.2.1 "bad iface" || rc=$?
if [[ "${rc}" -eq 2 ]]; then
  pass "rejects invalid interface argument"
else
  fail "invalid interface expected rc=2 got ${rc}"
fi

# Integration runner captures policy-routing diagnostics
runner="${ROOT}/tools/integration-test-vm"
if grep -q 'capture_vpn_routing_diagnostics' "${runner}" &&
  grep -q 'ip -4 route show table all' "${runner}" &&
  grep -q 'ip -4 rule show' "${runner}" &&
  grep -q 'ip -4 route get' "${runner}" &&
  grep -q 'wireguard.ip4-auto-default-route' "${runner}"; then
  pass "integration runner captures policy-routing diagnostics"
else
  fail "integration runner missing policy-routing diagnostics"
fi

# Online-check failure still attempts public IP capture after diagnostics
if grep -A40 'capture_vpn_routing_diagnostics "first-vpn"' "${runner}" |
  grep -q 'lookup_public_ip 4'; then
  pass "first-vpn captures public IP even when preparing online-check outcome"
else
  fail "first-vpn missing post-activation public IP capture path"
fi

unset AIRVPN_TEST_ROUTE_GET_OUTPUT

if ((FAILS > 0)); then
  printf 'ROUTING VERIFY TESTS FAILED: %s\n' "${FAILS}"
  exit 1
fi
printf 'ROUTING VERIFY TESTS OK\n'
exit 0
