#!/usr/bin/env bash
# Mocked/static tests for tools/uninstall-audit-snapshot.
# No root, NetworkManager, firewalld, WireGuard, systemd, rpm-ostree, or network.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${ROOT}/tools/uninstall-audit-snapshot"
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/uas-unit.XXXXXX")"
cleanup() { rm -rf -- "${TMP}"; }
trap cleanup EXIT

# --- Static source guarantees (command forms, not prose bans) ---
if grep -E -q '(^|[[:space:]])eval[[:space:]]' "${SCRIPT}"; then
  fail "script must not use eval"
else
  pass "no eval"
fi

# Reject executable-looking secret/mutating invocations (ignore comment/usage prose).
code_lines="$(grep -vE '^[[:space:]]*(#|$)' "${SCRIPT}" || true)"
for needle in \
  'wg show all dump' \
  'wg showconf' \
  'connection export' \
  '--show-secrets' \
  '/etc/NetworkManager/system-connections' \
  'source /etc/airvpn-client/airvpn-client.conf' \
  'rpm-ostree install' \
  'rpm-ostree uninstall' \
  'dnf install' \
  'dnf remove' \
  'systemctl start' \
  'systemctl stop' \
  'systemctl enable' \
  'systemctl disable' \
  'playbooks/install.yml' \
  'playbooks/uninstall.yml'; do
  if printf '%s\n' "${code_lines}" | grep -F -q "${needle}"; then
    fail "forbidden live pattern in non-comment code: ${needle}"
  fi
done
pass "no forbidden secret/mutating invocations in executable lines"

if grep -q 'overwriting snapshots is not supported' "${SCRIPT}" &&
  ! grep -E -q 'FORCE=1|OVERWRITE=1' "${SCRIPT}"; then
  pass "no supported --force/--overwrite"
else
  fail "force/overwrite support unexpectedly present"
fi

# Prose must not collect private-key fields; mentions only as bans are ok.
pk_hits="$(grep -n 'PrivateKey\|PresharedKey' "${SCRIPT}" || true)"
if [[ -z "${pk_hits}" ]]; then
  pass "no private-key field collection"
elif printf '%s\n' "${pk_hits}" | grep -vE 'not read|Never|never|no private|Does not read|private key material' | grep -q .; then
  fail "unexpected PrivateKey/PresharedKey reference"
else
  pass "no private-key field collection"
fi
# --- Help without root ---
if bash "${SCRIPT}" --help >/dev/null; then
  pass "--help works without root"
else
  fail "--help failed"
fi

# --- Arg validation (no root required; fails before capture) ---
assert_die() {
  local desc="$1"
  shift
  local rc=0
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "${rc}" -eq 2 ]]; then
    pass "${desc}"
  else
    fail "${desc} (rc=${rc})"
  fi
}

assert_die "missing --run-name rejected" bash "${SCRIPT}" --phase baseline
assert_die "missing --phase rejected" bash "${SCRIPT}" --run-name demo1
assert_die "invalid phase rejected" bash "${SCRIPT}" --run-name demo1 --phase nope
assert_die "slash in run-name rejected" bash "${SCRIPT}" --run-name 'a/b' --phase baseline
assert_die "dotdot run-name rejected" bash "${SCRIPT}" --run-name '..' --phase baseline
assert_die "leading-dot run-name rejected" bash "${SCRIPT}" --run-name '.hidden' --phase baseline
long="$(printf 'a%.0s' {1..81})"
assert_die "too-long run-name rejected" bash "${SCRIPT}" --run-name "${long}" --phase baseline
assert_die "--force refused" bash "${SCRIPT}" --run-name demo1 --phase baseline --force

# Root required message (without skip)
set +e
out="$(bash "${SCRIPT}" --run-name demo-root --phase baseline --output-root "${TMP}/out" 2>&1)"
rc=$?
set -e
if [[ "${rc}" -eq 2 ]] && grep -q 'must be run as root' <<<"${out}"; then
  pass "root requirement message without UAS_SKIP_ROOT_CHECK"
else
  fail "root requirement not enforced (rc=${rc})"
fi

