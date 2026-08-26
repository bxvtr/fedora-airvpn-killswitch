#!/usr/bin/env bash
# Static contract: do not globally disable SSH host-key checking.
# Does not open SSH connections, touch the network, or mutate the host.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILS=$((FAILS + 1))
}

cfg="${ROOT}/ansible.cfg"
inventory="${ROOT}/inventory/localhost.yml"
self="$(basename "${BASH_SOURCE[0]}")"

false_ini='^[[:space:]]*host_key_checking[[:space:]]*=[[:space:]]*(false|no|0)[[:space:]]*([;#].*)?$'
false_env='(^|[[:space:]])ANSIBLE_HOST_KEY_CHECKING[[:space:]]*=[[:space:]]*(false|no|0)([[:space:];#]|$)'

if [[ ! -f "${cfg}" ]]; then
  fail "missing ansible.cfg"
else
  if grep -Ei -q "${false_ini}" "${cfg}"; then
    fail "ansible.cfg must not disable host-key checking"
  else
    pass "ansible.cfg does not disable host-key checking"
  fi
fi

env_hits=0
while IFS= read -r path; do
  [[ -z "${path}" ]] && continue
  [[ "$(basename "${path}")" == "${self}" ]] && continue
  if grep -Ei -q "${false_env}" "${path}"; then
    fail "tracked operational path disables host-key checking via environment: ${path}"
    env_hits=1
  fi
done < <(git ls-files -- ansible.cfg bootstrap.sh inventory playbooks roles tools .github)
if ((env_hits == 0)); then
  pass "no ANSIBLE_HOST_KEY_CHECKING=False in tracked operational config"
fi

if [[ ! -f "${inventory}" ]]; then
  fail "missing canonical inventory ${inventory#"${ROOT}"/}"
elif grep -Eq '^[[:space:]]*ansible_connection:[[:space:]]*local[[:space:]]*$' "${inventory}"; then
  pass "canonical inventory uses ansible_connection: local"
else
  fail "inventory/localhost.yml must set ansible_connection: local"
fi

echo
if ((FAILS > 0)); then
  echo "ANSIBLE HOST-KEY CHECKING TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "ANSIBLE HOST-KEY CHECKING TESTS OK"
exit 0
