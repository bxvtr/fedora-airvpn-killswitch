#!/usr/bin/env bash
# Non-destructive regression tests for WireGuard import filename handling.
# Uses fake nmcli/wg/firewall-cmd; does not invoke real NetworkManager.
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

IMPORT_SCRIPT="${ROOT}/roles/airvpn_client/files/airvpn-import"
LONG_BASE="AirVPN_CH-Zurich_Toliman_UDP-1637-Entry3.conf"
LONG_FIXTURE="${ROOT}/tests/fixtures/${LONG_BASE}"

# --- Structural guards ---
if grep -nE 'nmcli.*connection import.*\$\{dest\}|connection import type wireguard file "\$\{dest\}"' \
  "${IMPORT_SCRIPT}" >/dev/null; then
  fail "airvpn-import still imports from managed basename path \$dest"
else
  pass "nmcli import does not use managed long basename path"
fi

if grep -q 'import_file="${tmpdir}/${ifname}.conf"' "${IMPORT_SCRIPT}" &&
  grep -q 'connection import type wireguard file "${import_file}"' "${IMPORT_SCRIPT}"; then
  pass "nmcli import uses temporary \${ifname}.conf path"
else
  fail "temporary deterministic import filename wiring missing"
fi

if grep -q 'chmod 0700 "${tmpdir}"' "${IMPORT_SCRIPT}" &&
  grep -q 'install -m 0600' "${IMPORT_SCRIPT}" &&
  grep -q 'cleanup_import_tmpdir' "${IMPORT_SCRIPT}"; then
  pass "import temp dir/file modes and cleanup helper present"
else
  fail "import temporary security/cleanup markers missing"
fi

if grep -q 'airvpn_ensure_connection_inactive' "${IMPORT_SCRIPT}" &&
  grep -q 'Failed to leave newly imported profile inactive' "${IMPORT_SCRIPT}"; then
  pass "import ensures newly imported profiles become inactive"
else
  fail "import missing post-import inactivity enforcement"
fi

if grep -q 'airvpn_uuid_is_active' "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh" &&
  grep -q 'airvpn_ensure_connection_inactive' "${ROOT}/roles/airvpn_client/files/lib/airvpn-common.sh"; then
  pass "common.sh provides exact UUID active-state helpers"
else
  fail "common.sh missing airvpn_uuid_is_active / ensure inactive helpers"
fi