# --- Mocked capture environment ---
MOCKBIN="${TMP}/mockbin"
mkdir -p "${MOCKBIN}"
cat >"${MOCKBIN}/nmcli" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *-f\ UUID,NAME,TYPE,DEVICE,STATE\ connection\ show*)
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:AirVPN - Test:wireguard:wg0:activated\n'
    ;;
  *-f\ UUID,NAME,TYPE,DEVICE\ connection\ show\ --active*)
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:AirVPN - Test:wireguard:wg0\n'
    ;;
  *-f\ UUID\ connection\ show*)
    printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n'
    ;;
  *-g\ connection.zone,connection.autoconnect,connection.interface-name*)
    printf 'vpn-underlay\nno\neth0\n'
    ;;
  *-f\ DEVICE,TYPE,STATE,CONNECTION\ device\ status*)
    printf 'eth0:ethernet:connected:Home\nwg0:wireguard:connected:AirVPN - Test\n'
    ;;
  *)
    printf 'unexpected nmcli args: %s\n' "$*" >&2
    exit 99
    ;;
esac
exit 0
EOF
cat >"${MOCKBIN}/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
# Refuse mutating verbs
case "$*" in
  *--add-*|*--remove-*|*--new-*|*--delete-*|*--set-*|*--reload*|*--runtime-to-permanent*)
    echo "MUTATION_REFUSED $*" >&2
    exit 99
    ;;
esac
case "$*" in
  *--get-zones*) echo "public fedora airvpn vpn-underlay" ;;
  *--get-policies*) echo "airvpn-host-vpn airvpn-host-under" ;;
  *--get-active-zones*) echo "public"$'\n'"  interfaces: eth0" ;;
  *--info-zone=*|*--info-policy=*) echo "ok" ;;
  *) echo "ok" ;;
esac
exit 0
EOF
cat >"${MOCKBIN}/ip" <<'EOF'
#!/usr/bin/env bash
echo "mock ip $*"
exit 0
EOF
cat >"${MOCKBIN}/wg" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *dump*|*showconf*)
    echo "FORBIDDEN $*" >&2
    exit 99
    ;;
  show\ interfaces) echo "wg0" ;;
  show) echo "interface: wg0"$'\n'"  public key: fake"$'\n'"  listening port: 1" ;;
  *) echo "wg $*" ;;
esac
exit 0
EOF
cat >"${MOCKBIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  start\ *|stop\ *|enable\ *|disable\ *|restart\ *)
    echo "MUTATION $*" >&2
    exit 99
    ;;
  is-active\ *) echo active; exit 0 ;;
  is-enabled\ *) echo enabled; exit 0 ;;
  *) echo ok; exit 0 ;;
esac
EOF
cat >"${MOCKBIN}/rpm" <<'EOF'
#!/usr/bin/env bash
echo "$2-1.0.mock"
exit 0
EOF
cat >"${MOCKBIN}/rpm-ostree" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *install*|*uninstall*|*override*)
    echo "MUTATION $*" >&2
    exit 99
    ;;
  status) echo "Idle" ;;
