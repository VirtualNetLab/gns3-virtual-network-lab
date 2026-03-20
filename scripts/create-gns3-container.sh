#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash ./scripts/create-gns3-container.sh CONTAINER_NAME WG_IP
#
# Example:
#   sudo bash ./scripts/create-gns3-container.sh gns3-student10 10.9.0.10
#
# Result:
#   WG IP      10.9.0.10
#   Container  172.30.0.10

CONTAINER_NAME="${1:-}"
WG_IP="${2:-}"

if [ -z "${CONTAINER_NAME}" ] || [ -z "${WG_IP}" ]; then
  echo "Usage: sudo bash ./scripts/create-gns3-container.sh CONTAINER_NAME WG_IP" >&2
  exit 1
fi

# --- settings ---
NETWORK_NAME="${NETWORK_NAME:-labnet}"
GNS3_SUBNET_BASE="${GNS3_SUBNET_BASE:-172.30.0}"
GNS3_IMAGE="${GNS3_IMAGE:-gns3-server:latest}"
TZ_VALUE="${TZ_VALUE:-Europe/Helsinki}"
PUID_VALUE="${PUID_VALUE:-1000}"
PGID_VALUE="${PGID_VALUE:-1000}"
HOST_KVM="${HOST_KVM:-/dev/kvm}"
HOST_TUN="${HOST_TUN:-/dev/net/tun}"
# ----------------

# Resolve repository root from script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Docker/GNS3 host paths inside repo
GNS3_DOCKER_DIR="${REPO_ROOT}/docker/gns3"
HOST_INIT_TAP="${GNS3_DOCKER_DIR}/init-tap.sh"
HOST_START_GNS3="${GNS3_DOCKER_DIR}/start-gns3.sh"

# Per-container persistent directories
HOST_CONF_DIR="${GNS3_DOCKER_DIR}/instances/${CONTAINER_NAME}/conf"
HOST_GNS3_DIR="${GNS3_DOCKER_DIR}/instances/${CONTAINER_NAME}/GNS3"
HOST_SHARE_DIR="${GNS3_DOCKER_DIR}/instances/${CONTAINER_NAME}/share"

# Validate required files
if [ ! -f "${HOST_INIT_TAP}" ]; then
  echo "ERROR: Missing file: ${HOST_INIT_TAP}" >&2
  exit 1
fi

if [ ! -f "${HOST_START_GNS3}" ]; then
  echo "ERROR: Missing file: ${HOST_START_GNS3}" >&2
  exit 1
fi

# Validate required devices
if [ ! -e "${HOST_TUN}" ]; then
  echo "ERROR: Missing device: ${HOST_TUN}" >&2
  exit 1
fi

if [ ! -e "${HOST_KVM}" ]; then
  echo "WARNING: ${HOST_KVM} not found. QEMU/KVM acceleration may not work." >&2
fi

# Extract last octet from WireGuard IP
LAST_OCTET="$(printf '%s\n' "${WG_IP}" | awk -F'.' '{print $4}')"

if ! [[ "${LAST_OCTET}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: Could not parse last octet from WG IP: ${WG_IP}" >&2
  exit 1
fi

if [ "${LAST_OCTET}" -lt 2 ] || [ "${LAST_OCTET}" -gt 254 ]; then
  echo "ERROR: Last octet must be between 2 and 254, got ${LAST_OCTET}" >&2
  exit 1
fi

CONTAINER_IP="${GNS3_SUBNET_BASE}.${LAST_OCTET}"

# Validate Docker network exists
if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
  echo "ERROR: Docker network ${NETWORK_NAME} does not exist" >&2
  echo "Create it first, for example:" >&2
  echo "  docker network create --driver bridge --subnet ${GNS3_SUBNET_BASE}.0/24 --gateway ${GNS3_SUBNET_BASE}.1 ${NETWORK_NAME}" >&2
  exit 1
fi

# Check container name collision
if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  echo "ERROR: Container ${CONTAINER_NAME} already exists" >&2
  exit 1
fi

# Check whether IP already appears in network inspection
if docker network inspect "${NETWORK_NAME}" | grep -q "\"${CONTAINER_IP}\""; then
  echo "ERROR: IP ${CONTAINER_IP} already appears to be in use on network ${NETWORK_NAME}" >&2
  exit 1
fi

# Create host directories
mkdir -p "${HOST_CONF_DIR}" "${HOST_GNS3_DIR}" "${HOST_SHARE_DIR}"

# Optional default config creation
if [ ! -f "${HOST_CONF_DIR}/gns3_server.conf" ]; then
  cat > "${HOST_CONF_DIR}/gns3_server.conf" <<EOF
[Server]
host = 0.0.0.0
port = 3080
images_path = /root/GNS3/images
projects_path = /root/GNS3/projects

[Qemu]
enable_kvm = true

[Docker]
enable = true
EOF
fi

# Run container
docker run -d \
  --name "${CONTAINER_NAME}" \
  --hostname "${CONTAINER_NAME}" \
  --network "${NETWORK_NAME}" \
  --ip "${CONTAINER_IP}" \
  --device "${HOST_TUN}:${HOST_TUN}" \
  $( [ -e "${HOST_KVM}" ] && printf -- '--device %s:%s ' "${HOST_KVM}" "${HOST_KVM}" ) \
  --sysctl net.ipv4.ip_forward=1 \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  -e TZ="${TZ_VALUE}" \
  -e PUID="${PUID_VALUE}" \
  -e PGID="${PGID_VALUE}" \
  -v "${HOST_CONF_DIR}:/server/conf" \
  -v "${HOST_GNS3_DIR}:/root/GNS3" \
  -v "${HOST_SHARE_DIR}:/server/.local/share" \
  -v "${HOST_INIT_TAP}:/usr/local/bin/init-tap.sh:ro" \
  -v "${HOST_START_GNS3}:/usr/local/bin/start-gns3.sh:ro" \
  --entrypoint /usr/local/bin/start-gns3.sh \
  --restart unless-stopped \
  "${GNS3_IMAGE}"

echo "Created GNS3 container successfully"
echo "  Container name : ${CONTAINER_NAME}"
echo "  WireGuard IP   : ${WG_IP}"
echo "  Container IP   : ${CONTAINER_IP}"
echo "  Conf dir       : ${HOST_CONF_DIR}"
echo "  GNS3 dir       : ${HOST_GNS3_DIR}"
echo "  Share dir      : ${HOST_SHARE_DIR}"
