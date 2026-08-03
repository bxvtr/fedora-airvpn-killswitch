#!/usr/bin/env bash
# Static regression checks for Cursor agent safety files (no host mutation).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILS=$((FAILS + 1))
}

for f in \
  .cursor/permissions.json \
  .cursor/cli.json \
  .cursor/rules/safe-local-development.mdc \
  tools/validate-safe \
  tools/check-agent-safety; do
  if [[ -f "${f}" ]]; then
    pass "exists ${f}"
  else
    fail "missing ${f}"
  fi
done

if [[ -x tools/validate-safe && -x tools/check-agent-safety ]]; then
  pass "wrappers are executable"
else
  fail "wrappers must be executable"
fi

if grep -q '^alwaysApply: true$' .cursor/rules/safe-local-development.mdc; then
  pass "MDC alwaysApply true"
else
  fail "MDC alwaysApply missing"
fi

if grep -q 'Refusing to run as root' tools/validate-safe &&
  grep -q 'Refusing to run as root' tools/check-agent-safety; then
  pass "wrappers refuse root execution"
else
  fail "wrappers missing root refusal"
fi

if grep -E '(^|[[:space:]])ansible-playbook([[:space:]]|$)' tools/validate-safe |
  grep -vE 'have_cmd |skip "' |
  grep -v -- '--syntax-check' >/dev/null; then
  fail "validate-safe has ansible-playbook without --syntax-check"
else
  pass "validate-safe ansible-playbook uses --syntax-check"
fi

if command -v python3 >/dev/null 2>&1; then
  if python3 - <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(".")
text = (root / ".cursor/permissions.json").read_text(encoding="utf-8")
text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
text = re.sub(r"(?m)^\s*//.*?$", "", text)
perms = json.loads(text)
cli = json.loads((root / ".cursor/cli.json").read_text(encoding="utf-8"))
allow = perms.get("terminalAllowlist") or []
if any(e == "git branch" or str(e).startswith("git branch ") for e in allow):
    print("git branch allowlisted")
    sys.exit(1)
if "git" in allow:
    print("bare git allowlisted")
    sys.exit(1)
deny = (cli.get("permissions") or {}).get("deny") or []
for req in (
    "Shell(sudo)",
    "Shell(/usr/bin/sudo)",
    "Shell(tools/integration-test-vm)",
    "Shell(./tools/integration-test-vm)",
    "Write(tools/validate-safe)",
    "Write(.cursor/rules/**)",
):
    if req not in deny:
        print("missing deny " + req)
        sys.exit(1)
allow_cli = (cli.get("permissions") or {}).get("allow") or []
if "Shell(git)" in allow_cli or any(str(x).startswith("Shell(git:branch") for x in allow_cli):
    print("unsafe git allow in cli.json")
    sys.exit(1)
if any("integration-test-vm" in str(x) for x in allow):
    print("integration-test-vm in IDE allowlist")
    sys.exit(1)
if any("integration-test-vm" in str(x) for x in allow_cli):
    print("integration-test-vm in CLI allow")
    sys.exit(1)
# Invalid JSONC should fail: ensure parser rejects trailing garbage when forced
try:
    json.loads("{ not json")
    sys.exit(1)
except json.JSONDecodeError:
    pass
sys.exit(0)
PY
  then
    pass "permissions JSON/JSONC policy invariants"
  else
    fail "permissions JSON/JSONC policy invariants"
  fi
else
  fail "python3 required for policy invariant checks"
fi

# Tracked AirVPN conf outside fixtures
conf_bad=0
while IFS= read -r path; do
  [[ -z "${path}" ]] && continue
  case "${path}" in
    tests/fixtures/*.conf) ;;
    *)
      fail "tracked conf outside fixtures: ${path}"
      conf_bad=1
      ;;
  esac
done < <(git ls-files '*.conf')
if ((conf_bad == 0)); then
  pass "no tracked AirVPN .conf outside fixtures"
fi

if grep -q 'Passing this check does NOT prove' tools/check-agent-safety; then
  pass "self-check documents non-proof limitation"
else
  fail "self-check missing non-proof limitation text"
fi

echo
if ((FAILS > 0)); then
  echo "AGENT SAFETY TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "AGENT SAFETY TESTS OK"
exit 0
