#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (Azure CSE runs as root)." >&2
    exit 1
  fi
}

wait_for_apt_locks() {
  while \
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
    fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
    fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
    log "Waiting for apt/dpkg locks..."
    sleep 5
  done
}

ensure_user_exists() {
  local u="$1"
  if ! id "${u}" >/dev/null 2>&1; then
    echo "ERROR: User '${u}' does not exist on this VM (yet)." >&2
    exit 1
  fi
}

run_as_user() {
  local u="$1"
  shift
  sudo -u "${u}" bash -lc "$*"
}

need_root

ADMIN_USER="${1:-}"
if [[ -z "${ADMIN_USER}" ]]; then
  echo "ERROR: Missing admin username argument." >&2
  echo "Usage: $0 <adminUsername>" >&2
  exit 1
fi
ensure_user_exists "${ADMIN_USER}"

log "Ensuring git is installed..."
wait_for_apt_locks
apt-get update -y
apt-get install -y git

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. Install Docker first." >&2
  exit 1
fi

log "Ensuring Docker service is running..."
systemctl enable --now docker

USER_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
REPO_URL="https://github.com/VirtualNetLab/gns3-virtual-network-lab.git"
REPO_DIR="${USER_HOME}/gns3-virtual-network-lab"

LABNET_SCRIPT="${REPO_DIR}/scripts/create-labnet.sh"
GNS3_DIR="${REPO_DIR}/docker/gns3"

log "Cloning/updating repo to ${REPO_DIR} ..."
if [[ -d "${REPO_DIR}/.git" ]]; then
  run_as_user "${ADMIN_USER}" "git -C '${REPO_DIR}' pull"
elif [[ -d "${REPO_DIR}" ]]; then
  echo "ERROR: ${REPO_DIR} exists but is not a git repo. Move/delete it." >&2
  exit 1
else
  run_as_user "${ADMIN_USER}" "git clone '${REPO_URL}' '${REPO_DIR}'"
fi

chown -R "${ADMIN_USER}:${ADMIN_USER}" "${REPO_DIR}" || true

log "Creating labnet via ${LABNET_SCRIPT} ..."
if [[ -f "${LABNET_SCRIPT}" ]]; then
  chmod +x "${LABNET_SCRIPT}"
  bash "${LABNET_SCRIPT}"
else
  echo "ERROR: Labnet script not found: ${LABNET_SCRIPT}" >&2
  exit 1
fi

log "Building GNS3 image only..."
if [[ -f "${GNS3_DIR}/compose.yaml" || -f "${GNS3_DIR}/docker-compose.yml" || -f "${GNS3_DIR}/docker-compose.yaml" ]]; then
  cd "${GNS3_DIR}"
  docker compose build
else
  echo "ERROR: Compose file not found in: ${GNS3_DIR}" >&2
  exit 1
fi

chown -R "${ADMIN_USER}:${ADMIN_USER}" "${REPO_DIR}" || true

log "Done."
echo "Repo: ${REPO_DIR}"
echo "labnet: created/ensured via scripts/create-labnet.sh"
echo "GNS3 image: built only"
