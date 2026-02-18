#!/usr/bin/env bash
set -euo pipefail

# --- asetukset (samat kuin sulla) ---
TAP_IF="tap0"
BR_IF="virbr0"

BR_IP="10.0.0.1/24"
DHCP_START="10.0.0.100"
DHCP_END="10.0.0.200"
DHCP_LEASE="12h"
DNS1="1.1.1.1"
DNS2="8.8.8.8"
UPLINK_IF="eth0"
# ------------------------------------

# /dev/net/tun
if [ ! -e /dev/net/tun ]; then
  echo "ERROR: /dev/net/tun not present. Did you pass devices: /dev/net/tun ?" >&2
  exit 1
fi

# tap0 olemassa?
if ! ip link show "${TAP_IF}" >/dev/null 2>&1; then
  ip tuntap add dev "${TAP_IF}" mode tap
fi

# bridge virbr0 olemassa?
if ! ip link show "${BR_IF}" >/dev/null 2>&1; then
  ip link add name "${BR_IF}" type bridge
fi

# nollaa mahdolliset vanhat IP:t (tap0 ja virbr0)
ip -4 addr flush dev "${TAP_IF}" || true
ip -4 addr flush dev "${BR_IF}" || true

# liitä tap0 siltaan (virbr0)
# (jos oli jo masterissa, tämä ei haittaa)
ip link set "${TAP_IF}" master "${BR_IF}"

# IP sillalle
ip addr add "${BR_IP}" dev "${BR_IF}"

# ylös
ip link set "${TAP_IF}" up
ip link set "${BR_IF}" up

# Forwardointi päälle
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# NAT uplinkille (masquerade) — käytetään koko /24 lähdeverkkoa
SUBNET_CIDR="${BR_IP%.*}.0/24"   # 10.0.0.0/24 jos BR_IP=10.0.0.1/24

iptables -t nat -C POSTROUTING -s "${SUBNET_CIDR}" -o "${UPLINK_IF}" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s "${SUBNET_CIDR}" -o "${UPLINK_IF}" -j MASQUERADE

# Forward-säännöt (virbr0 <-> eth0)
iptables -C FORWARD -i "${BR_IF}" -o "${UPLINK_IF}" -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i "${BR_IF}" -o "${UPLINK_IF}" -j ACCEPT

iptables -C FORWARD -i "${UPLINK_IF}" -o "${BR_IF}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i "${UPLINK_IF}" -o "${BR_IF}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# dnsmasq config virbr0:lle
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/gns3-virbr0.conf <<EOC
interface=${BR_IF}
bind-interfaces
listen-address=${BR_IP%/*}
except-interface=${UPLINK_IF}

# DHCP pool for GNS3 lab clients on virbr0 (tap0 is port)
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,${DHCP_LEASE}

# Default gateway + DNS handed to clients
dhcp-option=3,${BR_IP%/*}
dhcp-option=6,${DNS1},${DNS2}

log-dhcp
EOC

# käynnistä dnsmasq uusiksi
pkill dnsmasq 2>/dev/null || true
dnsmasq --conf-file=/etc/dnsmasq.d/gns3-virbr0.conf

echo "OK:"
echo "  bridge up: ${BR_IF} (${BR_IP})"
echo "  port: ${TAP_IF} -> ${BR_IF}"
echo "  DHCP: ${DHCP_START}-${DHCP_END}"
echo "  NAT: ${SUBNET_CIDR} -> ${UPLINK_IF}"
