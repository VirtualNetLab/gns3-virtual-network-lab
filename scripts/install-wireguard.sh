#!/usr/bin/env bash
set -euo pipefail

WG_SUBNET="${1:-10.8.0.0/24}"
VNET_PREFIX="${2:-10.10.0.0/16}"
WG_PORT="${3:-51820}"
SCRIPT_BASE_URL="${4:-}"

WG_ADDR="${WG_SUBNET%0/24}1/24"
WG_NET_CIDR="${WG_SUBNET}"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y wireguard iptables

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

DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"

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
EOF

echo "WireGuard installation complete"
cat /var/lib/wireguard/wireguard-info.txt

PEER_SCRIPT_URL="${SCRIPT_BASE_URL}/wireguard-add-peers.sh"
PEER_SCRIPT_PATH="/usr/local/sbin/wireguard-add-peers.sh"

echo "Downloading peer management script from ${PEER_SCRIPT_URL}"

curl -fsSL "${PEER_SCRIPT_URL}" -o "${PEER_SCRIPT_PATH}"

chmod 755 "${PEER_SCRIPT_PATH}"

echo "wireguard-add-peers.sh installed at ${PEER_SCRIPT_PATH}"
