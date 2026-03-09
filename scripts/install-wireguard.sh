#!/usr/bin/env bash
set -euo pipefail


WG_SUBNET="${1:-10.8.0.0/24}"
VNET_PREFIX="${2:-10.10.0.0/16}"
WG_PORT="${3:-51820}"
SCRIPT_BASE_URL="${4:-}"
STORAGE_ACCOUNT_NAME="${5:-}"
FILE_SHARE_NAME="${6:-wireguard}"
STORAGE_ACCOUNT_KEY="${7:-}"
PUBLIC_ENDPOINT="${8:-}"

if ! printf '%s' "${WG_SUBNET}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.0/24$'; then
  echo "ERROR: WG_SUBNET must be in x.x.x.0/24 format, got: ${WG_SUBNET}" >&2
  exit 1
fi

WG_ADDR="${WG_SUBNET%0/24}1/24"
WG_NET_CIDR="${WG_SUBNET}"
WG_NETWORK_BASE="${WG_SUBNET%.*/*}"
WIREGUARD_ENV_FILE="/etc/wireguard/wireguard.env"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wireguard iptables cifs-utils curl ca-certificates

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

if [ ! -f /etc/wireguard/server_private.key ]; then
  umask 077
  wg genkey > /etc/wireguard/server_private.key
fi

SERVER_PRIVATE_KEY="$(cat /etc/wireguard/server_private.key)"
SERVER_PUBLIC_KEY="$(printf '%s' "${SERVER_PRIVATE_KEY}" | wg pubkey)"

printf '%s\n' "${SERVER_PUBLIC_KEY}" > /etc/wireguard/server_public.key
chmod 600 /etc/wireguard/server_private.key
chmod 644 /etc/wireguard/server_public.key

cat > "${WIREGUARD_ENV_FILE}" <<EOF
WG_SUBNET=${WG_SUBNET}
WG_ADDR=${WG_ADDR}
WG_NETWORK_BASE=${WG_NETWORK_BASE}
WG_SERVER_ENDPOINT=${PUBLIC_ENDPOINT}
VNET_PREFIX=${VNET_PREFIX}
WG_PORT=${WG_PORT}
SERVER_PUBLIC_KEY_FILE=/etc/wireguard/server_public.key
WG_CONF=/etc/wireguard/wg0.conf
WG_DIR=/etc/wireguard
LOCAL_CLIENT_DIR=/etc/wireguard/clients
SHARE_ROOT=/mnt/wireguard-share
SHARE_INPUT_DIR=/mnt/wireguard-share/input
SHARE_CONFIG_DIR=/mnt/wireguard-share/configs
SHARE_LOG_DIR=/mnt/wireguard-share/logs
EOF

chmod 600 "${WIREGUARD_ENV_FILE}"

DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"

if [ -z "${DEFAULT_IF}" ]; then
  echo "ERROR: Could not determine default network interface" >&2
  exit 1
fi

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

PostUp = sysctl -w net.ipv4.ip_forward=1
PostUp = iptables -A FORWARD -i wg0 -d ${VNET_PREFIX} -j ACCEPT
PostUp = iptables -A FORWARD -o wg0 -s ${VNET_PREFIX} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostUp = iptables -A FORWARD -i wg0 -j DROP
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET_CIDR} -d ${VNET_PREFIX} -o ${DEFAULT_IF} -j MASQUERADE

PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET_CIDR} -d ${VNET_PREFIX} -o ${DEFAULT_IF} -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j DROP
PostDown = iptables -D FORWARD -o wg0 -s ${VNET_PREFIX} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -d ${VNET_PREFIX} -j ACCEPT
EOF

chmod 600 /etc/wireguard/wg0.conf

cat > /etc/sysctl.d/99-wireguard-ipforward.conf <<EOF
net.ipv4.ip_forward=1
EOF

sysctl --system

if [ -n "${STORAGE_ACCOUNT_NAME}" ] && [ -n "${FILE_SHARE_NAME}" ] && [ -n "${STORAGE_ACCOUNT_KEY}" ]; then
  mkdir -p /mnt/wireguard-share
  mkdir -p /etc/smbcredentials

  SMB_CREDENTIAL_FILE="/etc/smbcredentials/${STORAGE_ACCOUNT_NAME}.cred"

  cat > "${SMB_CREDENTIAL_FILE}" <<EOF
username=${STORAGE_ACCOUNT_NAME}
password=${STORAGE_ACCOUNT_KEY}
EOF

  chmod 600 "${SMB_CREDENTIAL_FILE}"

  if ! grep -q "/mnt/wireguard-share" /etc/fstab; then
    echo "//${STORAGE_ACCOUNT_NAME}.file.core.windows.net/${FILE_SHARE_NAME} /mnt/wireguard-share cifs nofail,credentials=${SMB_CREDENTIAL_FILE},dir_mode=0700,file_mode=0600,serverino,nosharesock,actimeo=30,mfsymlinks,vers=3.0 0 0" >> /etc/fstab
  fi

  mount /mnt/wireguard-share
  mountpoint -q /mnt/wireguard-share || {
    echo "ERROR: Azure Files share mount failed" >&2
    exit 1
  }

  mkdir -p /mnt/wireguard-share/input
  mkdir -p /mnt/wireguard-share/configs
  mkdir -p /mnt/wireguard-share/logs
fi

systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0

mkdir -p /var/lib/wireguard
chmod 755 /var/lib/wireguard

cat > /var/lib/wireguard/wireguard-info.txt <<EOF
WireGuard installation complete

Server public key:
${SERVER_PUBLIC_KEY}

Server listen port:
${WG_PORT}

WireGuard subnet:
${WG_NET_CIDR}

Azure VNet reachable through tunnel:
${VNET_PREFIX}

Azure Files storage account:
${STORAGE_ACCOUNT_NAME}

Azure Files share:
${FILE_SHARE_NAME}

Azure Files mount path:
 /mnt/wireguard-share
EOF

echo "WireGuard installation complete"
cat /var/lib/wireguard/wireguard-info.txt

PEER_SCRIPT_URL="${SCRIPT_BASE_URL}/wireguard-add-peers.sh"
PEER_SCRIPT_PATH="/usr/local/sbin/wireguard-add-peers.sh"

echo "Downloading peer management script from ${PEER_SCRIPT_URL}"

curl -fsSL "${PEER_SCRIPT_URL}" -o "${PEER_SCRIPT_PATH}"

chmod 755 "${PEER_SCRIPT_PATH}"

echo "wireguard-add-peers.sh installed at ${PEER_SCRIPT_PATH}"

if [ -n "${STORAGE_ACCOUNT_NAME}" ] && [ -n "${FILE_SHARE_NAME}" ]; then
  echo "Azure Files share mounted at /mnt/wireguard-share"
  echo "Put users.csv in /mnt/wireguard-share/input/users.csv"
fi
