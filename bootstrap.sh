#!/usr/bin/env bash
# Bootstrap Ansible controller tooling and run the local install playbook.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${ROOT_DIR}/.venv"
COLLECTIONS_PATH="${ROOT_DIR}/.ansible/collections"
REQUIREMENTS_CONTROLLER="${ROOT_DIR}/requirements-controller.txt"
REQUIREMENTS_GALAXY="${ROOT_DIR}/requirements.yml"
PLAYBOOK="${ROOT_DIR}/playbooks/install.yml"

CONFIG_SOURCE=""
CHECK_MODE=0
SKIP_PLAYBOOK=0
EXTRA_ANSIBLE_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh --config-source DIR [options]

Bootstrap a repository-local Python virtualenv with pinned ansible-core,
install pinned Ansible collections, then run the local install playbook on
this Fedora host (controller == managed host).

Required:
  --config-source DIR   Absolute path to AirVPN WireGuard .conf files
                        (never downloaded by this project; treat as secrets)

Options:
  --check               Run ansible-playbook in check mode where supported
  --skip-playbook       Only prepare the controller environment
  -e KEY=VALUE          Extra Ansible -e arguments (repeatable)
  -h, --help            Show this help

Examples:
  ./bootstrap.sh --config-source /secure/airvpn-configs
  ./bootstrap.sh --config-source /secure/airvpn-configs --check
  ./bootstrap.sh --config-source /secure/airvpn-configs -e airvpn_replace_existing_profiles=true
EOF
}

log() { printf '%s\n' "[bootstrap] $*"; }
die() {
  printf '%s\n' "[bootstrap] ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-source)
      CONFIG_SOURCE="${2:-}"
      shift 2
      ;;
    --check)
      CHECK_MODE=1
      shift
      ;;
    --skip-playbook)
      SKIP_PLAYBOOK=1
      shift
      ;;
    -e)
      EXTRA_ANSIBLE_ARGS+=(-e "${2:-}")
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${CONFIG_SOURCE}" ]] || {
  usage
  die "--config-source is required"
}
[[ "${CONFIG_SOURCE}" == /* ]] || die "--config-source must be an absolute path"

# Refuse to use a source directory inside this Git repository tree.
case "${CONFIG_SOURCE}" in
  "${ROOT_DIR}" | "${ROOT_DIR}"/*)
    die "Refusing AirVPN config source inside the Git repository (${CONFIG_SOURCE}). Keep secrets outside the clone."
    ;;
esac

if ((SKIP_PLAYBOOK == 0)); then
  [[ -d "${CONFIG_SOURCE}" ]] || die "Configuration source directory not found: ${CONFIG_SOURCE}"
elif [[ ! -d "${CONFIG_SOURCE}" ]]; then
  log "NOTE: --config-source path does not exist yet; continuing because --skip-playbook was set"
fi

# Detect Fedora / Atomic
if [[ ! -f /etc/os-release ]]; then
  die "Cannot detect OS (/etc/os-release missing)"
fi
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "fedora" ]] || die "Unsupported OS '${ID:-unknown}'. Version 1 supports Fedora only."

ATOMIC=0
if [[ -e /run/ostree-booted ]]; then
  ATOMIC=1
  log "Detected Fedora Atomic Desktop"
else
  log "Detected package-based Fedora ${VERSION_ID:-unknown}"
fi

command -v python3 >/dev/null 2>&1 || die "python3 is required on the controller"
PYTHON_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
python3 - <<'PY' || die "Python >= 3.12 is required for pinned ansible-core 2.21.x"
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
log "Using Python ${PYTHON_VERSION}"

command -v python3 >/dev/null
if ! python3 -c 'import venv' 2>/dev/null; then
  if ((ATOMIC)); then
    die "Python venv module missing. On Atomic, layer python3-pip/python3 and reboot, or ensure the venv stdlib is available."
  fi
  die "Python venv module is unavailable"
fi

log "Creating or updating virtualenv at ${VENV_DIR}"
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
python -m pip install --upgrade pip setuptools wheel
log "Installing pinned controller requirements"
python -m pip install -r "${REQUIREMENTS_CONTROLLER}"

mkdir -p "${COLLECTIONS_PATH}"
export ANSIBLE_COLLECTIONS_PATH="${COLLECTIONS_PATH}${ANSIBLE_COLLECTIONS_PATH:+:${ANSIBLE_COLLECTIONS_PATH}}"
log "Installing pinned Ansible collections into ${COLLECTIONS_PATH}"
ansible-galaxy collection install -r "${REQUIREMENTS_GALAXY}" -p "${COLLECTIONS_PATH}" --force

log "Controller bootstrap complete"
ansible --version | head -n 1
ansible-galaxy collection list 2>/dev/null | grep -E 'ansible.posix|community.general' || true

if ((SKIP_PLAYBOOK)); then
  log "Skipping playbook as requested"
  exit 0
fi

cd "${ROOT_DIR}"
ANSIBLE_ARGS=(
  ansible-playbook
  "${PLAYBOOK}"
  -e "airvpn_config_source=${CONFIG_SOURCE}"
)
if ((CHECK_MODE)); then
  ANSIBLE_ARGS+=(--check --diff)
  log "Running install playbook in check mode"
else
  log "Running install playbook (live)"
fi
if ((${#EXTRA_ANSIBLE_ARGS[@]} > 0)); then
  ANSIBLE_ARGS+=("${EXTRA_ANSIBLE_ARGS[@]}")
fi

# Prefer system Python on the managed host for firewalld bindings.
ANSIBLE_ARGS+=(-e "ansible_python_interpreter=/usr/bin/python3")

log "Command: ${ANSIBLE_ARGS[*]}"
"${ANSIBLE_ARGS[@]}"
log "Bootstrap finished successfully"
log "Next: sudo airvpn-check --offline && sudo airvpn-switch"
