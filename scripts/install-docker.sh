#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n==> $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Run as root (or with sudo)." >&2
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
    echo "Tip: Ensure the VM is created with this adminUsername before running the script." >&2
    exit 1
  fi
}

need_root
export DEBIAN_FRONTEND=noninteractive

# ----------------------------
# Input: admin username from ARM param
# ----------------------------
ADMIN_USER="${1:-}"
if [[ -z "${ADMIN_USER}" ]]; then
  echo "ERROR: Missing admin username argument." >&2
  echo "Usage: $0 <adminUsername>" >&2
  exit 1
fi

ensure_user_exists "${ADMIN_USER}"

log "Waiting for apt locks (Azure provisioning safety)..."
wait_for_apt_locks

log "Installing prerequisites..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

# ----------------------------
# Docker install (idempotent)
# ----------------------------
if command -v docker >/dev/null 2>&1; then
  log "Docker already installed: $(docker --version)"
else
  log "Preparing Docker apt repo keyring..."
  install -m 0755 -d /etc/apt/keyrings

  # Fix possible Signed-By conflicts (docker.asc vs docker.gpg)
  if grep -R "download.docker.com/linux/ubuntu" /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -q "signed-by=/etc/apt/keyrings/docker.asc"; then
    log "Found docker.asc Signed-By reference -> normalizing to docker.gpg..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    sed -i 's#/etc/apt/keyrings/docker\.asc#/etc/apt/keyrings/docker.gpg#g' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null || true
  fi

  # Create/refresh docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  log "Adding Docker apt repository..."
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  log "Updating apt and installing Docker Engine + Compose plugin..."
  wait_for_apt_locks
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

log "Enabling and starting Docker..."
systemctl enable --now docker

# ----------------------------
# Add admin user to docker group
# ----------------------------
log "Adding user '${ADMIN_USER}' to docker group (if not already)..."
if getent group docker >/dev/null 2>&1; then
  if id -nG "${ADMIN_USER}" | grep -qw docker; then
    log "User '${ADMIN_USER}' is already in docker group."
  else
    usermod -aG docker "${ADMIN_USER}"
    log "Added '${ADMIN_USER}' to docker group."
  fi
else
  echo "ERROR: docker group not found (Docker install may have failed)." >&2
  exit 1
fi

log "Installed versions:"
docker --version
docker compose version

log "Done."
echo "NOTE: Group membership takes effect on the user's next login."
