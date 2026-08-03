#!/usr/bin/env bash
# Static / mocked tests for bootstrap become-password argv behavior.
# Does not run ansible-playbook, pip, ansible-galaxy, sudo, or live playbooks.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="${ROOT}/bootstrap.sh"
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

argv_has() {
  local needle="$1"
  local arg
  for arg in "${ARGV[@]}"; do
    if [[ "${arg}" == "${needle}" ]]; then
      return 0
    fi
  done
  return 1
}

argv_join() {
  local IFS=' '
  printf '%s' "${ARGV[*]}"
}

# shellcheck source=../../bootstrap.sh
source "${BOOTSTRAP}"

# --- Live install argv ---
ARGV=()
while IFS= read -r -d '' arg; do
  ARGV+=("${arg}")
done < <(bootstrap_install_argv "${ROOT}/playbooks/install.yml" "/secure/airvpn-configs" 0)

if argv_has "--ask-become-pass"; then
  pass "live lifecycle argv includes --ask-become-pass"
else
  fail "live lifecycle argv missing --ask-become-pass"
fi

if argv_has "-e" && argv_join | grep -q 'ansible_python_interpreter=/usr/bin/python3'; then
  pass "live argv includes system Python interpreter extra var"
else
  fail "live argv missing ansible_python_interpreter=/usr/bin/python3"
fi

if argv_has "--check" || argv_has "--diff"; then
  fail "live argv must not include --check/--diff"
else
  pass "live argv omits --check/--diff"
fi

# --- Check mode argv ---
ARGV=()
while IFS= read -r -d '' arg; do
  ARGV+=("${arg}")
done < <(bootstrap_install_argv "${ROOT}/playbooks/install.yml" "/secure/airvpn-configs" 1)

if argv_has "--ask-become-pass"; then
  pass "check-mode argv includes --ask-become-pass"
else
  fail "check-mode argv missing --ask-become-pass"
fi

if argv_has "--check" && argv_has "--diff"; then
  pass "check-mode argv includes --check --diff"
else
  fail "check-mode argv missing --check and/or --diff"
fi

# --- Extra -e forwarding and paths with spaces ---
ARGV=()
while IFS= read -r -d '' arg; do
  ARGV+=("${arg}")
done < <(bootstrap_install_argv \
  "${ROOT}/playbooks/install.yml" \
  "/secure/air vpn/configs" \
  0 \
  -e "airvpn_replace_existing_profiles=true" \
  -e "custom_key=value with spaces")

joined="$(argv_join)"
if [[ "${joined}" == *'airvpn_config_source=/secure/air vpn/configs'* ]]; then
  pass "config source path with spaces stays in a single argv element"
else
  fail "config source path with spaces was not preserved as one argv element"
fi

if argv_has "-e" && [[ "${joined}" == *'airvpn_replace_existing_profiles=true'* ]]; then
  pass "user -e KEY=VALUE forwarding remains intact"
else
  fail "user -e forwarding broken"
fi

if [[ "${joined}" == *'custom_key=value with spaces'* ]]; then
  pass "extra-var values with spaces remain array-safe"
else
  fail "extra-var values with spaces were split unsafely"
fi

# Ensure construction is array/null-delimited (no eval / shell-string exec)
if grep -E -q '(^|[[:space:]])eval[[:space:]]' "${BOOTSTRAP}"; then
  fail "bootstrap must not use eval for command construction"
else
  pass "bootstrap command construction remains array-based (no eval)"
fi

if grep -q 'ANSIBLE_ARGS+=("${arg}")' "${BOOTSTRAP}" &&
  grep -Fq '"${ANSIBLE_ARGS[@]}"' "${BOOTSTRAP}"; then
  pass "bootstrap invokes playbook via argv array expansion"
else
  fail "bootstrap playbook invocation is not clearly array-based"
fi

# --- Skip-playbook exits before playbook / become ---
skip_line="$(grep -n 'Skipping playbook as requested' "${BOOTSTRAP}" | head -n1 | cut -d: -f1)"
argv_call_line="$(grep -n 'bootstrap_install_argv' "${BOOTSTRAP}" | grep 'PLAYBOOK' | head -n1 | cut -d: -f1)"
if [[ -n "${skip_line}" && -n "${argv_call_line}" && "${skip_line}" -lt "${argv_call_line}" ]] &&
  ! awk -v start="${skip_line}" -v end="${argv_call_line}" 'NR>start && NR<end {print}' "${BOOTSTRAP}" |
    grep -q -- '--ask-become-pass'; then
  pass "skip-playbook exits before install argv; no become prompt on that path"
