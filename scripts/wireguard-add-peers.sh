#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash wireguard-add-peers.sh users.csv PUBLIC_ENDPOINT
#
# Example:
#   sudo bash wireguard-add-peers.sh students.csv 20.74.83.219
#   sudo bash wireguard-add-peers.sh students.csv wg.example.com
#
# CSV format:
#   one email per row, for example:
#   tjsdd001@students.oamk.fi
#   tjsdd002@students.oamk.fi
#   teacher001@oamk.fi

CSV_FILE="${1:-}"
SERVER_ENDPOINT="${2:-}"

WG_CONF="/etc/wireguard/wg0.conf"
WG_DIR="/etc/wireguard"
CLIENT_DIR="${WG_DIR}/clients"
SERVER_PUBLIC_KEY_FILE="${WG_DIR}/server_public.key"
SERVER_PORT="51820"
WG_NETWORK_BASE="10.8.0"
SERVER_ADDRESS="10.8.0.1/24"
VNET_ALLOWED_IPS="10.10.0.0/16"

if [ -z "${CSV_FILE}" ] || [ -z "${SERVER_ENDPOINT}" ]; then
  echo "Usage: sudo bash wireguard-add-peers.sh users.csv PUBLIC_ENDPOINT" >&2
  exit 1
fi

if [ ! -f "${CSV_FILE}" ]; then
  echo "ERROR: CSV file not found: ${CSV_FILE}" >&2
  exit 1
fi

if [ ! -f "${WG_CONF}" ]; then
  echo "ERROR: WireGuard config not found: ${WG_CONF}" >&2
  exit 1
fi

if [ ! -f "${SERVER_PUBLIC_KEY_FILE}" ]; then
  echo "ERROR: Server public key file not found: ${SERVER_PUBLIC_KEY_FILE}" >&2
  exit 1
fi

mkdir -p "${CLIENT_DIR}"
chmod 700 "${CLIENT_DIR}"

SERVER_PUBLIC_KEY="$(cat "${SERVER_PUBLIC_KEY_FILE}")"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

sanitize_name() {
  local email="$1"
  printf '%s' "${email}" | tr '[:upper:]' '[:lower:]' | sed 's/@/_at_/g; s/[^a-z0-9._-]/_/g'
}

peer_exists() {
  local public_key="$1"
  grep -Fq "PublicKey = ${public_key}" "${WG_CONF}"
}

email_block_exists() {
  local email="$1"
  grep -Fq "# user: ${email}" "${WG_CONF}"
}

next_free_ip() {
  local used_ips
  used_ips="$(grep -E 'AllowedIPs = 10\.8\.0\.[0-9]+/32' "${WG_CONF}" | sed -E 's/.*AllowedIPs = (10\.8\.0\.([0-9]+))\/32/\2/' || true)"

  for host in $(seq 2 254); do
    if ! printf '%s\n' "${used_ips}" | grep -qx "${host}"; then
      echo "${WG_NETWORK_BASE}.${host}"
      return 0
    fi
  done

  echo "ERROR: No free IPs left in ${WG_NETWORK_BASE}.0/24" >&2
  exit 1
}

append_peer_to_wgconf() {
  local email="$1"
  local client_public_key="$2"
  local client_ip="$3"

  cat >> "${WG_CONF}" <<EOF

# user: ${email}
[Peer]
PublicKey = ${client_public_key}
AllowedIPs = ${client_ip}/32
EOF
}

create_client_config() {
  local email="$1"
  local client_private_key="$2"
  local client_ip="$3"
  local out_file="$4"

  cat > "${out_file}" <<EOF
[Interface]
PrivateKey = ${client_private_key}
Address = ${client_ip}/24

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_ENDPOINT}:${SERVER_PORT}
AllowedIPs = ${VNET_ALLOWED_IPS}
EOF

  chmod 600 "${out_file}"
}

TMP_REPORT="$(mktemp)"
trap 'rm -f "${TMP_REPORT}"' EXIT

echo "Processing users from ${CSV_FILE}"

while IFS= read -r raw_line || [ -n "${raw_line}" ]; do
  line="$(trim "${raw_line}")"

  if [ -z "${line}" ]; then
    continue
  fi

  if printf '%s' "${line}" | grep -Eq '^[[:space:]]*#'; then
    continue
  fi

  email="$(printf '%s' "${line}" | tr '[:upper:]' '[:lower:]')"

  if ! printf '%s' "${email}" | grep -Eq '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'; then
    echo "Skipping invalid email: ${email}" | tee -a "${TMP_REPORT}"
    continue
  fi

  safe_name="$(sanitize_name "${email}")"
  private_key_file="${CLIENT_DIR}/${safe_name}.key"
  public_key_file="${CLIENT_DIR}/${safe_name}.pub"
  conf_file="${CLIENT_DIR}/${safe_name}.conf"

  if email_block_exists "${email}"; then
    echo "User already exists in wg0.conf, skipping: ${email}" | tee -a "${TMP_REPORT}"
    continue
  fi

  if [ -f "${private_key_file}" ] && [ -f "${public_key_file}" ]; then
    client_private_key="$(cat "${private_key_file}")"
    client_public_key="$(cat "${public_key_file}")"
  else
    umask 077
    wg genkey | tee "${private_key_file}" | wg pubkey > "${public_key_file}"
    client_private_key="$(cat "${private_key_file}")"
    client_public_key="$(cat "${public_key_file}")"
    chmod 600 "${private_key_file}"
    chmod 600 "${public_key_file}"
  fi

  if peer_exists "${client_public_key}"; then
    echo "Public key already exists in wg0.conf, skipping: ${email}" | tee -a "${TMP_REPORT}"
    continue
  fi

  client_ip="$(next_free_ip)"

  append_peer_to_wgconf "${email}" "${client_public_key}" "${client_ip}"
  create_client_config "${email}" "${client_private_key}" "${client_ip}" "${conf_file}"

  echo "Added ${email} -> ${client_ip} -> ${conf_file}" | tee -a "${TMP_REPORT}"
done < "${CSV_FILE}"

chmod 600 "${WG_CONF}"

wg-quick strip wg0 >/dev/null 2>&1 || true
systemctl restart wg-quick@wg0
systemctl --no-pager --full status wg-quick@wg0 || true

echo
echo "Summary:"
cat "${TMP_REPORT}"
echo
echo "Client configs are in: ${CLIENT_DIR}"
