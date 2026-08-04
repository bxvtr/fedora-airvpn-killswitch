#!/usr/bin/env bash
# Run all non-destructive unit test scripts under tests/unit/.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

FAILS=0
while IFS= read -r -d '' script; do
  base="$(basename "${script}")"
  [[ "${base}" == "run_all.sh" ]] && continue
  printf '\n=== %s ===\n' "${base}"
  if bash "${script}"; then
    :
  else
    FAILS=$((FAILS + 1))
  fi
done < <(find "${ROOT}/tests/unit" -maxdepth 1 -type f -name 'test_*.sh' -print0 | sort -z)

echo
if ((FAILS > 0)); then
  echo "UNIT SUITE FAILED: ${FAILS} script(s)"
  exit 1
fi
echo "UNIT SUITE OK"
exit 0