# Deterministic ifname constraints for the long AirVPN fixture
pubkey="$(airvpn_wg_field "${LONG_FIXTURE}" "PublicKey")"
endpoint="$(airvpn_wg_field "${LONG_FIXTURE}" "Endpoint")"
ifname="$(airvpn_iface_name "${pubkey}" "${endpoint}")"
stem_len=${#ifname}
long_stem="${LONG_BASE%.conf}"
if ((stem_len <= 15)) && [[ "${ifname}" =~ ^avpn[0-9a-f]{11}$ ]]; then
  pass "deterministic ifname valid length ${stem_len}: ${ifname}"
else
  fail "deterministic ifname invalid: '${ifname}' len=${stem_len}"
fi
if ((${#long_stem} > 15)); then
  pass "fixture AirVPN basename exceeds IFNAMSIZ-1 (${#long_stem} chars)"
else
  fail "long-name fixture unexpectedly short (${#long_stem})"
fi

# --- Fake command harness ---
harness="$(mktemp -d "${TMPDIR:-/tmp}/airvpn-import-test.XXXXXX")"
cleanup_harness() { rm -rf -- "${harness}"; }
trap cleanup_harness EXIT

bin="${harness}/bin"
state="${harness}/state"
src="${harness}/src"
managed="${harness}/managed"
cfgdir="${harness}/etc"
mkdir -p "${bin}" "${state}" "${src}" "${managed}" "${cfgdir}"
chmod 0700 "${src}" "${managed}" "${cfgdir}"

install -m 0600 "${LONG_FIXTURE}" "${src}/${LONG_BASE}"

# Fake project runtime config consumed by airvpn_load_config
cat >"${cfgdir}/airvpn-client.conf" <<EOF
AIRVPN_CONNECTION_PREFIX="AirVPN - "
AIRVPN_MANAGED_CONFIG_DIR="${managed}"
AIRVPN_ZONE="airvpn"
AIRVPN_DNS_PRIORITY="-100"
AIRVPN_ENABLE_IPV6="true"
AIRVPN_LOCK_FILE="${harness}/airvpn-client.lock"
EOF

# Capture argv and simulate nmcli WireGuard import semantics.
cat >"${bin}/nmcli" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE_DIR="${AIRVPN_TEST_STATE:?}"
mkdir -p "${STATE_DIR}"
printf '%s\n' "$*" >>"${STATE_DIR}/nmcli.argv"
fail_mode="$(cat "${STATE_DIR}/nmcli.fail" 2>/dev/null || true)"
: >>"${STATE_DIR}/active.uuids"
: >>"${STATE_DIR}/import.counter"

active_add() {
  local u="$1"
  if ! grep -qxF "${u}" "${STATE_DIR}/active.uuids" 2>/dev/null; then
    printf '%s\n' "${u}" >>"${STATE_DIR}/active.uuids"
  fi
}

active_del() {
  local u="$1" tmp
  tmp="$(mktemp)"
  grep -vxF "${u}" "${STATE_DIR}/active.uuids" >"${tmp}" 2>/dev/null || true
  mv "${tmp}" "${STATE_DIR}/active.uuids"
}

if [[ "${1:-}" == "-t" && "${2:-}" == "connection" && "${3:-}" == "import" ]]; then
  # argv: -t connection import type wireguard file PATH
  file=""
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    if [[ "${args[i]}" == "file" && $((i + 1)) -lt ${#args[@]} ]]; then
      file="${args[i + 1]}"
      break
    fi
  done
  base="$(basename "${file}")"
  printf '%s\n' "${base}" >>"${STATE_DIR}/import.basenames"
  printf '%s\n' "${base}" >"${STATE_DIR}/import.basename"
  printf '%s\n' "${file}" >"${STATE_DIR}/import.path"
  if [[ -n "${fail_mode}" && "${fail_mode}" == "import" ]]; then
    printf 'Error: The name of the WireGuard config must be a valid interface name followed by ".conf".\n' >&2
    exit 1
  fi
  # Refuse long/invalid basenames the way NetworkManager does.
  stem="${base%.conf}"
  if [[ "${base}" != "${stem}.conf" || ${#stem} -gt 15 || ! "${stem}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'Error: The name of the WireGuard config must be a valid interface name followed by ".conf".\n' >&2
    exit 1
  fi
  if [[ ! -f "${file}" ]]; then
    printf 'Error: missing import file\n' >&2
    exit 1
  fi
  mode="$(stat -c '%a' "${file}")"
  printf '%s\n' "${mode}" >"${STATE_DIR}/import.mode"
  if [[ -n "${fail_mode}" && "${fail_mode}" == "uuid" ]]; then
    # Successful-looking import without a parseable UUID and no fallback rows.
    : >"${STATE_DIR}/list.uuid_name"
    printf "Connection '%s' successfully added.\n" "${stem}"
    exit 0
  fi
  n="$(cat "${STATE_DIR}/import.counter")"
  n=$((n + 1))
  printf '%s\n' "${n}" >"${STATE_DIR}/import.counter"
  uuid="$(printf '11111111-1111-4111-8111-%012d' "${n}")"
  printf '%s\n' "${uuid}" >"${STATE_DIR}/imported.uuid"
  printf '%s\n' "${stem}" >"${STATE_DIR}/imported.name"
  printf '%s\n' "${uuid}" >>"${STATE_DIR}/imported.uuids"
  # Default: mimic Fedora NM WireGuard import auto-activation.
  if [[ ! -f "${STATE_DIR}/import.leave_inactive" ]]; then
    active_add "${uuid}"
  fi
  printf "Connection '%s' (%s) successfully added.\n" "${stem}" "${uuid}"
  exit 0
fi

if [[ "${1:-}" == "-t" && "${2:-}" == "-f" && "${3:-}" == "UUID,STATE" && "${4:-}" == "connection" && "${5:-}" == "show" && "${6:-}" == "--active" ]]; then
  while IFS= read -r u; do
    [[ -n "${u}" ]] || continue
    printf '%s:activated\n' "${u}"
  done <"${STATE_DIR}/active.uuids"
  exit 0
fi

if [[ "${1:-}" == "-g" && "${2:-}" == "connection.interface-name" ]]; then
  # profile_exists_for_ifname probe
  if [[ -f "${STATE_DIR}/existing.ifname" ]]; then
    cat "${STATE_DIR}/existing.ifname"
  fi
  exit 0
fi

if [[ "${1:-}" == "-t" && "${2:-}" == "-f" && "${3:-}" == "UUID,NAME" ]]; then
  if [[ -f "${STATE_DIR}/list.uuid_name" ]]; then
    cat "${STATE_DIR}/list.uuid_name"
  elif [[ -f "${STATE_DIR}/imported.uuid" && -f "${STATE_DIR}/imported.name" ]]; then
    printf '%s:%s\n' "$(cat "${STATE_DIR}/imported.uuid")" "$(cat "${STATE_DIR}/imported.name")"
  fi
  exit 0
fi

if [[ "${1:-}" == "-t" && "${2:-}" == "-f" && "${3:-}" == "UUID,NAME,TYPE,DEVICE,STATE" ]]; then
  if [[ -f "${STATE_DIR}/list.managed" ]]; then
    cat "${STATE_DIR}/list.managed"
  fi
  exit 0
fi

if [[ "${1:-}" == "connection" && "${2:-}" == "modify" ]]; then
  if [[ -n "${fail_mode}" && "${fail_mode}" == "modify" ]]; then
    printf 'Error: modify failed\n' >&2
    exit 1
  fi
  printf '%s\n' "$*" >>"${STATE_DIR}/nmcli.modify"
  exit 0
fi

if [[ "${1:-}" == "connection" && "${2:-}" == "down" ]]; then
  printf '%s\n' "$*" >>"${STATE_DIR}/nmcli.down"
  # uuid is typically argv[3] for: connection down uuid UUID
  down_uuid=""
  if [[ "${3:-}" == "uuid" ]]; then
    down_uuid="${4:-}"
  fi
  if [[ -n "${fail_mode}" && "${fail_mode}" == "down" ]]; then
    printf 'Error: disconnect failed\n' >&2
    exit 1
  fi
  [[ -n "${down_uuid}" ]] && active_del "${down_uuid}"
  exit 0
fi

if [[ "${1:-}" == "connection" && "${2:-}" == "delete" ]]; then
  printf '%s\n' "$*" >>"${STATE_DIR}/nmcli.delete"
  exit 0
fi

printf 'unexpected nmcli argv: %s\n' "$*" >&2
exit 90
EOF
chmod 0755 "${bin}/nmcli"

cat >"${bin}/wg" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${bin}/wg"

cat >"${bin}/firewall-cmd" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "${bin}/firewall-cmd"

# Companion sync must not touch the host firewall.
cat >"${bin}/airvpn-firewall-sync" <<'EOF'
#!/usr/bin/env bash
printf 'fake-firewall-sync\n' >>"${AIRVPN_TEST_STATE}/firewall-sync"
exit 0
EOF
chmod 0755 "${bin}/airvpn-firewall-sync"

export PATH="${bin}:${PATH}"
export AIRVPN_TEST_STATE="${state}"
export AIRVPN_CONFIG_DIR="${cfgdir}"
export TMPDIR="${harness}/tmp"
mkdir -p "${TMPDIR}"
chmod 0700 "${TMPDIR}"

# install -o root requires privileges; sandbox unit runs as EUID=0.
if [[ "${EUID}" -ne 0 ]]; then
  pass "SKIP live import harness (EUID!=0; structural checks above still apply)"
else
  # Successful long-name import
  rm -f "${state}"/*
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  out="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)" || {
    fail "import long filename failed: ${out}"
    out=""
  }
  if [[ -n "${out}" ]]; then
    ibase="$(cat "${state}/import.basename" 2>/dev/null || true)"
    ipath="$(cat "${state}/import.path" 2>/dev/null || true)"
    imode="$(cat "${state}/import.mode" 2>/dev/null || true)"
    if [[ "${ibase}" == "${ifname}.conf" ]]; then
      pass "fake nmcli received ${ifname}.conf not long AirVPN basename"
    else
      fail "fake nmcli basename='${ibase}' expected '${ifname}.conf'"
    fi
    if [[ "${ibase}" != "${LONG_BASE}" ]]; then
      pass "import basename is not original AirVPN filename"
    else
      fail "import still used long AirVPN basename"
    fi
    if [[ -n "${ipath}" && "${ipath}" == "${TMPDIR}"/* && -n "${imode}" && "${imode}" == "600" ]]; then
      pass "import file lived under private TMPDIR with mode 0600"
    else
      fail "import path/mode unexpected path='${ipath}' mode='${imode}'"
    fi
    if [[ -f "${managed}/${LONG_BASE}" ]]; then
      pass "managed copy retained original AirVPN basename"
    else
      fail "managed copy missing original basename"
    fi
    # Temp import copies must not remain
    leftover="$(find "${TMPDIR}" -type f -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "${leftover}" == "0" ]]; then
      pass "no temporary import .conf remains after success"
    else
      fail "temporary import files remain: ${leftover}"
    fi
    if printf '%s' "${out}" | grep -qiE 'PrivateKey|PresharedKey|AAAAAAAA|BBBBBBBB'; then
      fail "import output leaked key material"
    else
      pass "import output has no private key material"
    fi
    if grep -q 'connection down uuid' "${state}/nmcli.down" 2>/dev/null &&
      [[ ! -s "${state}/active.uuids" ]] &&
      printf '%s' "${out}" | grep -q 'inactive'; then
      pass "auto-activated import was disconnected and left inactive"
    else
      fail "post-import deactivation missing or profile still active"
    fi
  fi

  # Already-inactive import: no disconnect required
  rm -rf "${TMPDIR:?}/"* "${state:?}/"*
  mkdir -p "${TMPDIR}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  : >"${state}/import.leave_inactive"
  out_inactive="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)" || fail "inactive import failed: ${out_inactive}"
  if [[ ! -f "${state}/nmcli.down" ]] && [[ ! -s "${state}/active.uuids" ]]; then
    pass "already-inactive import skips connection down"
  else
    fail "already-inactive import unexpectedly called down or left active"
  fi

  # Two-profile import: A must be inactive before B is imported
  SECOND_BASE="AirVPN_CH-Geneva_Hamal_UDP-1637-Entry3.conf"
  install -m 0600 "${ROOT}/tests/fixtures/${SECOND_BASE}" "${src}/${SECOND_BASE}"
  rm -rf "${TMPDIR:?}/"* "${state:?}/"* "${managed:?}/"*
  mkdir -p "${TMPDIR}" "${managed}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  out_two="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)" || fail "two-profile import failed: ${out_two}"
  # Extract relative order from nmcli.argv
  mapfile -t seq_lines < <(grep -E 'connection import|connection down' "${state}/nmcli.argv" || true)
  # Expect: import, down, import, down (modify calls ignored)
  order_ok=0
  if ((${#seq_lines[@]} >= 4)); then
    if [[ "${seq_lines[0]}" == *'connection import'* &&
      "${seq_lines[1]}" == *'connection down'* &&
      "${seq_lines[2]}" == *'connection import'* &&
      "${seq_lines[3]}" == *'connection down'* ]]; then
      order_ok=1
    fi
  fi
  # Stronger: max active never >1 after each recorded down; final active empty
  if ((order_ok == 1)) && [[ ! -s "${state}/active.uuids" ]] &&
    [[ "$(grep -c 'connection import' "${state}/nmcli.argv")" == "2" ]]; then
    pass "two-profile import disconnects each profile before the next import"
  else
    fail "two-profile import ordering/inactivity unexpected (lines=${#seq_lines[@]})"
  fi

  # Deactivation failure aborts before further imports and cleans temp
  rm -rf "${TMPDIR:?}/"* "${state:?}/"* "${managed:?}/"*
  mkdir -p "${TMPDIR}" "${managed}"
  # Only first long-name config in source for this failure case
  rm -f "${src}/${SECOND_BASE}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  printf 'down\n' >"${state}/nmcli.fail"
  set +e
  out_down="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)"
  rc_down=$?
  set -e
  leftover_down="$(find "${harness}" -type f -name "${ifname}.conf" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${rc_down}" -ne 0 && "${leftover_down}" == "0" ]] &&
    printf '%s' "${out_down}" | grep -q 'Failed to leave newly imported profile inactive' &&
    ! printf '%s' "${out_down}" | grep -qiE 'PrivateKey|AAAAAAAA'; then
    pass "deactivation failure aborts import without leaking secrets"
  else
    fail "deactivation failure handling unexpected rc=${rc_down}"
  fi
  # Restore second fixture for later tests that may need only one file — keep single
  # Restore long fixture only in src (already present)

  # Add mode: existing ifname refreshes managed copy without re-import
  rm -f "${state}/import.basename" "${state}/nmcli.argv" "${state}/nmcli.fail" "${state}/nmcli.down"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  # Mark one managed VPN as intentionally active; add-mode refresh must not disconnect it.
  printf '%s\n' "22222222-2222-4222-8222-222222222222" >"${state}/active.uuids"
  printf '%s\n' "${ifname}" >"${state}/existing.ifname"
  printf '%s:%s:wireguard::activated\n' "22222222-2222-4222-8222-222222222222" "AirVPN - existing" >"${state}/list.managed"
  before_imports="$(grep -c 'connection import' "${state}/nmcli.argv" 2>/dev/null || true)"
  before_imports="${before_imports:-0}"
  out2="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)" || fail "add-mode refresh failed: ${out2}"
  after_imports="$(grep -c 'connection import' "${state}/nmcli.argv" 2>/dev/null || true)"
  after_imports="${after_imports:-0}"
  if [[ ! -f "${state}/import.basename" && "${before_imports}" == "${after_imports}" ]] &&
    printf '%s' "${out2}" | grep -q 'already exists' &&
    [[ ! -f "${state}/nmcli.down" ]] &&
    grep -qxF '22222222-2222-4222-8222-222222222222' "${state}/active.uuids"; then
    pass "add mode skips re-import and does not disconnect existing active VPN"
  else
    fail "add mode unexpectedly re-imported or disconnected existing ifname"
  fi
  if [[ -f "${managed}/${LONG_BASE}" ]]; then
    pass "add mode still refreshed managed copy"
  else
    fail "add mode lost managed copy"
  fi

  # Import failure cleanup
  rm -rf "${TMPDIR:?}/"* "${state:?}/"*
  mkdir -p "${TMPDIR}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  printf 'import\n' >"${state}/nmcli.fail"
  set +e
  out3="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)"
  rc3=$?
  set -e
  leftover3="$(find "${harness}" -type f -name "${ifname}.conf" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${rc3}" -ne 0 && "${leftover3}" == "0" ]]; then
    pass "nmcli import failure cleans temporary ${ifname}.conf"
  else
    fail "import failure cleanup rc=${rc3} leftover=${leftover3}"
  fi
  if printf '%s' "${out3}" | grep -qiE 'PrivateKey|AAAAAAAA'; then
    fail "failure output leaked private key"
  else
    pass "failure output has no private key material"
  fi

  # UUID detection failure cleanup
  rm -rf "${TMPDIR:?}/"* "${state:?}/"*
  mkdir -p "${TMPDIR}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  printf 'uuid\n' >"${state}/nmcli.fail"
  set +e
  out_uuid="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)"
  rc_uuid=$?
  set -e
  leftover_uuid="$(find "${harness}" -type f -name "${ifname}.conf" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${rc_uuid}" -ne 0 && "${leftover_uuid}" == "0" ]]; then
    pass "UUID parse failure cleans temporary import file"
  else
    fail "UUID failure cleanup rc=${rc_uuid} leftover=${leftover_uuid}"
  fi

  # Modify failure after successful import still cleans temp
  rm -rf "${TMPDIR:?}/"* "${state:?}/"*
  mkdir -p "${TMPDIR}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  printf 'modify\n' >"${state}/nmcli.fail"
  set +e
  out4="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add 2>&1)"
  rc4=$?
  set -e
  leftover4="$(find "${harness}" -type f -name "${ifname}.conf" 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${rc4}" -ne 0 && "${leftover4}" == "0" ]]; then
    pass "profile modify failure cleans temporary import file"
  else
    fail "modify failure cleanup rc=${rc4} leftover=${leftover4}"
  fi

  # Replace mode: remove managed profiles then import via short temp name; leave inactive
  rm -rf "${TMPDIR:?}/"* "${state:?}/"*
  mkdir -p "${TMPDIR}"
  printf '0\n' >"${state}/import.counter"
  : >"${state}/active.uuids"
  printf '%s:%s:wireguard::\n' "33333333-3333-4333-8333-333333333333" "AirVPN - old" >"${state}/list.managed"
  printf '%s\n' "${ifname}" >"${state}/existing.ifname"
  out_rep="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode replace 2>&1)" || fail "replace mode failed: ${out_rep}"
  if grep -q 'connection delete' "${state}/nmcli.delete" 2>/dev/null &&
    [[ "$(cat "${state}/import.basename" 2>/dev/null || true)" == "${ifname}.conf" ]] &&
    grep -q 'connection down uuid' "${state}/nmcli.down" 2>/dev/null &&
    [[ ! -s "${state}/active.uuids" ]]; then
    pass "replace mode deletes managed profile, imports short basename, leaves inactive"
  else
    fail "replace mode delete/import/inactive behavior unexpected"
  fi

  # Dry-run mentions short import basename, not long managed path import
  rm -f "${state}/nmcli.fail" "${state}/existing.ifname" "${state}/list.managed"
  dry="$(AIRVPN_CONFIG_DIR="${cfgdir}" \
    "${IMPORT_SCRIPT}" --source "${src}" --mode add --dry-run 2>&1)" || fail "dry-run failed"
  if printf '%s\n' "${dry}" | grep -q "${ifname}.conf" &&
    printf '%s\n' "${dry}" | grep -q 'ensure imported profile inactive' &&
    ! printf '%s\n' "${dry}" | grep -q "wireguard file ${managed}/${LONG_BASE}"; then
    pass "dry-run shows deterministic import basename and inactivity step"
  else
    fail "dry-run import path messaging unexpected"
  fi
fi

# Endpoint collection still sees original managed basename layout
cp -a "${LONG_FIXTURE}" "${managed}/${LONG_BASE}"
chmod 0600 "${managed}/${LONG_BASE}"
eps="$(airvpn_collect_endpoints_from_dir "${managed}" || true)"
if printf '%s\n' "${eps}" | grep -q 'ipv4|192.0.2.10|1637'; then
  pass "endpoint discovery works with original managed basename"
else
  fail "endpoint discovery missed managed long-name copy"
fi

if ((FAILS > 0)); then
  printf 'IMPORT FILENAME TESTS FAILED: %s\n' "${FAILS}"
  exit 1
fi
printf 'IMPORT FILENAME TESTS OK\n'
exit 0
