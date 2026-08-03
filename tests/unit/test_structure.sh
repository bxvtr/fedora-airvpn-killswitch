#!/usr/bin/env bash
# Static regression checks for Ansible task order, uninstall vars, Atomic deps, import add-mode.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILS=$((FAILS + 1))
}

main_yml="${ROOT}/roles/airvpn_client/tasks/main.yml"
fw_line="$(grep -n 'firewall.yml' "${main_yml}" | head -n1 | cut -d: -f1)"
nm_line="$(grep -n 'networkmanager.yml' "${main_yml}" | head -n1 | cut -d: -f1)"
if [[ -n "${fw_line}" && -n "${nm_line}" && "${fw_line}" -lt "${nm_line}" ]]; then
  pass "firewall.yml included before networkmanager.yml"
else
  fail "firewall.yml must precede networkmanager.yml (fw=${fw_line-} nm=${nm_line-})"
fi

# No other task file should import networkmanager before firewall in role entrypoints
if grep -R -n 'import_tasks: networkmanager.yml' "${ROOT}/roles/airvpn_client/tasks" | grep -v 'main.yml'; then
  fail "unexpected networkmanager.yml import outside main.yml"
else
  pass "networkmanager.yml only imported from main.yml"
fi

uninstall="${ROOT}/playbooks/uninstall.yml"
if grep -q 'roles/airvpn_client/defaults/main.yml' "${uninstall}"; then
  pass "uninstall.yml loads role defaults"
else
  fail "uninstall.yml missing role defaults include_vars"
fi

# Defaults define variables uninstall uses
defaults="${ROOT}/roles/airvpn_client/defaults/main.yml"
for var in airvpn_runtime_scripts airvpn_state_dir airvpn_install_dir airvpn_bin_dir \
  airvpn_config_dir airvpn_managed_config_dir airvpn_connection_prefix \
  airvpn_underlay_zone airvpn_restore_zone airvpn_zone \
  airvpn_policy_to_vpn airvpn_policy_to_underlay \
  airvpn_uninstall_remove_profiles airvpn_uninstall_delete_configs; do
  if grep -q "^${var}:" "${defaults}"; then
    pass "defaults define ${var}"
  else
    fail "defaults missing ${var}"
  fi
done

# config.yml overrides still load after defaults in uninstall
def_task="$(grep -n 'Load airvpn_client role defaults' "${uninstall}" | head -n1 | cut -d: -f1)"
cfg_task="$(grep -n 'Load local config.yml overrides' "${uninstall}" | head -n1 | cut -d: -f1)"
if [[ -n "${def_task}" && -n "${cfg_task}" && "${def_task}" -lt "${cfg_task}" ]]; then
  pass "uninstall loads defaults before optional config.yml overrides"
else
  fail "uninstall variable load order incorrect"
fi

atomic="${ROOT}/roles/airvpn_client/tasks/dependencies_fedora_atomic.yml"
if grep -q "python3-firewall" "${atomic}" && grep -q 'package_facts' "${atomic}"; then
  pass "Atomic path checks python3-firewall via package_facts"
else
  fail "Atomic python3-firewall check missing"
fi

if grep -q 'ansible.builtin.dnf\|ansible.builtin.package:' "${atomic}"; then
  fail "Atomic dependency tasks must not call DNF/package install"
else
  pass "Atomic dependency tasks avoid DNF package install"
fi

if grep -E -q 'ansible\.builtin\.(reboot|command|shell):.*reboot|cmd:.*systemctl reboot' "${atomic}"; then
  fail "Atomic tasks must not reboot automatically"
else
  pass "Atomic tasks do not auto-reboot"
fi

# python3-firewall listed for package Fedora host deps
pkg_defaults="${ROOT}/roles/airvpn_client/defaults/main.yml"
if grep -q 'python3-firewall' "${pkg_defaults}"; then
  pass "python3-firewall in role package list"
else
  fail "python3-firewall missing from package list"
fi

import_script="${ROOT}/roles/airvpn_client/files/airvpn-import"
# Managed copy install must appear before the add-mode early return after profile_exists.
if python3 - "${import_script}" <<'PY'
import pathlib, sys

text = pathlib.Path(sys.argv[1]).read_text()
start = text.index("import_one() {")
end = text.index("\nmain_import() {", start)
body = text[start:end]
idx_install = body.find('install -m 0600 -o root -g root "${file}" "${dest}"')
idx_exists = body.find("profile_exists_for_ifname")
idx_add = body.find('[[ "${MODE}" == "add" ]]')
idx_return = body.find("return 0", idx_add if idx_add != -1 else 0)
ok = (
    idx_install != -1
    and idx_exists != -1
    and idx_add != -1
    and idx_return != -1
    and idx_install < idx_exists
    and idx_exists < idx_add < idx_return
)
sys.exit(0 if ok else 1)
PY
then
  pass "import refreshes managed copy before add-mode early return"
else
  fail "import add-mode managed copy order incorrect"
fi

if grep -q 'WireGuard keys/peers in NM unchanged' "${import_script}"; then
  pass "import documents add-mode does not re-import NM WireGuard material"
else
  fail "import missing add-mode NM limitation documentation"
