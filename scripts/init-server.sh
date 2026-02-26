#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (CSE runs as root)." >&2
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
  # Run command as login shell for correct HOME/PATH in CSE context
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

# Ensure git exists (small dependency; safe in CSE)
log "Ensuring git is installed..."
wait_for_apt_locks
apt-get update -y
apt-get install -y git

# Ensure docker exists + daemon running
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found. Install Docker first (previous script)." >&2
  exit 1
fi

log "Ensuring Docker service is running..."
systemctl enable --now docker

# Paths
USER_HOME="$(getent passwd "${ADMIN_USER}" | cut -d: -f6)"
REPO_URL="https://github.com/VirtualNetLab/gns3-virtual-network-lab.git"
REPO_DIR="${USER_HOME}/gns3-virtual-network-lab"

WG_DIR="${REPO_DIR}/docker/wireguard-stack"
GNS3_DIR="${REPO_DIR}/docker/gns3"

# Clone or update repo (as the user)
log "Cloning/updating repo to ${REPO_DIR} ..."
if [[ -d "${REPO_DIR}/.git" ]]; then
  run_as_user "${ADMIN_USER}" "git -C '${REPO_DIR}' pull"
elif [[ -d "${REPO_DIR}" ]]; then
  echo "ERROR: ${REPO_DIR} exists but is not a git repo. Move/delete it." >&2
  exit 1
else
  run_as_user "${ADMIN_USER}" "git clone '${REPO_URL}' '${REPO_DIR}'"
fi

# Create docker network labnet (idempotent)
log "Ensuring Docker network 'labnet' exists..."
if docker network inspect labnet >/dev/null 2>&1; then
  log "Network labnet already exists."
else
  # Create as the admin user (requires docker group membership, set by previous script)
  run_as_user "${ADMIN_USER}" "docker network create labnet"
  log "Created network labnet."
fi

# Start WireGuard first
log "Starting WireGuard stack (first)..."
if [[ ! -d "${WG_DIR}" ]]; then
  echo "ERROR: WireGuard directory not found: ${WG_DIR}" >&2
  exit 1
fi

# Verify compose file exists
if [[ -f "${WG_DIR}/compose.yaml" || -f "${WG_DIR}/docker-compose.yml" || -f "${WG_DIR}/docker-compose.yaml" ]]; then
  run_as_user "${ADMIN_USER}" "cd '${WG_DIR}' && docker compose up -d"
else
  echo "ERROR: Compose file not found in: ${WG_DIR}" >&2
  exit 1
fi

# Then start GNS3
log "Starting GNS3 stack (second)..."
if [[ ! -d "${GNS3_DIR}" ]]; then
  echo "ERROR: GNS3 directory not found: ${GNS3_DIR}" >&2
  exit 1
fi

if [[ -f "${GNS3_DIR}/compose.yaml" || -f "${GNS3_DIR}/docker-compose.yml" || -f "${GNS3_DIR}/docker-compose.yaml" ]]; then
  run_as_user "${ADMIN_USER}" "cd '${GNS3_DIR}' && docker compose up -d"
else
  echo "ERROR: Compose file not found in: ${GNS3_DIR}" >&2
  exit 1
fi

log "Done."
echo "Repo: ${REPO_DIR}"
echo "WireGuard: started"
echo "GNS3: started"
