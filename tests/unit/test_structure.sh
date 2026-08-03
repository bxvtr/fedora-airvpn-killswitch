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
  airvpn_firewalld_policy_name_max airvpn_firewalld_zone_name_max \
  airvpn_uninstall_remove_profiles airvpn_uninstall_delete_configs; do
  if grep -q "^${var}:" "${defaults}"; then
    pass "defaults define ${var}"
  else
    fail "defaults missing ${var}"
  fi
done

# Firewalld policy-name length constraint (max_policy_name_len == 18 on Fedora).
vpn_pol="$(grep -E '^airvpn_policy_to_vpn:' "${defaults}" | head -n1 | sed -E 's/^[^:]+:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
under_pol="$(grep -E '^airvpn_policy_to_underlay:' "${defaults}" | head -n1 | sed -E 's/^[^:]+:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
vpn_len=${#vpn_pol}
under_len=${#under_pol}
if [[ "${vpn_pol}" == "airvpn-host-vpn" && "${vpn_len}" -eq 15 && "${vpn_len}" -le 18 ]]; then
  pass "default VPN policy name valid length ${vpn_len}: ${vpn_pol}"
else
  fail "default VPN policy name unexpected: '${vpn_pol}' len=${vpn_len}"
fi
if [[ "${under_pol}" == "airvpn-host-under" && "${under_len}" -eq 17 && "${under_len}" -le 18 ]]; then
  pass "default underlay policy name valid length ${under_len}: ${under_pol}"
else
  fail "default underlay policy name unexpected: '${under_pol}' len=${under_len}"
fi
if [[ "${under_len}" -le 18 && "${vpn_len}" -le 18 && "${vpn_pol}" != "${under_pol}" ]]; then
  pass "default policy names within 18-char limit and distinct"
else
  fail "default policy names violate length/distinct constraints"
fi
# Rejected historical default must not remain as the active default.
if grep -q 'airvpn-host-to-underlay' "${defaults}" || grep -q 'airvpn-host-to-vpn' "${defaults}"; then
  fail "obsolete overlong/at-limit policy defaults still present in role defaults"
else
  pass "obsolete airvpn-host-to-* policy defaults removed from role defaults"
fi
if grep -q 'airvpn-host-to-underlay' "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh" ||
  grep -q 'airvpn-host-to-vpn' "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"; then
  fail "obsolete policy defaults still present in airvpn-common.sh"
else
  pass "airvpn-common.sh fallback policy defaults match short names"
fi

validate_yml="${ROOT}/roles/airvpn_client/tasks/validate.yml"
if grep -q 'airvpn_firewalld_policy_name_max' "${validate_yml}" &&
  grep -q 'Validate firewalld zone and policy name constraints' "${validate_yml}" &&
  grep -qF '[A-Za-z0-9][A-Za-z0-9_-]*' "${validate_yml}"; then
  # Ensure naming assert is the first task name in validate.yml
  first_task="$(awk '/^- name:/{print; exit}' "${validate_yml}")"
  if [[ "${first_task}" == *'Validate firewalld zone and policy name constraints'* ]]; then
    pass "firewalld name validation runs first in validate.yml"
  else
    fail "firewalld name validation is not the first validate.yml task: ${first_task}"
  fi
else
  fail "validate.yml missing firewalld identifier constraints"
fi

# Structural reject fixtures: overlong / bad charset must be described in tests via assert fields
if grep -q 'airvpn_policy_to_underlay | length <=' "${validate_yml}" &&
  grep -q 'airvpn_policy_to_vpn | length <=' "${validate_yml}"; then
  pass "validate.yml enforces policy name max length"
else
  fail "validate.yml missing policy length asserts"
fi

# Confirm rejected 23-char name is only intentional as legacy cleanup or docs/tests,
# never as an active default / runtime fallback / newly created policy name.
bad_default_hits="$(grep -R -n --exclude-dir=.git --exclude-dir=.venv --exclude-dir=.ansible \
  -e 'airvpn-host-to-underlay' "${ROOT}" || true)"
allowed_legacy_ref='CHANGELOG\.md|docs/|tests/unit/|tests/integration/|roles/airvpn_client/vars/main\.yml|roles/airvpn_client/tasks/firewall\.yml|playbooks/uninstall\.yml'
if [[ -z "${bad_default_hits}" ]]; then
  pass "rejected underlay policy literal absent from tree"
elif printf '%s\n' "${bad_default_hits}" | grep -vE "${allowed_legacy_ref}" >/dev/null; then
  fail "unexpected airvpn-host-to-underlay references:\n${bad_default_hits}"
else
  pass "airvpn-host-to-underlay retained only as legacy cleanup or docs/tests"
fi

# Known former VPN default may appear only as legacy cleanup or docs/tests.
legacy_vpn_hits="$(grep -R -n --exclude-dir=.git --exclude-dir=.venv --exclude-dir=.ansible \
  -e 'airvpn-host-to-vpn' "${ROOT}" || true)"
if [[ -z "${legacy_vpn_hits}" ]]; then
  fail "expected legacy cleanup references to airvpn-host-to-vpn"
elif printf '%s\n' "${legacy_vpn_hits}" | grep -vE "${allowed_legacy_ref}|README\.md" >/dev/null; then
  fail "unexpected airvpn-host-to-vpn references:\n${legacy_vpn_hits}"
else
  pass "airvpn-host-to-vpn retained only as legacy cleanup or docs/tests"
fi

# Internal legacy cleanup list must exist and must not be advertised as example config.
legacy_vars="${ROOT}/roles/airvpn_client/vars/main.yml"
if [[ -f "${legacy_vars}" ]] &&
  grep -q 'airvpn_legacy_default_policy_names' "${legacy_vars}" &&
  grep -q 'airvpn-host-to-vpn' "${legacy_vars}" &&
  grep -q 'airvpn-host-to-underlay' "${legacy_vars}" &&
  ! grep -q 'airvpn_legacy_default_policy_names' "${ROOT}/example.config.yml" &&
  ! grep -q 'airvpn_legacy_default_policy_names' "${ROOT}/roles/airvpn_client/defaults/main.yml"; then
  pass "internal legacy policy cleanup list present and not public config"
else
  fail "legacy policy cleanup list missing or exposed as public config"
fi

# Install migration: current policies fully configured before legacy delete; check-config
# after legacy delete; reload includes legacy-changed.
firewall_yml="${ROOT}/roles/airvpn_client/tasks/firewall.yml"
set_under_line="$(grep -n 'Set underlay policy target to REJECT' "${firewall_yml}" | head -n1 | cut -d: -f1)"
legacy_build_line="$(grep -n 'Build legacy firewalld policy cleanup candidates' "${firewall_yml}" | head -n1 | cut -d: -f1)"
legacy_del_line="$(grep -n 'Remove known legacy project firewalld policies' "${firewall_yml}" | head -n1 | cut -d: -f1)"
check_line="$(grep -n 'Validate permanent firewalld configuration before reload' "${firewall_yml}" | head -n1 | cut -d: -f1)"
reload_line="$(grep -n 'Reload firewalld to activate permanent zones and policies' "${firewall_yml}" | head -n1 | cut -d: -f1)"
if [[ -n "${set_under_line}" && -n "${legacy_build_line}" && -n "${legacy_del_line}" &&
  -n "${check_line}" && -n "${reload_line}" &&
  "${set_under_line}" -lt "${legacy_build_line}" &&
  "${legacy_build_line}" -lt "${legacy_del_line}" &&
  "${legacy_del_line}" -lt "${check_line}" &&
  "${check_line}" -lt "${reload_line}" ]] &&
  grep -q 'reject('\''equalto'\'', airvpn_policy_to_vpn' "${firewall_yml}" &&
  grep -q 'reject('\''equalto'\'', airvpn_policy_to_underlay' "${firewall_yml}" &&
  grep -q 'airvpn_legacy_pol_delete is changed' "${firewall_yml}" &&
  ! grep -qE 'delete-policy.*airvpn-\*|firewall-cmd.*--remove-policy=.*\*' "${firewall_yml}"; then
  pass "install migrates known legacy policies after current config, before check-config/reload"
else
  fail "install legacy policy migration order or guards incorrect"
fi

# Uninstall removes union of current + legacy, policies before zones, verifies absence.
if grep -q 'Load airvpn_client internal role vars' "${uninstall}" &&
  grep -q 'Build uninstall firewalld policy cleanup list' "${uninstall}" &&
  grep -q 'airvpn_uninstall_policy_names' "${uninstall}" &&
  grep -q 'Verify project firewalld policies are absent after uninstall' "${uninstall}" &&
  grep -q 'airvpn_legacy_default_policy_names' "${uninstall}"; then
  pass "uninstall loads legacy list and verifies policy absence"
else
  fail "uninstall missing legacy union cleanup or absence verification"
fi
pol_line="$(grep -n 'Remove project firewalld policies if present' "${uninstall}" | head -n1 | cut -d: -f1)"
zone_rm_line="$(grep -n 'Remove project firewalld zones if present' "${uninstall}" | head -n1 | cut -d: -f1)"
verify_pol_line="$(grep -n 'Verify project firewalld policies are absent after uninstall' "${uninstall}" | head -n1 | cut -d: -f1)"
if [[ -n "${pol_line}" && -n "${zone_rm_line}" && -n "${verify_pol_line}" &&
  "${pol_line}" -lt "${zone_rm_line}" && "${zone_rm_line}" -lt "${verify_pol_line}" ]]; then
  pass "uninstall removes policies before zones and verifies afterward"
else
  fail "uninstall policy/zone/verify order incorrect (pol=${pol_line-} zone=${zone_rm_line-} verify=${verify_pol_line-})"
fi

# Name validation must precede mutating role imports (scripts/firewall/nm).
val_line="$(grep -n 'validate.yml' "${main_yml}" | head -n1 | cut -d: -f1)"
scripts_line="$(grep -n 'scripts.yml' "${main_yml}" | head -n1 | cut -d: -f1)"
if [[ -n "${val_line}" && -n "${scripts_line}" && -n "${fw_line}" &&
  "${val_line}" -lt "${scripts_line}" && "${val_line}" -lt "${fw_line}" ]]; then
  pass "validate.yml imported before scripts.yml and firewall.yml"
else
  fail "validate.yml must run before mutating role tasks (val=${val_line-} scripts=${scripts_line-} fw=${fw_line-})"
fi

# Structural charset constraints reject empty/whitespace/metachar via Ansible match.
if grep -q "airvpn_policy_to_vpn is match" "${validate_yml}" &&
  grep -q "airvpn_policy_to_underlay is match" "${validate_yml}" &&
  grep -q 'airvpn_policy_to_vpn != airvpn_policy_to_underlay' "${validate_yml}" &&
  grep -q 'airvpn_policy_to_underlay != airvpn_zone' "${validate_yml}"; then
  pass "validate.yml rejects empty/whitespace/metachar and duplicate/ambiguous names"
else
  fail "validate.yml missing duplicate/charset policy asserts"
fi

# Defaults max constants match discovered firewalld limits.
if grep -qE '^airvpn_firewalld_policy_name_max:[[:space:]]*18[[:space:]]*$' "${defaults}" &&
  grep -qE '^airvpn_firewalld_zone_name_max:[[:space:]]*17[[:space:]]*$' "${defaults}"; then
  pass "defaults encode firewalld policy max 18 and zone max 17"
else
  fail "defaults missing expected firewalld name length constants"
fi

# example.config.yml and conf template stay aligned with variables (not stale literals).
if grep -q 'airvpn-host-vpn' "${ROOT}/example.config.yml" &&
  grep -q 'airvpn-host-under' "${ROOT}/example.config.yml" &&
  ! grep -q 'airvpn-host-to-' "${ROOT}/example.config.yml"; then
  pass "example.config.yml uses short policy defaults"
else
  fail "example.config.yml policy defaults stale"
fi
if grep -q 'AIRVPN_POLICY_TO_VPN="{{ airvpn_policy_to_vpn }}"' \
  "${ROOT}/roles/airvpn_client/templates/airvpn-client.conf.j2" &&
  grep -q 'AIRVPN_POLICY_TO_UNDERLAY="{{ airvpn_policy_to_underlay }}"' \
  "${ROOT}/roles/airvpn_client/templates/airvpn-client.conf.j2"; then
  pass "runtime conf template uses policy variables"
else
  fail "airvpn-client.conf.j2 missing policy variable templates"
fi

# firewall.yml / uninstall use variables, not hard-coded policy literals.
if ! grep -qE 'airvpn-host-(vpn|under|to-)' "${ROOT}/roles/airvpn_client/tasks/firewall.yml" &&
  ! grep -qE 'airvpn-host-(vpn|under|to-)' "${uninstall}"; then
  pass "firewall.yml and uninstall.yml use policy variables not literals"
else
  fail "hard-coded policy name literals found in firewall or uninstall tasks"
fi

# Uninstall deletes project policies before zones.
pol_line="$(grep -n 'delete-policy\|Remove project firewalld policies' "${uninstall}" | head -n1 | cut -d: -f1)"
zone_rm_line="$(grep -n 'Remove project firewalld zones if present' "${uninstall}" | head -n1 | cut -d: -f1)"
if [[ -n "${pol_line}" && -n "${zone_rm_line}" && "${pol_line}" -lt "${zone_rm_line}" ]]; then
  pass "uninstall removes policies before zones"
else
  fail "uninstall policy/zone order incorrect (pol=${pol_line-} zone=${zone_rm_line-})"
fi

# config.yml overrides still load after defaults in uninstall; internal legacy
# vars load last so the fixed cleanup list is not operator-replaceable.
def_task="$(grep -n 'Load airvpn_client role defaults' "${uninstall}" | head -n1 | cut -d: -f1)"
cfg_task="$(grep -n 'Load local config.yml overrides' "${uninstall}" | head -n1 | cut -d: -f1)"
legacy_task="$(grep -n 'Load airvpn_client internal role vars' "${uninstall}" | head -n1 | cut -d: -f1)"
if [[ -n "${def_task}" && -n "${cfg_task}" && -n "${legacy_task}" &&
  "${def_task}" -lt "${cfg_task}" && "${cfg_task}" -lt "${legacy_task}" ]]; then
  pass "uninstall loads defaults, then config overrides, then internal legacy vars"
else
  fail "uninstall variable load order incorrect (def=${def_task-} cfg=${cfg_task-} legacy=${legacy_task-})"
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

# Zone create/delete must be permanent-only (ansible.posix.firewalld ZoneTransaction).
fw_yml="${ROOT}/roles/airvpn_client/tasks/firewall.yml"
set +e
ROOT_DIR="${ROOT}" python3 - <<'PY'
import os
import re
import sys
from pathlib import Path
import yaml

root = Path(os.environ["ROOT_DIR"])
fw = yaml.safe_load((root / "roles/airvpn_client/tasks/firewall.yml").read_text())
un = yaml.safe_load((root / "playbooks/uninstall.yml").read_text())


def zone_tasks(docs):
    out = []
    items = docs
    if isinstance(docs, list) and docs and isinstance(docs[0], dict) and "tasks" in docs[0]:
        items = docs[0]["tasks"]
    elif isinstance(docs, list):
        items = docs
    else:
        items = []
    for t in items:
        if not isinstance(t, dict):
            continue
        mod = t.get("ansible.posix.firewalld")
        if isinstance(mod, dict) and "zone" in mod and "state" in mod:
            out.append((t.get("name"), mod))
    return out


fails = 0
for name, mod in zone_tasks(fw):
    if mod.get("permanent") is not True:
        print(f"FAIL install zone task not permanent: {name} {mod}")
        fails += 1
    if "immediate" in mod and mod.get("immediate") is not False:
        print(f"FAIL install zone task sets immediate: {name} {mod}")
        fails += 1
    if mod.get("state") != "present":
        print(f"FAIL install zone unexpected state: {name} {mod}")
        fails += 1

if len(zone_tasks(fw)) < 2:
    print("FAIL expected two install zone tasks")
    fails += 1

for name, mod in zone_tasks(un):
    if mod.get("state") != "absent":
        continue
    if mod.get("permanent") is not True:
        print(f"FAIL uninstall zone task not permanent: {name} {mod}")
        fails += 1
    if "immediate" in mod and mod.get("immediate") is not False:
        print(f"FAIL uninstall zone task sets immediate: {name} {mod}")
        fails += 1

un_tasks = un[0]["tasks"]
names = [t.get("name", "") for t in un_tasks if isinstance(t, dict)]
try:
    i_pol = next(i for i, n in enumerate(names) if "Remove project firewalld policies" in n)
    i_zone = next(i for i, n in enumerate(names) if "Remove project firewalld zones" in n)
except StopIteration:
    print("FAIL uninstall policy/zone removal tasks missing")
    fails += 1
else:
    if i_pol >= i_zone:
        print("FAIL uninstall must remove policies before zones")
        fails += 1

fw_text = (root / "roles/airvpn_client/tasks/firewall.yml").read_text()
if "airvpn_zone_airvpn is changed" not in fw_text or "airvpn_zone_underlay is changed" not in fw_text:
    print("FAIL reload when-clause must include zone creation changes")
    fails += 1
if "immediate: true" in fw_text:
    print("FAIL firewall.yml still contains immediate: true")
    fails += 1

un_text = (root / "playbooks/uninstall.yml").read_text()
m = re.search(
    r"Remove project firewalld zones if present.*?Reload firewalld after uninstall",
    un_text,
    re.S,
)
if not m:
    print("FAIL could not locate uninstall zone removal block")
    fails += 1
elif "immediate:" in m.group(0):
    print("FAIL uninstall zone removal still sets immediate")
    fails += 1

for path in [fw_text, un_text]:
    for bad in ["--complete-reload", "--panic-off", "nft flush", "iptables -F"]:
        if bad in path:
            print(f"FAIL forbidden firewall reset pattern: {bad}")
            fails += 1

sys.exit(1 if fails else 0)
PY
zone_rc=$?
set -e
if [[ "${zone_rc}" -eq 0 ]]; then
  pass "firewalld zone tasks use permanent-only semantics with ordered reload"
else
  fail "firewalld zone permanent/immediate semantics invalid"
fi

# Policy targets remain fail-closed
if grep -q 'set-target=ACCEPT' "${fw_yml}" && grep -q 'set-target=REJECT' "${fw_yml}"; then
  pass "VPN policy ACCEPT and underlay REJECT targets remain"
else
  fail "fail-closed policy targets missing"
fi

# Policies still removed before zones; only project zone names
if grep -A12 'Remove project firewalld zones if present' "${uninstall}" | grep -q 'airvpn_zone' &&
  grep -A12 'Remove project firewalld zones if present' "${uninstall}" | grep -q 'airvpn_underlay_zone' &&
  ! grep -A12 'Remove project firewalld zones if present' "${uninstall}" | grep -qE 'FedoraWorkstation|public|allow-host-ipv6'; then
  pass "uninstall removes only project zones after policies"
else
  fail "uninstall zone removal targets unexpected"
fi

nm_yml="${ROOT}/roles/airvpn_client/tasks/networkmanager.yml"
if grep -q 'airvpn_ensure_runtime_zone' "${nm_yml}" &&
  grep -q 'Reapply underlay zone on active physical interfaces' "${nm_yml}"; then
  pass "networkmanager reapplies runtime underlay zone after profile modify"
else
  fail "networkmanager.yml missing runtime zone reapply"
fi

# ansible-core 2.21: select()/reject() take Jinja *tests*; length is a filter only.
# Ignore comment-only mentions; fail on non-comment task expressions.
if grep -R -n --include='*.yml' --include='*.yaml' -E "select\(['\"]length['\"]\)|reject\(['\"]length['\"]\)" \
  "${ROOT}/roles" "${ROOT}/playbooks" 2>/dev/null | grep -vE '^[^=]+:[0-9]+:[[:space:]]*#' >/dev/null; then
  fail "invalid select/reject('length') still present in Ansible YAML"
else
  pass "Ansible YAML has no select/reject('length') expressions"
fi

if grep -q "reject('equalto', '')" "${nm_yml}" &&
  grep -q "map('trim')" "${nm_yml}" &&
  grep -A12 'Set physical UUID fact' "${nm_yml}" | grep -q 'unique' &&
  grep -A12 'Set physical UUID fact' "${nm_yml}" | grep -q 'airvpn_physical_uuid_lines.stdout_lines'; then
  pass "physical UUID fact uses trim/reject/unique pipeline"
else
  fail "physical UUID fact expression missing compatible filters"
fi

# Mirror the Jinja pipeline in bash: trim, drop empty, first-seen unique (no sort).
airvpn_uuid_pipeline() {
  local line trimmed
  declare -A seen=()
  declare -a out=()
  for line in "$@"; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "${trimmed}" ]] || continue
    [[ -z "${seen[${trimmed}]+x}" ]] || continue
    seen["${trimmed}"]=1
    out+=("${trimmed}")
  done
  if ((${#out[@]} > 0)); then
    printf '%s\n' "${out[@]}"
  fi
}

u1="11111111-1111-4111-8111-111111111111"
u2="22222222-2222-4222-8222-222222222222"
expect_uuid_case() {
  local name="$1" expected="$2"
  shift 2
  local got
  got="$(airvpn_uuid_pipeline "$@" | paste -sd, -)"
  if [[ "${got}" == "${expected}" ]]; then
    pass "UUID pipeline ${name}"
  else
    fail "UUID pipeline ${name}: got='${got}' expected='${expected}'"
  fi
}
expect_uuid_case empty ""
expect_uuid_case empty_str "" ""
expect_uuid_case whitespace_only "" "   "
expect_uuid_case one "${u1}" "${u1}"
expect_uuid_case one_empty "${u1}" "${u1}" ""
expect_uuid_case dup "${u1}" "${u1}" "${u1}"
expect_uuid_case trim "${u1}" " ${u1} "
expect_uuid_case two "${u1},${u2}" "${u1}" "${u2}"
expect_uuid_case mixed "${u1},${u2}" "${u1}" "" "${u2}" "${u1}"

# Selection task precedes fact; loops consume cleaned list and skip when empty.
sel_line="$(grep -n 'Select physical connection UUIDs' "${nm_yml}" | head -n1 | cut -d: -f1)"
fact_line="$(grep -n 'Set physical UUID fact' "${nm_yml}" | head -n1 | cut -d: -f1)"
zone_line="$(grep -n 'Assign physical NetworkManager profiles to underlay zone' "${nm_yml}" | head -n1 | cut -d: -f1)"
if [[ -n "${sel_line}" && -n "${fact_line}" && -n "${zone_line}" &&
  "${sel_line}" -lt "${fact_line}" && "${fact_line}" -lt "${zone_line}" ]]; then
  pass "physical UUID select → fact → zone assign order"
else
  fail "physical UUID task order incorrect (sel=${sel_line-} fact=${fact_line-} zone=${zone_line-})"
fi
if grep -A20 'Query current zone for each physical connection' "${nm_yml}" |
  grep -q 'when: airvpn_physical_uuids | length > 0'; then
  pass "physical zone query skips safely when UUID list empty"
else
  fail "physical zone query missing empty-list guard"
fi

# Helper contract: one UUID per stdout line; errors on stderr; no headings.
helper="${ROOT}/roles/airvpn_client/files/lib/airvpn-select-physical-uuids.sh"
if grep -q "printf '%s\\\\n' \"\${uuid}\"" "${helper}" &&
  grep -q 'Unknown argument' "${helper}" &&
  grep -q '>&2' "${helper}" &&
  ! grep -qE 'printf.*(UUID|NAME|TYPE)' "${helper}"; then
  pass "select-physical-uuids helper stdout contract is UUID lines only"
else
  fail "select-physical-uuids helper stdout contract unexpected"
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

# --- Ansible controller collection path (ansible.cfg + bootstrap agree) ---
ansible_cfg="${ROOT}/ansible.cfg"
if grep -E -q '^[[:space:]]*collections_path[[:space:]]*=' "${ansible_cfg}" &&
  ! grep -E -q '^[[:space:]]*collections_paths[[:space:]]*=' "${ansible_cfg}"; then
  pass "ansible.cfg uses singular collections_path ini key"
else
  fail "ansible.cfg must set collections_path (singular); plural key is ignored by ansible-core"
fi

cfg_collections_line="$(grep -E '^[[:space:]]*collections_path[[:space:]]*=' "${ansible_cfg}" | head -n1 || true)"
cfg_first_path="$(sed -E 's/^[[:space:]]*collections_path[[:space:]]*=[[:space:]]*//; s/[[:space:]]*$//; s/:.*//' <<<"${cfg_collections_line}")"
if [[ "${cfg_first_path}" == ".ansible/collections" ]]; then
  pass "ansible.cfg prefers repository-local .ansible/collections"
else
  fail "ansible.cfg first collections_path entry is '${cfg_first_path}', expected .ansible/collections"
fi

bootstrap="${ROOT}/bootstrap.sh"
if grep -q 'COLLECTIONS_PATH="${ROOT_DIR}/.ansible/collections"' "${bootstrap}" &&
  grep -q 'ansible-galaxy collection install -r .* -p "${COLLECTIONS_PATH}"' "${bootstrap}" &&
  grep -q -- '--skip-playbook' "${bootstrap}"; then
  pass "bootstrap installs collections under repo .ansible/collections and supports --skip-playbook"
else
  fail "bootstrap collection install path or --skip-playbook missing"
fi

# Relative cfg path and bootstrap absolute path must resolve to the same directory name.
if [[ "${cfg_first_path}" == ".ansible/collections" ]] &&
  grep -q 'ROOT_DIR}/.ansible/collections' "${bootstrap}"; then
  pass "bootstrap install path matches ansible.cfg repository-local collections_path"
else
  fail "bootstrap and ansible.cfg collection locations disagree"
fi

if ! grep -E -q '^[[:space:]]*(export[[:space:]]+)?ANSIBLE_COLLECTIONS_PATH=' \
  "${ROOT}/tools/integration-test-vm" "${ROOT}/tools/validate-safe" 2>/dev/null; then
  pass "integration-test-vm and validate-safe do not export ANSIBLE_COLLECTIONS_PATH"
else
  fail "unexpected ANSIBLE_COLLECTIONS_PATH export in integration-test-vm or validate-safe"
fi

# Mentions for refusal/bash -n allowlists are fine; actual invocation is not.
if grep -E -q '^[[:space:]]*(-[[:space:]]+)?(run:[[:space:]]*)?(\./)?tools/integration-test-vm([[:space:]].*)?$' \
  "${ROOT}/.github/workflows/"*.yml 2>/dev/null; then
  fail "CI workflows must not execute tools/integration-test-vm"
else
  pass "CI workflows do not execute live integration-test-vm"
fi
if grep -E -q '^[[:space:]]*(\./)?tools/integration-test-vm([[:space:]].*)?$' \
  "${ROOT}/tools/validate-safe"; then
  fail "validate-safe must not invoke tools/integration-test-vm"
else
  pass "validate-safe does not invoke live integration-test-vm"
fi

echo
if ((FAILS > 0)); then
  echo "STRUCTURE TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "STRUCTURE TESTS OK"
exit 0
