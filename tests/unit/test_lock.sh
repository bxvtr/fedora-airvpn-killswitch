#!/usr/bin/env bash
# Unit tests for shared mutation lock (no NetworkManager/firewalld changes).
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

tmpdir="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '${tmpdir}'" EXIT
export AIRVPN_LOCK_FILE="${tmpdir}/airvpn-client.lock"
ready="${tmpdir}/holder-ready"

# Hold the exclusive lock in the background on the same lock file.
: >"${ready}"
rm -f "${ready}"
(
  exec 8>"${AIRVPN_LOCK_FILE}"
  flock -n 8 || exit 99
  : >"${ready}"
  sleep 5
) &
holder_pid=$!
for _ in $(seq 1 50); do
  [[ -f "${ready}" ]] && break
  sleep 0.05
done
if [[ ! -f "${ready}" ]]; then
  fail "background lock holder failed to start"
  kill "${holder_pid}" 2>/dev/null || true
else
  # AIRVPN_LOCK_HELD must NOT bypass locking (airvpn_die calls exit — use subshell).
  export AIRVPN_LOCK_HELD=1
  rc=0
  (
    airvpn_with_lock test_env_bypass true
  ) >/dev/null 2>&1 || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    pass "AIRVPN_LOCK_HELD=1 does not bypass exclusive flock"
  else
    fail "AIRVPN_LOCK_HELD=1 incorrectly skipped locking"
  fi
  unset AIRVPN_LOCK_HELD
fi
kill "${holder_pid}" 2>/dev/null || true
wait "${holder_pid}" 2>/dev/null || true

# Nested same-process re-entry via FD 9 must succeed.
nested_ok=0
inner() { nested_ok=1; }
outer() { airvpn_with_lock inner_lock inner; }
if airvpn_with_lock outer_lock outer; then
  [[ "${nested_ok}" -eq 1 ]] && pass "nested same-process lock re-entry" || fail "nested re-entry did not run inner"
else
  fail "nested same-process lock re-entry failed"
fi

# Child subprocess inheriting FD 9 must re-enter without deadlock.
child_script="${tmpdir}/child.sh"
cat >"${child_script}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
source "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"
export AIRVPN_LOCK_FILE="${AIRVPN_LOCK_FILE}"
airvpn_with_lock child true
printf 'child-ok\n'
EOF
chmod 0700 "${child_script}"

out=""
parent_with_child() {
  out="$("${child_script}")"
}
if airvpn_with_lock parent parent_with_child; then
  [[ "${out}" == "child-ok" ]] && pass "inherited FD 9 nested subprocess lock" || fail "child output unexpected: ${out}"
else
  fail "parent/child nested lock failed"
fi

# Lock file mode should be 0600 after acquisition
airvpn_with_lock mode_check true
mode="$(stat -c '%a' "${AIRVPN_LOCK_FILE}" 2>/dev/null || stat -f '%OLp' "${AIRVPN_LOCK_FILE}")"
mode="${mode: -3}"
if [[ "${mode}" == "600" ]]; then
  pass "lock file mode 0600"
else
  fail "lock file mode expected 600 got ${mode}"
fi

# Read-only helper path: airvpn-status should not take the mutation lock
if grep -q 'airvpn_with_lock' "${ROOT}/roles/airvpn_client/files/airvpn-status"; then
  fail "airvpn-status should not take mutation lock"
else
  pass "airvpn-status remains lock-free"
fi

for cmd in airvpn-import airvpn-switch airvpn-firewall-sync airvpn-killswitch airvpn-protect-connection; do
  if grep -q 'airvpn_with_lock' "${ROOT}/roles/airvpn_client/files/${cmd}"; then
    pass "${cmd} uses shared lock wrapper"
  else
    fail "${cmd} missing airvpn_with_lock"
  fi
done

# Ensure no AIRVPN_LOCK_HELD trust remains in common library
if grep -E -q 'export AIRVPN_LOCK_HELD|AIRVPN_LOCK_HELD:-' "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"; then
  fail "common.sh still trusts AIRVPN_LOCK_HELD for bypass"
else
  pass "common.sh does not trust AIRVPN_LOCK_HELD bypass"
fi

echo
if ((FAILS > 0)); then
  echo "LOCK TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "LOCK TESTS OK"
exit 0
