#!/usr/bin/env bash
set -euo pipefail

CSV="/mnt/wireguard-share/input/users.csv"
HASH_FILE="/var/lib/wireguard/users.csv.sha256"
PEER_SCRIPT="/usr/local/sbin/wireguard-add-peers.sh"

if [ ! -f "${CSV}" ]; then
  exit 0
fi

mkdir -p /var/lib/wireguard

NEW_HASH="$(sha256sum "${CSV}" | awk '{print $1}')"

if [ -f "${HASH_FILE}" ]; then
  OLD_HASH="$(cat "${HASH_FILE}")"
else
  OLD_HASH=""
fi

if [ "${NEW_HASH}" != "${OLD_HASH}" ]; then
  echo "users.csv changed, running wireguard-add-peers.sh"
  "${PEER_SCRIPT}"
  echo "${NEW_HASH}" > "${HASH_FILE}"
fi
