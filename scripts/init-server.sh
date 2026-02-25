#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Settings
# ----------------------------
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"

REPO_URL="https://github.com/VirtualNetLab/gns3-virtual-network-lab.git"
REPO_DIR="${TARGET_HOME}/gns3-virtual-network-lab"

SCRIPTS_DIR="${REPO_DIR}/scripts"
LABNET_SCRIPT="${SCRIPTS_DIR}/create-labnet.sh"

GNS3_COMPOSE_DIR="${REPO_DIR}/docker/gns3"
WG_COMPOSE_DIR="${REPO_DIR}/docker/wireguard-stack"

# ----------------------------
# Helpers
# ----------------------------
log() { echo -e "\n==> $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Aja tämä scripti rootina tai sudolla: sudo $0" >&2
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------
# Main
# ----------------------------
need_root

log "Päivitetään pakettilistat ja perusriippuvuudet..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release git

# --- Docker install (only if missing) ---
if command_exists docker; then
  log "Docker löytyy jo: $(docker --version)"
else
  log "Docker puuttuu -> asennetaan Docker (repo + gpg + paketit)..."

  install -m 0755 -d /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  else
    log "Docker GPG-avain on jo olemassa, ohitetaan."
  fi

  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
  else
    log "Docker apt-repo on jo olemassa, ohitetaan."
  fi

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
fi

# --- Docker service up ---
if systemctl is-active --quiet docker; then
  log "Docker-palvelu on käynnissä."
else
  log "Käynnistetään Docker-palvelu..."
  systemctl enable --now docker
fi

# --- Add invoking user to docker group (if not already) ---
# If running via sudo, use SUDO_USER as the target; else use current user.

if id -nG "${TARGET_USER}" | grep -qw docker; then
  log "User ${TARGET_USER} on jo docker-ryhmässä."
else
  log "Lisätään user ${TARGET_USER} docker-ryhmään..."
  usermod -aG docker "${TARGET_USER}"
fi

# --- Clone / update repo ---
log "Haetaan GNS3 lab repo..."
if [[ -d "${REPO_DIR}/.git" ]]; then
  log "Repo löytyy jo (${REPO_DIR}) -> git pull"
  sudo -u "${TARGET_USER}" git -C "${REPO_DIR}" pull
elif [[ -d "${REPO_DIR}" ]]; then
  log "Kansio ${REPO_DIR} löytyy mutta ei näytä git-repolta -> EI kloonata päälle. Poista/siirrä kansio jos haluat kloonata uudestaan."
else
  sudo -u "${TARGET_USER}" git clone "${REPO_URL}" "${REPO_DIR}"
fi

# --- Create labnet (script must be executable) ---
log "Luodaan/tarkistetaan labnet..."
if [[ -f "${LABNET_SCRIPT}" ]]; then
  chmod +x "${LABNET_SCRIPT}"
  sudo -u "${TARGET_USER}" bash -lc "cd '${SCRIPTS_DIR}' && ./create-labnet.sh"
else
  echo "ERROR: Labnet-scriptiä ei löydy: ${LABNET_SCRIPT}" >&2
  exit 1
fi

# --- Start compose stacks ---

log "Käynnistetään WireGuard stack..."
if [[ -f "${WG_COMPOSE_DIR}/compose.yaml" || -f "${WG_COMPOSE_DIR}/docker-compose.yml" || -f "${WG_COMPOSE_DIR}/docker-compose.yaml" ]]; then
  sudo -u "${TARGET_USER}" bash -lc "cd '${WG_COMPOSE_DIR}' && docker compose up -d"
else
  echo "ERROR: Compose-tiedostoa ei löydy kansiosta: ${WG_COMPOSE_DIR}" >&2
  exit 1
fi

log "Käynnistetään GNS3 stack..."
if [[ -f "${GNS3_COMPOSE_DIR}/compose.yaml" || -f "${GNS3_COMPOSE_DIR}/docker-compose.yml" || -f "${GNS3_COMPOSE_DIR}/docker-compose.yaml" ]]; then
  sudo -u "${TARGET_USER}" bash -lc "cd '${GNS3_COMPOSE_DIR}' && docker compose up -d"
else
  echo "ERROR: Compose-tiedostoa ei löydy kansiosta: ${GNS3_COMPOSE_DIR}" >&2
  exit 1
fi

log "Setup valmis!"
echo "HUOM: Jos lisättiin docker-ryhmään (${TARGET_USER}), kirjaudu ulos ja takaisin sisään (tai aja: newgrp docker) jotta ryhmämuutos astuu voimaan."