fi

# Unsafe IFS=: / split(':') must not remain in project runtime/ansible paths for nmcli
if grep -R -n "IFS=:" "${ROOT}/roles/airvpn_client/files" "${ROOT}/playbooks" 2>/dev/null | grep -v 'Binary'; then
  fail "unsafe IFS=: still present in role files/playbooks"
else
  pass "no unsafe IFS=: nmcli splits in role files/playbooks"
fi

if grep -n "split(':')" "${ROOT}/roles/airvpn_client/tasks/networkmanager.yml" 2>/dev/null; then
  fail "networkmanager.yml still uses Jinja split(':')"
else
  pass "networkmanager.yml no longer uses Jinja split(':')"
fi

# Owned rules state path + validation helpers present
if grep -q 'owned-underlay-endpoint-rules' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync"; then
  pass "firewall-sync tracks owned-underlay-endpoint-rules"
else
  fail "owned rules state file missing"
fi

if grep -q 'airvpn_validate_endpoint_rich_rule' "${ROOT}/roles/airvpn_client/files/airvpn-firewall-sync"; then
  pass "firewall-sync validates rules before firewall-cmd"
else
  fail "firewall-sync missing rule validation"
fi

uninstall="${ROOT}/playbooks/uninstall.yml"
if grep -A25 'Remove project firewalld policies if present' "${uninstall}" | grep -q 'INVALID_POLICY' &&
  grep -A25 'Remove project firewalld policies if present' "${uninstall}" | grep -q 'NOT_ENABLED'; then
  pass "uninstall treats NOT_ENABLED/INVALID_POLICY policy absence as non-fatal"
else
  fail "uninstall policy deletion failed_when must accept NOT_ENABLED and INVALID_POLICY"
fi

nm_yml="${ROOT}/roles/airvpn_client/tasks/networkmanager.yml"
if grep -q 'airvpn_ensure_runtime_zone' "${nm_yml}" &&
  grep -q 'Reapply underlay zone on active physical interfaces' "${nm_yml}"; then
  pass "networkmanager reapplies runtime underlay zone after profile modify"
else
  fail "networkmanager.yml missing runtime zone reapply"
fi

# Loop register aggregate .rc must not gate failure; assert over .results instead.
if grep -A25 'Reapply underlay zone on active physical interfaces' "${nm_yml}" |
  grep -qE 'failed_when:[[:space:]]*airvpn_runtime_zone\.rc'; then
  fail "runtime zone task still gates on aggregate register .rc"
else
  pass "runtime zone task does not use aggregate register .rc as failed_when"
fi
if grep -q 'Fail closed if any underlay runtime zone reapply failed' "${nm_yml}" &&
  grep -q 'airvpn_runtime_zone.results' "${nm_yml}" &&
  grep -q 'airvpn_failed_runtime_zone_uuids' "${nm_yml}"; then
  pass "runtime zone failures asserted over loop results"
else
  fail "networkmanager.yml missing results-based runtime zone assert"
fi

# Simulated Ansible loop results: earlier rc!=0 must remain visible after later success
# (mirrors the Jinja selectattr('rc','ne',0) | map(attribute='item') filter).
mock_failed_uuids=""
while IFS='|' read -r mock_rc mock_item; do
  [[ -n "${mock_rc}" ]] || continue
  if [[ "${mock_rc}" != "0" ]]; then
    mock_failed_uuids+="${mock_item}"$'\n'
  fi
done <<'MOCK'
1|aaaaaaaa-1111-1111-1111-111111111111
0|bbbbbbbb-2222-2222-2222-222222222222
MOCK
mock_failed_uuids="$(printf '%s' "${mock_failed_uuids}" | sed '/^$/d')"
if [[ "${mock_failed_uuids}" == *'aaaaaaaa-1111-1111-1111-111111111111'* ]] &&
  [[ "${mock_failed_uuids}" != *'bbbbbbbb-2222-2222-2222-222222222222'* ]]; then
  pass "earlier failed loop iteration not hidden by later success"
else
  fail "loop failure aggregation mock broken: ${mock_failed_uuids}"
fi

check_script="${ROOT}/roles/airvpn_client/files/airvpn-check"
if grep -q 'ipv6.dns-priority' "${check_script}" &&
  grep -q 'ipv6.dns-search' "${check_script}" &&
  grep -q 'get-zone-of-interface' "${check_script}" &&
  grep -q 'airvpn_eval_endpoint_rule_coverage' "${check_script}" &&
  grep -q 'no applicable device for runtime zone check' "${check_script}"; then
  pass "airvpn-check verifies ipv6 DNS, runtime zones, exact endpoint rules"
else
  fail "airvpn-check missing ipv6/runtime/exact-endpoint assertions"
fi

if grep -q 'airvpn_ensure_runtime_zone' "${ROOT}/roles/airvpn_client/files/airvpn-protect-connection"; then
  pass "airvpn-protect-connection applies runtime underlay zone"
else
  fail "airvpn-protect-connection missing runtime zone apply"
fi

echo
if ((FAILS > 0)); then
  echo "STRUCTURE TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "STRUCTURE TESTS OK"
exit 0
