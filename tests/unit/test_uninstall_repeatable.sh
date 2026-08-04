#!/usr/bin/env bash
# Mocked regression tests: uninstall must remain usable after installed
# runtime libraries were removed (second uninstall / partial recovery).
# No root, Ansible host runs, NetworkManager, firewalld, or network access.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UNINSTALL="${ROOT}/playbooks/uninstall.yml"
ROLE_COMMON="${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"
PASS=0
FAIL=0

pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

[[ -f "${UNINSTALL}" && -f "${ROLE_COMMON}" ]] || {
  echo "missing uninstall playbook or role airvpn-common.sh" >&2
  exit 1
}

# --- Structural: NM cleanup snippets must not require installed libexec ---
src_count="$(grep -c 'source "{{ playbook_dir }}/../roles/airvpn_client/files/lib/airvpn-common.sh"' "${UNINSTALL}" || true)"
if [[ "${src_count}" -eq 3 ]]; then
  pass "uninstall sources role airvpn-common.sh from the repository three times"
else
  fail "expected 3 repository sources of airvpn-common.sh, found ${src_count}"
fi

if grep -n 'source "{{ airvpn_install_dir }}/lib/airvpn-common.sh"' "${UNINSTALL}"; then
  fail "uninstall still sources installed libexec airvpn-common.sh"
else
  pass "uninstall does not source installed libexec airvpn-common.sh"
fi

# File removal of installed common.sh must still happen (first uninstall cleanup)
if grep -q "airvpn_install_dir ~ '/lib/airvpn-common.sh'" "${UNINSTALL}"; then
  pass "first uninstall still removes installed airvpn-common.sh"
else
  fail "installed airvpn-common.sh removal missing from uninstall"
fi

# Config retention default path still gated
if grep -A3 'Optionally delete managed AirVPN configuration copies' "${UNINSTALL}" |
  grep -q 'airvpn_uninstall_delete_configs | bool'; then
  pass "managed config deletion remains opt-in"
else
  fail "managed config deletion gate missing"
fi

# --- Simulate second uninstall NM snippets with install_dir absent ---
TMP="$(mktemp -d "${TMPDIR:-/tmp}/uninstall-repeat.XXXXXX")"
cleanup() { rm -rf -- "${TMP}"; }
trap cleanup EXIT

FAKE_INSTALL="${TMP}/usr/local/libexec/airvpn-client"
mkdir -p "${FAKE_INSTALL}/lib"
# Intentionally do NOT install airvpn-common.sh under FAKE_INSTALL (post-first-uninstall).
# Leave a leftover project marker to model partial recovery (runtime gone, artifact remains).
printf 'leftover\n' >"${FAKE_INSTALL}/airvpn-check"
[[ ! -f "${FAKE_INSTALL}/lib/airvpn-common.sh" ]] || {
  fail "test setup accidentally created installed common.sh"
  exit 1
}
pass "fixture: installed runtime library absent; leftover project file present"

MOCKBIN="${TMP}/bin"
mkdir -p "${MOCKBIN}"
cat >"${MOCKBIN}/nmcli" <<'EOF'
#!/usr/bin/env bash
# Empty inventory: second uninstall should be a no-op for NM mutations.
exit 0
EOF
chmod +x "${MOCKBIN}/nmcli"
export PATH="${MOCKBIN}:${PATH}"

extract_snippet() {
  local task_name="$1"
  awk -v name="${task_name}" '
    index($0, "- name: " name) {grab=1; next}
    grab && /ansible.builtin.command:/ {cmd=1; next}
    cmd && /- \|$/ {body=1; next}
    body && /^[[:space:]]*register:/ {exit}
    body { sub(/^            /, ""); print }
  ' "${UNINSTALL}"
}

run_snippet() {
  local task_name="$1"
  local body
  body="$(extract_snippet "${task_name}")"
  if [[ -z "${body}" ]]; then
    fail "failed to extract snippet for: ${task_name}"
    return 1
  fi
  # Substitute Jinja used in snippets with fixture values
  body="${body//\{\{ playbook_dir \}\}/${ROOT}/playbooks}"
  body="${body//\{\{ airvpn_connection_prefix | to_json \}\}/\"AirVPN - \"}"
  body="${body//\{\{ airvpn_underlay_zone | to_json \}\}/\"vpn-underlay\"}"
  body="${body//\{\{ airvpn_restore_zone | to_json \}\}/\"public\"}"
  if grep -F 'airvpn_install_dir' <<<"${body}"; then
    fail "snippet ${task_name} still references airvpn_install_dir after rewrite"
    return 1
  fi
  if ! grep -F "${ROOT}/playbooks/../roles/airvpn_client/files/lib/airvpn-common.sh" <<<"${body}"; then
    fail "snippet ${task_name} does not source repository role common.sh"
    return 1
  fi
  local script="${TMP}/snippet.sh"
  printf '%s\n' "${body}" >"${script}"
  bash "${script}"
}

