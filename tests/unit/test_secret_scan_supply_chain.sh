#!/usr/bin/env bash
# Static supply-chain contract for the Gitleaks CI workflow (no network, no extract).
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

FAILS=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() {
  printf 'FAIL: %s\n' "$*"
  FAILS=$((FAILS + 1))
}

workflow=".github/workflows/secret-scan.yml"
PINNED_VERSION="8.30.1"
PINNED_SHA256="551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"
PINNED_ARCHIVE="gitleaks_${PINNED_VERSION}_linux_x64.tar.gz"

if [[ ! -f "${workflow}" ]]; then
  fail "missing ${workflow}"
  echo
  echo "SECRET SCAN SUPPLY CHAIN TESTS FAILED: ${FAILS}"
  exit 1
fi

install_step="$(awk '
  /^[[:space:]]+- name:[[:space:]]*Install pinned Gitleaks[[:space:]]*$/ { in_step=1 }
  in_step {
    if (seen && /^[[:space:]]+- name:/) exit
    seen=1
    print
  }
' "${workflow}")"

if [[ -n "${install_step}" ]]; then
  pass "found Install pinned Gitleaks step"
else
  fail "could not extract Install pinned Gitleaks step from ${workflow}"
  install_step=""
fi

run_code="$(awk '
  /^[[:space:]]+run:[[:space:]]*\|[[:space:]]*$/ { in_run=1; next }
  in_run {
    sub(/^[[:space:]]+/, "")
    if ($0 ~ /^#/) next
    if ($0 ~ /^$/) next
    print
  }
' <<<"${install_step}")"

if grep -qE "GITLEAKS_VERSION:[[:space:]]*\"${PINNED_VERSION}\"" <<<"${install_step}"; then
  pass "pins Gitleaks version ${PINNED_VERSION}"
else
  fail "must pin GITLEAKS_VERSION to \"${PINNED_VERSION}\""
fi

if grep -qE "GITLEAKS_SHA256:[[:space:]]*\"${PINNED_SHA256}\"" <<<"${install_step}"; then
  pass "pins expected Linux x64 SHA-256 in the workflow"
else
  fail "must pin GITLEAKS_SHA256 to \"${PINNED_SHA256}\" in the workflow"
fi

if grep -q "${PINNED_ARCHIVE}" <<<"${install_step}" ||
  grep -q 'gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz' <<<"${install_step}"; then
  pass "targets pinned linux_x64 archive ${PINNED_ARCHIVE}"
else
  fail "must download ${PINNED_ARCHIVE}"
fi

if grep -Eq 'sha256sum[[:space:]]+(--check|-c)\b' <<<"${run_code}" ||
  grep -Eq 'sha256sum[[:space:]].*(--check|-c)\b' <<<"${run_code}"; then
  pass "contains an actual SHA-256 verification step"
else
  fail "must verify the archive with sha256sum --check/-c before use"
fi

if grep -Eqi 'checksums\.txt|sha256sums\.txt|releases/download/.*/checksum' <<<"${install_step}"; then
  fail "must not download an unverified checksum file at runtime"
else
  pass "expected digest is repository-pinned (no checksum-file download)"
fi

if grep -Eqi 'api\.github\.com|github\.com/.*/releases/latest' <<<"${install_step}"; then
  fail "must not resolve version or digest from GitHub at runtime"
else
  pass "no dynamic GitHub API or latest-release lookup"
fi

download_line="$(printf '%s\n' "${run_code}" | grep -nE '^(curl|wget)[[:space:]]' | head -n1 | cut -d: -f1 || true)"
verify_line="$(printf '%s\n' "${run_code}" | grep -nE 'sha256sum[[:space:]]' | head -n1 | cut -d: -f1 || true)"
extract_line="$(printf '%s\n' "${run_code}" | grep -nE '^tar[[:space:]]+-[A-Za-z]*x' | head -n1 | cut -d: -f1 || true)"

if [[ -n "${download_line}" && -n "${verify_line}" && "${download_line}" -lt "${verify_line}" ]]; then
  pass "archive download precedes SHA-256 verification"
else
  fail "download must precede checksum verification (download=${download_line-} verify=${verify_line-})"
fi

if [[ -n "${verify_line}" && -n "${extract_line}" && "${verify_line}" -lt "${extract_line}" ]]; then
  pass "SHA-256 verification precedes archive extraction"
else
  fail "checksum verification must occur before tar extraction (verify=${verify_line-} extract=${extract_line-})"
fi

exec_line="$(printf '%s\n' "${run_code}" | grep -nE '/gitleaks"|/gitleaks[[:space:]]|[[:space:]]gitleaks[[:space:]]' | head -n1 | cut -d: -f1 || true)"
if [[ -n "${extract_line}" && -n "${exec_line}" && "${extract_line}" -lt "${exec_line}" ]]; then
  pass "Gitleaks execution occurs after extraction"
elif [[ -z "${exec_line}" ]]; then
  pass "install step does not execute gitleaks before a later PATH step"
else
  fail "must not execute gitleaks before archive extraction (extract=${extract_line-} exec=${exec_line-})"
fi

if grep -Eq '(^|[[:space:]])sudo([[:space:]]|$)' <<<"${install_step}"; then
  fail "must not use sudo for Gitleaks installation"
else
  pass "no sudo in Gitleaks install step"
fi

if grep -Eq '/usr/local/bin|/usr/bin/' <<<"${install_step}"; then
  fail "must not install Gitleaks into a root-owned system path"
else
  pass "no system-wide Gitleaks install path"
fi

if grep -Eq 'releases/latest|/latest/' "${workflow}" ||
  grep -Eq 'GITLEAKS_VERSION:[[:space:]]*"latest"' "${workflow}"; then
  fail "must not use an unpinned latest release URL or version"
else
  pass "no unpinned latest release URL"
fi

echo
if ((FAILS > 0)); then
  echo "SECRET SCAN SUPPLY CHAIN TESTS FAILED: ${FAILS}"
  exit 1
fi
echo "SECRET SCAN SUPPLY CHAIN TESTS OK"
exit 0