else
  fail "skip-playbook path ordering or become isolation is wrong (${skip_line} vs ${argv_call_line})"
fi

if grep -A3 'Skipping playbook as requested' "${BOOTSTRAP}" | grep -q 'exit 0' &&
  ! grep -A3 'Skipping playbook as requested' "${BOOTSTRAP}" | grep -q 'ansible-playbook'; then
  pass "skip-playbook path does not invoke ansible-playbook"
else
  fail "skip-playbook path still appears to invoke ansible-playbook"
fi

# --- Password safety ---
for needle in 'sudo -S' 'ANSIBLE_BECOME_PASSWORD' 'ansible_become_password' 'pexpect' 'expect -'; do
  if grep -F -q "${needle}" "${BOOTSTRAP}"; then
    fail "bootstrap must not contain insecure password plumbing: ${needle}"
  fi
done
pass "bootstrap contains no sudo -S / ANSIBLE_BECOME_PASSWORD / ansible_become_password plumbing"

if grep -E -q 'read[[:space:]]+-s|BECOME_PASSWORD|SUDO_PASSWORD' "${BOOTSTRAP}"; then
  fail "bootstrap must not read or store become/sudo passwords itself"
else
  pass "bootstrap contains no custom password reader or password env assignment"
fi

# --- Root refusal before venv/collections ---
root_line="$(grep -n 'Do not run bootstrap.sh as root or through sudo' "${BOOTSTRAP}" | head -n1 | cut -d: -f1)"
venv_line="$(grep -n 'Creating or updating virtualenv' "${BOOTSTRAP}" | head -n1 | cut -d: -f1)"
collections_line="$(grep -n 'Installing pinned Ansible collections' "${BOOTSTRAP}" | head -n1 | cut -d: -f1)"
euid_line="$(grep -n 'EUID' "${BOOTSTRAP}" | head -n1 | cut -d: -f1)"
if [[ -n "${root_line}" && -n "${venv_line}" && -n "${collections_line}" && -n "${euid_line}" ]] &&
  [[ "${euid_line}" -lt "${venv_line}" && "${root_line}" -lt "${venv_line}" && "${root_line}" -lt "${collections_line}" ]]; then
  pass "root refusal happens before virtualenv/collection writes"
else
  fail "root refusal ordering before .venv/.ansible writes is incorrect"
fi

if grep -q 'Do not run bootstrap.sh as root or through sudo' "${BOOTSTRAP}" &&
  grep -q 'Run it as your normal user' "${BOOTSTRAP}"; then
  pass "root-refusal message tells users to run without sudo"
else
  fail "root-refusal message incomplete"
fi

# --- Documentation: no sudo ./bootstrap.sh as an install recipe ---
# Negated mentions (do not use sudo ./bootstrap.sh) are allowed in troubleshooting.
if grep -R -n -E 'sudo[[:space:]]+\./bootstrap\.sh' --include='*.md' "${ROOT}" 2>/dev/null |
  grep -viE 'not[[:space:]]|never[[:space:]]|do not|don'\''t' |
  grep -q .; then
  fail "versioned Markdown must not document sudo ./bootstrap.sh as an install command"
else
  pass "documented installation does not use sudo ./bootstrap.sh"
fi

if grep -q -- '--ask-become-pass' "${ROOT}/README.md" &&
  grep -qi 'become' "${ROOT}/README.md" &&
  grep -q './bootstrap.sh' "${ROOT}/README.md"; then
  pass "README documents bootstrap and Become prompting"
else
  fail "README missing bootstrap/Become documentation"
fi

if grep -q -- '--ask-become-pass' "${ROOT}/playbooks/uninstall.yml" 2>/dev/null; then
  :
fi
if grep -A6 'ansible-playbook playbooks/uninstall.yml' "${ROOT}/README.md" | grep -q -- '--ask-become-pass'; then
  pass "uninstall documentation continues to use --ask-become-pass"
else
  fail "uninstall documentation missing --ask-become-pass"
fi

# Integration runner lifecycle unchanged (still has ask-become-pass helper)
if grep -q 'printf.*--ask-become-pass' "${ROOT}/tests/integration/lib/ansible-invoke.sh"; then
  pass "integration-runner lifecycle still includes --ask-become-pass"
else
  fail "integration-runner lifecycle lost --ask-become-pass"
fi

echo
if ((FAIL > 0)); then
  echo "BOOTSTRAP BECOME TESTS FAILED: ${FAIL} (passed ${PASS})"
  exit 1
fi
echo "BOOTSTRAP BECOME TESTS OK (${PASS} passed)"
exit 0
