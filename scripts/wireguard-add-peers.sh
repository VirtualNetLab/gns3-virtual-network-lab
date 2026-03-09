#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   sudo bash wireguard-add-peers.sh [users.csv] PUBLIC_ENDPOINT
#
# Examples:
#   sudo bash wireguard-add-peers.sh /mnt/wireguard-share/input/users.csv 20.74.83.219
#   sudo bash wireguard-add-peers.sh users.csv wg.example.com
#
# If the CSV path is omitted, default is:
#   /mnt/wireguard-share/input/users.csv
#
# CSV format:
#   one email per row, for example:
#   tjsdd001@students.oamk.fi
#   tjsdd002@students.oamk.fi
#   teacher001@oamk.fi

WIREGUARD_ENV_FILE="/etc/wireguard/wireguard.env"

if [ ! -f "${WIREGUARD_ENV_FILE}" ]; then
  echo "ERROR: WireGuard env file not found: ${WIREGUARD_ENV_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1091
source "${WIREGUARD_ENV_FILE}"

WG_CONF="${WG_CONF:-/etc/wireguard/wg0.conf}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
LOCAL_CLIENT_DIR="${LOCAL_CLIENT_DIR:-${WG_DIR}/clients}"
SERVER_PUBLIC_KEY_FILE="${SERVER_PUBLIC_KEY_FILE:-${WG_DIR}/server_public.key}"

SHARE_ROOT="${SHARE_ROOT:-/mnt/wireguard-share}"
SHARE_INPUT_DIR="${SHARE_INPUT_DIR:-${SHARE_ROOT}/input}"
SHARE_CONFIG_DIR="${SHARE_CONFIG_DIR:-${SHARE_ROOT}/configs}"
SHARE_LOG_DIR="${SHARE_LOG_DIR:-${SHARE_ROOT}/logs}"

SERVER_PORT="${WG_PORT:-51820}"
WG_NETWORK_BASE="${WG_NETWORK_BASE:?WG_NETWORK_BASE missing from ${WIREGUARD_ENV_FILE}}"
VNET_ALLOWED_IPS="${VNET_PREFIX:?VNET_PREFIX missing from ${WIREGUARD_ENV_FILE}}"

DEFAULT_CSV_FILE="${SHARE_INPUT_DIR}/users.csv"

if [ "$#" -eq 1 ]; then
  CSV_FILE="${DEFAULT_CSV_FILE}"
  SERVER_ENDPOINT="${1}"
elif [ "$#" -eq 2 ]; then
  CSV_FILE="${1}"
  SERVER_ENDPOINT="${2}"
else
  echo "Usage: sudo bash wireguard-add-peers.sh [users.csv] PUBLIC_ENDPOINT" >&2
  exit 1
fi

if [ -z "$(trim "${SERVER_ENDPOINT}")" ]; then
  echo "ERROR: PUBLIC_ENDPOINT is empty" >&2
  exit 1
fi

SUMMARY_FILE="${SHARE_LOG_DIR}/wireguard-peers-summary.csv"
TMP_REPORT="$(mktemp)"
trap 'rm -f "${TMP_REPORT}"' EXIT

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

mkdir -p "${LOCAL_CLIENT_DIR}"
chmod 700 "${LOCAL_CLIENT_DIR}"

if mountpoint -q "${SHARE_ROOT}"; then
  mkdir -p "${SHARE_INPUT_DIR}" "${SHARE_CONFIG_DIR}" "${SHARE_LOG_DIR}"
else
  echo "WARNING: ${SHARE_ROOT} is not mounted, generated configs will only be stored locally." | tee -a "${TMP_REPORT}"
  SHARE_CONFIG_DIR=""
  SHARE_LOG_DIR=""
  SUMMARY_FILE=""
fi

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
  local escaped_base used_ips

  escaped_base="$(printf '%s' "${WG_NETWORK_BASE}" | sed 's/\./\\./g')"

  used_ips="$(
    grep -E "AllowedIPs = ${escaped_base}\.[0-9]+/32" "${WG_CONF}" \
    | sed -E "s/.*AllowedIPs = ${escaped_base}\.([0-9]+)\/32/\1/" \
    || true
  )"

  for host in $(seq 2 254); do
    if ! printf '%s\n' "${used_ips}" | grep -qx "${host}"; then
      echo "${WG_NETWORK_BASE}.${host}"
      return 0
    fi
  done

  echo "ERROR: No free IPs left in ${WG_SUBNET}" >&2
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
  local client_private_key="$1"
  local client_ip="$2"
  local out_file="$3"

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

copy_to_share_if_available() {
  local src_file="$1"
  local dst_file="$2"

  if [ -n "${SHARE_CONFIG_DIR}" ]; then
    cp -f "${src_file}" "${dst_file}"
    chmod 600 "${dst_file}"
  fi
}

write_summary_header_if_needed() {
  if [ -n "${SUMMARY_FILE}" ] && [ ! -f "${SUMMARY_FILE}" ]; then
    echo "email,client_ip,local_conf,share_conf" > "${SUMMARY_FILE}"
    chmod 600 "${SUMMARY_FILE}"
  fi
}

write_summary_line() {
  local email="$1"
  local client_ip="$2"
  local local_conf="$3"
  local share_conf="$4"

  if [ -n "${SUMMARY_FILE}" ]; then
    echo "${email},${client_ip},${local_conf},${share_conf}" >> "${SUMMARY_FILE}"
  fi
}

write_summary_header_if_needed

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
  private_key_file="${LOCAL_CLIENT_DIR}/${safe_name}.key"
  public_key_file="${LOCAL_CLIENT_DIR}/${safe_name}.pub"
  local_conf_file="${LOCAL_CLIENT_DIR}/${safe_name}.conf"
  share_conf_file=""
  if [ -n "${SHARE_CONFIG_DIR}" ]; then
    share_conf_file="${SHARE_CONFIG_DIR}/${safe_name}.conf"
  fi

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
    chmod 600 "${private_key_file}" "${public_key_file}"
  fi

  if peer_exists "${client_public_key}"; then
    echo "Public key already exists in wg0.conf, skipping: ${email}" | tee -a "${TMP_REPORT}"
    continue
  fi

  client_ip="$(next_free_ip)"

  append_peer_to_wgconf "${email}" "${client_public_key}" "${client_ip}"
  create_client_config "${client_private_key}" "${client_ip}" "${local_conf_file}"

  if [ -n "${share_conf_file}" ]; then
    copy_to_share_if_available "${local_conf_file}" "${share_conf_file}"
  fi

  write_summary_line "${email}" "${client_ip}" "${local_conf_file}" "${share_conf_file}"

  echo "Added ${email} -> ${client_ip} -> ${local_conf_file}${share_conf_file:+ -> ${share_conf_file}}" | tee -a "${TMP_REPORT}"
done < "${CSV_FILE}"

chmod 600 "${WG_CONF}"

systemctl restart wg-quick@wg0
systemctl --no-pager --full status wg-quick@wg0 || true

echo
echo "Summary:"
cat "${TMP_REPORT}"
echo
echo "Local client configs are in: ${LOCAL_CLIENT_DIR}"

if [ -n "${SHARE_CONFIG_DIR}" ]; then
  echo "Shared client configs are in: ${SHARE_CONFIG_DIR}"
fi

if [ -n "${SUMMARY_FILE}" ]; then
  echo "Summary CSV: ${SUMMARY_FILE}"
fi