# First: prove installed-path source would fail when libexec common.sh is gone
set +e
bash -c 'set -Eeuo pipefail; source "'"${FAKE_INSTALL}"'/lib/airvpn-common.sh"' >/dev/null 2>&1
rc=$?
set -e
if [[ "${rc}" -ne 0 ]]; then
  pass "installed-path source fails when libexec common.sh is absent (pre-fix failure mode)"
else
  fail "expected installed-path source to fail when file absent"
fi

# Second: repository-sourced snippets succeed with empty nmcli (no-op)
if run_snippet "Disconnect managed AirVPN profiles"; then
  pass "disconnect snippet succeeds with role common.sh and empty nmcli (second uninstall)"
else
  fail "disconnect snippet failed"
fi

set +e
run_snippet "Remove managed AirVPN NetworkManager profiles"
rc=$?
set -e
if [[ "${rc}" -eq 0 ]]; then
  pass "remove-profiles snippet succeeds as no-op when no managed profiles"
else
  fail "remove-profiles snippet failed (rc=${rc})"
fi

set +e
run_snippet "Restore physical profiles to restore zone"
rc=$?
set -e
if [[ "${rc}" -eq 0 ]]; then
  pass "restore-zone snippet succeeds as no-op when no underlay profiles"
else
  fail "restore-zone snippet failed (rc=${rc})"
fi

# Leftover project file was not touched by NM snippets (file module would remove later)
if [[ -f "${FAKE_INSTALL}/airvpn-check" ]]; then
  pass "NM snippets do not delete leftover project files (Ansible file tasks remain responsible)"
else
  fail "leftover project file unexpectedly removed by NM snippets"
fi

# Critical errors must still fail: nmcli delete non-zero when profiles exist
cat >"${MOCKBIN}/nmcli" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"connection delete"* ]]; then
  echo "delete failed" >&2
  exit 2
fi
if [[ "$*" == *"-f UUID,NAME connection show"* ]] || [[ "$*" == *"-t"* && "$*" == *"UUID,NAME"* && "$*" != *"STATE"* && "$*" != *"TYPE"* ]]; then
  printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:AirVPN - Demo\n'
  exit 0
fi
exit 0
EOF
chmod +x "${MOCKBIN}/nmcli"
set +e
run_snippet "Remove managed AirVPN NetworkManager profiles"
rc=$?
set -e
if [[ "${rc}" -gt 1 ]]; then
  pass "remove-profiles still fails on critical nmcli delete errors"
else
  fail "remove-profiles swallowed critical nmcli delete failure (rc=${rc})"
fi

# Config retention: uninstall must not read private key material
mkdir -p "${TMP}/etc/airvpn-client/configs"
printf 'PrivateKey = should-not-be-read\n' >"${TMP}/etc/airvpn-client/configs/fake.conf"
if grep -q 'PrivateKey' "${UNINSTALL}"; then
  fail "uninstall playbook must not reference PrivateKey"
else
  pass "uninstall playbook does not read PrivateKey material"
fi
[[ -f "${TMP}/etc/airvpn-client/configs/fake.conf" ]] &&
  pass "fixture managed config remains when delete path not exercised" ||
  fail "fixture config missing"

# Foreign firewall objects: uninstall delete-policy list is exact names only
if grep -A25 'Remove project firewalld policies if present' "${UNINSTALL}" |
  grep -q 'airvpn-host-to-vpn' &&
  ! grep -A25 'Remove project firewalld policies if present' "${UNINSTALL}" |
    grep -qiE 'wildcard|glob'; then
  pass "policy cleanup remains exact-name (no wildcards)"
else
  fail "policy cleanup wildcard risk"
fi

# Idempotent absent already-missing policies: failed_when allows NOT_ENABLED / INVALID_POLICY
if grep -A20 'Remove project firewalld policies if present' "${UNINSTALL}" |
  grep -q 'NOT_ENABLED' &&
  grep -A20 'Remove project firewalld policies if present' "${UNINSTALL}" |
  grep -q 'INVALID_POLICY'; then
  pass "already-absent policies remain non-fatal"
else
  fail "already-absent policy handling missing"
fi

echo
if ((FAIL > 0)); then
  echo "UNINSTALL REPEATABILITY TESTS FAILED: ${FAIL} (passed ${PASS})"
  exit 1
fi
echo "UNINSTALL REPEATABILITY TESTS OK (${PASS} passed)"
exit 0