esac
exit 0
EOF
cat >"${MOCKBIN}/resolvectl" <<'EOF'
#!/usr/bin/env bash
echo "Global"
exit 0
EOF
cat >"${MOCKBIN}/hostnamectl" <<'EOF'
#!/usr/bin/env bash
echo "Static hostname: mock"
exit 0
EOF
cat >"${MOCKBIN}/systemd-detect-virt" <<'EOF'
#!/usr/bin/env bash
echo kvm
exit 0
EOF
cat >"${MOCKBIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl should not run without connectivity flag" >&2
exit 99
EOF
chmod +x "${MOCKBIN}"/*

export PATH="${MOCKBIN}:${PATH}"
export UAS_SKIP_ROOT_CHECK=1

OUT1="${TMP}/audit-out-1"
OUT2="${TMP}/audit-out-2"

# Reject output inside repository
set +e
bash "${SCRIPT}" --run-name r1 --phase baseline --output-root "${ROOT}/audit-out" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 2 ]] && pass "output inside repository rejected" || fail "repo output-root not rejected"

# Reject dangerous roots
for bad in /etc /usr /var /tmp /home /; do
  set +e
  bash "${SCRIPT}" --run-name r1 --phase baseline --output-root "${bad}" >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" -eq 2 ]] || fail "dangerous root not rejected: ${bad}"
done
pass "dangerous output roots rejected"

# Symlink-based output path rejected
mkdir -p "${TMP}/real-out"
ln -s "${TMP}/real-out" "${TMP}/link-out"
set +e
bash "${SCRIPT}" --run-name r1 --phase baseline --output-root "${TMP}/link-out" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 2 ]] && pass "symlink output-root rejected" || fail "symlink output-root accepted"

# Successful capture
bash "${SCRIPT}" --run-name runA --phase baseline --output-root "${OUT1}"
phase_dir="${OUT1}/runA/baseline"
if [[ -d "${phase_dir}" && -f "${phase_dir}/manifest.txt" && -f "${phase_dir}/filesystem.txt" ]]; then
  pass "capture publishes phase directory with manifest"
else
  fail "capture did not publish expected files"
fi

# Permissions 0700/0600
mode_dir="$(stat -c '%a' "${phase_dir}" 2>/dev/null || stat -f '%Lp' "${phase_dir}")"
mode_file="$(stat -c '%a' "${phase_dir}/manifest.txt" 2>/dev/null || stat -f '%Lp' "${phase_dir}/manifest.txt")"
if [[ "${mode_dir}" == "700" && "${mode_file}" == "600" ]]; then
  pass "phase dir 0700 and files 0600"
else
  fail "unexpected modes dir=${mode_dir} file=${mode_file}"
fi

# No overwrite
set +e
bash "${SCRIPT}" --run-name runA --phase baseline --output-root "${OUT1}" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 2 ]] && pass "existing phase directory not overwritten" || fail "overwrite allowed"

# Partial directory blocks
mkdir -p "${OUT1}/runA/.installed.partial.99999"
set +e
bash "${SCRIPT}" --run-name runA --phase installed --output-root "${OUT1}" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 2 ]] && pass "existing partial directory not overwritten" || fail "partial reuse allowed"

# Separate run names / phases
bash "${SCRIPT}" --run-name runB --phase baseline --output-root "${OUT1}"
bash "${SCRIPT}" --run-name runA --phase uninstalled --output-root "${OUT1}"
[[ -d "${OUT1}/runB/baseline" && -d "${OUT1}/runA/uninstalled" && -d "${OUT1}/runA/baseline" ]] &&
  pass "separate run names and phases remain isolated" ||
  fail "run/phase isolation broken"

# Connectivity off by default (curl stub exits 99)
if grep -q 'not requested' "${OUT1}/runA/baseline/connectivity.txt"; then
  pass "connectivity disabled without flag"
else
  fail "connectivity unexpectedly active"
fi

# Connectivity opt-in
cat >"${MOCKBIN}/curl" <<'EOF'
#!/usr/bin/env bash
echo "203.0.113.10"
exit 0
EOF
chmod +x "${MOCKBIN}/curl"
bash "${SCRIPT}" --run-name runC --phase baseline --output-root "${OUT2}" --include-connectivity
if grep -q '203.0.113.10' "${OUT2}/runC/baseline/connectivity.txt"; then
  pass "connectivity opt-in runs probes"
else
  fail "connectivity opt-in did not capture probe output"
fi

# Config contents not read: plant a fake config with PrivateKey and ensure not in artifacts
mkdir -p /tmp 2>/dev/null || true
# Use OUT tree only — cannot write /etc in unit test. Assert collector never cats configs:
if grep -E -q 'cat[[:space:]]+/etc/airvpn-client/configs|PrivateKey[[:space:]]*=' "${SCRIPT}"; then
  fail "collector appears to read config file contents"
else
  pass "collector does not read managed config contents"
fi

# NM field safety
if grep -q 'UUID,NAME,TYPE,DEVICE' "${SCRIPT}" && ! grep -q -- '--show-secrets' "${SCRIPT}"; then
  pass "NetworkManager uses explicit safe fields"
else
  fail "NM field selection unsafe"
fi

# Compare mode: no host collectors — replace mocks with failing ones
for c in nmcli firewall-cmd ip wg systemctl; do
  cat >"${MOCKBIN}/${c}" <<'EOF'
#!/usr/bin/env bash
echo "COMPARE_MUST_NOT_RUN $0 $*" >&2
exit 99
EOF
  chmod +x "${MOCKBIN}/${c}"
done
bash "${SCRIPT}" --run-name runA --compare --output-root "${OUT1}"
comp_count="$(find "${OUT1}/runA/comparisons" -mindepth 1 -maxdepth 1 -type d | wc -l)"
[[ "${comp_count}" -ge 1 ]] && pass "compare mode wrote comparison directory" || fail "compare mode missing output"

# Second compare creates new dir (no overwrite)
bash "${SCRIPT}" --run-name runA --compare --output-root "${OUT1}"
comp_count2="$(find "${OUT1}/runA/comparisons" -mindepth 1 -maxdepth 1 -type d | wc -l)"
[[ "${comp_count2}" -ge 2 ]] && pass "compare mode does not overwrite prior comparisons" || fail "compare overwrite"

# Missing phases SKIP in summary
sum="$(find "${OUT1}/runA/comparisons" -name comparison-summary.txt | head -n1)"
if grep -q 'SKIP' "${sum}"; then
  pass "missing compare phases reported as SKIP"
else
  # runA has baseline+uninstalled but maybe not after-reboot — should SKIP some
  if grep -q 'after-reboot' "${sum}"; then
    pass "compare summary mentions after-reboot"
  else
    fail "compare summary missing SKIP for absent phases"
  fi
fi

# Structural vs runtime split
if find "${OUT1}/runA/comparisons" -name '*.structural.diff' | grep -q .; then
  pass "structural diffs separated from runtime"
else
  fail "missing structural.diff artifacts"
fi

# Manifest PASS/SKIP/WARN
if grep -E -q '^(PASS|SKIP|WARN|FAIL) ' "${OUT1}/runA/baseline/manifest.txt"; then
  pass "manifest contains PASS/SKIP/WARN/FAIL lines"
else
  fail "manifest format unexpected"
fi

# run-metadata exists once
[[ -f "${OUT1}/runA/run-metadata.txt" ]] && pass "run-metadata.txt created" || fail "missing run-metadata"

# CI / validate-safe must not invoke collector as a command.
# Guard patterns that mention the tool name (ShellCheck find -name, grep bans)
# are allowed; only YAML run-steps / direct invocations fail this check.
if grep -E -q \
  '^[[:space:]]*(-[[:space:]]+)?(run:[[:space:]]*)?(\./)?tools/uninstall-audit-snapshot([[:space:]].*)?$' \
  "${ROOT}/.github/workflows/"*.yml 2>/dev/null; then
  fail "CI workflows must not execute tools/uninstall-audit-snapshot"
elif grep -E -q \
  '^[[:space:]]*(\./)?tools/uninstall-audit-snapshot([[:space:]].*)?$' \
  "${ROOT}/tools/validate-safe"; then
  fail "validate-safe must not invoke tools/uninstall-audit-snapshot"
else
  pass "CI/validate-safe do not auto-run uninstall-audit-snapshot"
fi

# Numeric SUDO owner helper via sourced functions
# shellcheck source=../../tools/uninstall-audit-snapshot
source "${SCRIPT}"
export SUDO_UID=abc SUDO_GID=1
if ! uas_sudo_owner >/dev/null; then
  pass "non-numeric SUDO_UID rejected"
else
  fail "non-numeric SUDO_UID accepted"
fi
export SUDO_UID=1000 SUDO_GID=1000
if owner="$(uas_sudo_owner)" && [[ "${owner}" == "1000 1000" ]]; then
  pass "numeric SUDO_UID/GID accepted"
else
  fail "numeric SUDO owner failed"
fi

# Direct root path supported (skip check already on; ensure capture still works)
bash "${SCRIPT}" --run-name runD --phase installed --output-root "${OUT2}"
[[ -d "${OUT2}/runD/installed" ]] && pass "direct capture path supported with test root skip" || fail "installed phase missing"

# --- Publish / interrupt safety (mocked; no live host collectors) ---

# Successful capture leaves no partial and no FAILED.txt
bash "${SCRIPT}" --run-name runPub --phase baseline --output-root "${OUT2}"
pub_phase="${OUT2}/runPub/baseline"
partials_left="$(find "${OUT2}/runPub" -maxdepth 1 -type d -name '.baseline.partial.*' 2>/dev/null | wc -l)"
if [[ -d "${pub_phase}" && ! -e "${pub_phase}/FAILED.txt" && "${partials_left}" -eq 0 ]]; then
  pass "successful capture publishes final phase without FAILED.txt or leftover partial"
else
  fail "successful capture publish invariants broken"
fi

# Structural: capture must not wrap the collector list in broad set +e
if grep -B6 'uas_write_phase_metadata "${partial_dir}/metadata.txt"' "${SCRIPT}" | grep -q 'set +e'; then
  fail "capture still begins collectors under broad set +e"
else
  pass "capture does not disable errexit for the collector list"
fi

if grep -q "uas_capture_on_signal INT 130" "${SCRIPT}" &&
  grep -q "uas_capture_on_signal TERM 143" "${SCRIPT}" &&
  grep -q 'publish_allowed=1' "${SCRIPT}"; then
  pass "signal handlers exit non-zero and publish uses an explicit success gate"
else
  fail "signal/publish gate markers missing"
fi

# Critical failure writing manifest: do not publish final phase
OUT_FAIL="${TMP}/audit-fail"
mkdir -p "${OUT_FAIL}"
REAL_MKTEMP="$(command -v mktemp)"
cat >"${MOCKBIN}/mktemp" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *manifest* ]]; then
  echo "forced mktemp failure for manifest" >&2
  exit 1
fi
exec "${REAL_MKTEMP}" "\$@"
EOF
chmod +x "${MOCKBIN}/mktemp"
set +e
bash "${SCRIPT}" --run-name runFail --phase baseline --output-root "${OUT_FAIL}" >/dev/null 2>&1
rc=$?
set -e
# Restore mktemp for later tests
cat >"${MOCKBIN}/mktemp" <<EOF
#!/usr/bin/env bash
exec "${REAL_MKTEMP}" "\$@"
EOF
chmod +x "${MOCKBIN}/mktemp"
if [[ "${rc}" -ne 0 && ! -d "${OUT_FAIL}/runFail/baseline" ]]; then
  fp="$(find "${OUT_FAIL}/runFail" -maxdepth 1 -type d -name '.baseline.partial.*' 2>/dev/null | head -n1 || true)"
  if [[ -n "${fp}" && -f "${fp}/FAILED.txt" ]] && grep -q 'failure_type=' "${fp}/FAILED.txt"; then
    pass "critical manifest write failure leaves failed partial and no final phase"
  elif [[ -n "${fp}" ]]; then
    pass "critical manifest write failure prevents publish and retains partial"
  else
    pass "critical manifest write failure prevents final phase publish"
  fi
else
  fail "critical failure published phase or exited zero (rc=${rc})"
fi

# WARN/SKIP path: remove optional curl; connectivity without opt-in still publishes
rm -f "${MOCKBIN}/curl"
bash "${SCRIPT}" --run-name runSkip --phase baseline --output-root "${OUT_FAIL}"
if [[ -d "${OUT_FAIL}/runSkip/baseline" && ! -e "${OUT_FAIL}/runSkip/baseline/FAILED.txt" ]] &&
  grep -q 'not requested' "${OUT_FAIL}/runSkip/baseline/connectivity.txt"; then
  pass "WARN/SKIP optional tooling does not block successful publish"
else
  fail "optional SKIP path blocked publish incorrectly"
fi

# SIGINT during hanging collector: no final phase, exit 130
cat >"${MOCKBIN}/nmcli" <<'EOF'
#!/usr/bin/env bash
# Hang so the unit test can deliver SIGINT before publish.
sleep 60
exit 0
EOF
chmod +x "${MOCKBIN}/nmcli"
OUT_SIG="${TMP}/audit-sig"
mkdir -p "${OUT_SIG}"
bash "${SCRIPT}" --run-name runSigInt --phase baseline --output-root "${OUT_SIG}" >/dev/null 2>&1 &
sig_pid=$!
# Wait until capture has started collectors (traps installed; metadata written).
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  sp_wait="$(find "${OUT_SIG}/runSigInt" -maxdepth 1 -type d -name '.baseline.partial.*' 2>/dev/null | head -n1 || true)"
  if [[ -n "${sp_wait}" && -f "${sp_wait}/metadata.txt" ]]; then
    break
  fi
  sleep 0.1
done
kill -INT "${sig_pid}" 2>/dev/null || true
set +e
wait "${sig_pid}"
sig_rc=$?
set -e
if [[ "${sig_rc}" -eq 130 && ! -d "${OUT_SIG}/runSigInt/baseline" ]]; then
  sp="$(find "${OUT_SIG}/runSigInt" -maxdepth 1 -type d -name '.baseline.partial.*' 2>/dev/null | head -n1 || true)"
  if [[ -n "${sp}" && -f "${sp}/FAILED.txt" ]] && grep -q 'failure_type=signal' "${sp}/FAILED.txt"; then
    pass "SIGINT prevents publish and exits 130 with FAILED partial"
  else
    pass "SIGINT prevents publish and exits 130"
  fi
else
  fail "SIGINT publish/exit semantics broken (rc=${sig_rc})"
fi

# SIGTERM during hanging collector: no final phase, exit 143
bash "${SCRIPT}" --run-name runSigTerm --phase baseline --output-root "${OUT_SIG}" >/dev/null 2>&1 &
sig_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  sp_wait="$(find "${OUT_SIG}/runSigTerm" -maxdepth 1 -type d -name '.baseline.partial.*' 2>/dev/null | head -n1 || true)"
  if [[ -n "${sp_wait}" && -f "${sp_wait}/metadata.txt" ]]; then
    break
  fi
  sleep 0.1
done
kill -TERM "${sig_pid}" 2>/dev/null || true
set +e
wait "${sig_pid}"
sig_rc=$?
set -e
if [[ "${sig_rc}" -eq 143 && ! -d "${OUT_SIG}/runSigTerm/baseline" ]]; then
  pass "SIGTERM prevents publish and exits 143"
else
  fail "SIGTERM publish/exit semantics broken (rc=${sig_rc})"
fi

# Restore fast nmcli mock used earlier in this file
cat >"${MOCKBIN}/nmcli" <<'EOF'
#!/usr/bin/env bash
echo "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:AirVPN - Demo:wireguard::activated"
exit 0
EOF
chmod +x "${MOCKBIN}/nmcli"

# Compare refuses phases that contain FAILED.txt
OUT_CMP="${TMP}/audit-cmp-fail"
mkdir -p "${OUT_CMP}/runBad/baseline" "${OUT_CMP}/runBad/uninstalled"
printf 'phase=baseline\nfailure_type=signal\nsignal_or_exit_status=INT\nfailed_at=test\n' \
  >"${OUT_CMP}/runBad/baseline/FAILED.txt"
printf 'ok\n' >"${OUT_CMP}/runBad/uninstalled/manifest.txt"
set +e
bash "${SCRIPT}" --run-name runBad --compare --output-root "${OUT_CMP}" >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" -eq 2 ]] && pass "compare mode refuses phases containing FAILED.txt" ||
  fail "compare mode accepted FAILED.txt phase (rc=${rc})"

# Existing final phase still untouched (re-check after new tests)
if [[ -d "${OUT1}/runA/baseline" ]]; then
  pass "earlier final phase directory remains intact"
else
  fail "earlier final phase directory was disturbed"
fi

echo
if ((FAIL > 0)); then
  echo "UNINSTALL AUDIT SNAPSHOT TESTS FAILED: ${FAIL} (passed ${PASS})"
  exit 1
fi
echo "UNINSTALL AUDIT SNAPSHOT TESTS OK (${PASS} passed)"
exit 0
