#!/usr/bin/env bash
# Unit tests for endpoint parsing and interface naming (no root, no network mutation).
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

# --- IPv4 endpoint ---
if airvpn_parse_endpoint "192.0.2.10:1637"; then
  [[ "${AIRVPN_PARSE_IP}" == "192.0.2.10" && "${AIRVPN_PARSE_PORT}" == "1637" && "${AIRVPN_PARSE_FAMILY}" == "ipv4" ]] &&
    pass "parse IPv4 endpoint" || fail "parse IPv4 endpoint values"
else
  fail "parse IPv4 endpoint rc"
fi

# --- Bracketed IPv6 endpoint ---
if airvpn_parse_endpoint "[2001:db8::10]:1637"; then
  [[ "${AIRVPN_PARSE_IP}" == "2001:db8::10" && "${AIRVPN_PARSE_PORT}" == "1637" && "${AIRVPN_PARSE_FAMILY}" == "ipv6" ]] &&
    pass "parse bracketed IPv6 endpoint" || fail "parse bracketed IPv6 values"
else
  fail "parse bracketed IPv6 endpoint rc"
fi

# --- Reject unbracketed IPv6 (ambiguous colon split) ---
if airvpn_parse_endpoint "2001:db8::10:1637"; then
  fail "should reject unbracketed IPv6 endpoint"
else
  rc=$?
  [[ "${rc}" -ne 0 ]] && pass "reject unbracketed IPv6" || fail "unexpected rc for unbracketed IPv6"
fi

# --- Reject hostname endpoints ---
rc=0
airvpn_parse_endpoint "vpn.example.invalid:1637" || rc=$?
if [[ "${rc}" -eq 2 ]]; then
  pass "reject hostname endpoint (rc=2)"
else
  fail "hostname endpoint expected rc=2 got ${rc}"
fi

# --- Reject malformed ---
if airvpn_parse_endpoint "192.0.2.10"; then
  fail "should reject missing port"
else
  pass "reject missing port"
fi

if airvpn_parse_endpoint "192.0.2.10:99999"; then
  fail "should reject invalid port"
else
  pass "reject invalid port"
fi

if airvpn_parse_endpoint "300.1.1.1:1637"; then
  fail "should reject invalid IPv4 octet"
else
  pass "reject invalid IPv4 octet"
fi

# --- Deterministic interface naming ---
n1="$(airvpn_iface_name "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE=" "192.0.2.10:1637")"
n2="$(airvpn_iface_name "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE=" "192.0.2.10:1637")"
n3="$(airvpn_iface_name "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBEE=" "192.0.2.11:1637")"
[[ "${n1}" == "${n2}" ]] && pass "iface name deterministic" || fail "iface name not deterministic"
[[ "${n1}" != "${n3}" ]] && pass "iface name changes with endpoint" || fail "iface name collision across endpoints"
[[ "${#n1}" -le 15 ]] && pass "iface name length <= 15 (${n1})" || fail "iface name too long: ${n1}"
[[ "${n1}" == avpn* ]] && pass "iface name prefix avpn" || fail "iface name prefix"

# --- Rich rule generation ---
rule="$(airvpn_endpoint_rich_rule ipv4 192.0.2.10 1637)"
[[ "${rule}" == *'family="ipv4"'* && "${rule}" == *'192.0.2.10'* && "${rule}" == *'1637'* && "${rule}" == *udp* ]] &&
  pass "rich rule IPv4" || fail "rich rule IPv4: ${rule}"

rule6="$(airvpn_endpoint_rich_rule ipv6 2001:db8::10 1637)"
[[ "${rule6}" == *'family="ipv6"'* && "${rule6}" == *'2001:db8::10'* ]] &&
  pass "rich rule IPv6" || fail "rich rule IPv6: ${rule6}"

# --- Managed profile filtering helper (prefix match) ---
AIRVPN_CONNECTION_PREFIX="AirVPN - "
# Simulate nmcli-like filtering logic
filter_managed() {
  local prefix="$1"
  local name
  while IFS= read -r name; do
    [[ "${name}" == "${prefix}"* ]] && printf '%s\n' "${name}"
  done
}
mapfile -t managed < <(printf '%s\n' "AirVPN - Test" "Other VPN" "AirVPN - Two" | filter_managed "${AIRVPN_CONNECTION_PREFIX}")
[[ "${#managed[@]}" -eq 2 ]] && pass "managed profile filtering" || fail "managed profile filtering count=${#managed[@]}"

# --- Secret redaction ---
redacted="$(printf 'PrivateKey = SUPERSECRETVALUE\nEndpoint = 192.0.2.10:1637\n' | airvpn_redact)"
[[ "${redacted}" != *SUPERSECRETVALUE* ]] && pass "private key redacted" || fail "private key leaked in redact"
[[ "${redacted}" == *192.0.2.10* ]] && pass "non-secret fields preserved" || fail "redact over-removed"

# --- Fixture endpoint extraction ---
fx4="${ROOT}/tests/fixtures/AirVPN_Test-IPv4_UDP-1637.conf"
fx6="${ROOT}/tests/fixtures/AirVPN_Test-IPv6_UDP-1637.conf"
ep4="$(airvpn_wg_field "${fx4}" Endpoint)"
ep6="$(airvpn_wg_field "${fx6}" Endpoint)"
[[ "${ep4}" == "192.0.2.10:1637" ]] && pass "fixture IPv4 endpoint field" || fail "fixture IPv4 endpoint"
[[ "${ep6}" == "[2001:db8::10]:1637" ]] && pass "fixture IPv6 endpoint field" || fail "fixture IPv6 endpoint"

# Ensure fixtures do not look like real Curve25519 keys from AirVPN exports beyond placeholders
if grep -E -q 'PrivateKey = [A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=' "${fx4}"; then
  # Fake keys of correct length are OK; reject if file contains obvious "BEGIN" or token patterns
  :
fi
if grep -E -qi 'airvpn\.org|api\.airvpn|-----BEGIN' "${fx4}" "${fx6}"; then
  fail "fixture contains suspicious real-looking material markers"
else
  pass "fixtures lack suspicious real credential markers"
fi

echo
if ((FAILS > 0)); then
  echo "UNIT TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "UNIT TESTS OK"
exit 0
