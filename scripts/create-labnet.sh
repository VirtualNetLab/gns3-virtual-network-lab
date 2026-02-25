#!/usr/bin/env bash
set -euo pipefail

# Create a Docker bridge network for GNS3 lab containers.
# Idempotent: if it exists, it verifies settings and exits.

NETWORK_NAME="${1:-labnet}"

# You can change these if you want a different lab subnet
SUBNET="${LABNET_SUBNET:-172.30.0.0/24}"
GATEWAY="${LABNET_GATEWAY:-172.30.0.1}"

# Optional: set to true if you want to allow containers on labnet to reach the internet via host NAT
# (Docker already NATs bridge networks by default; this is mainly for clarity)
ENABLE_MASQ="${LABNET_ENABLE_MASQ:-true}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
need docker

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon not reachable. Are you in the docker group or using sudo?" >&2
  echo "Try: sudo $0" >&2
  exit 1
fi

exists_id="$(docker network ls --filter "name=^${NETWORK_NAME}$" -q || true)"

if [[ -n "$exists_id" ]]; then
  # Verify existing config
  existing_subnet="$(docker network inspect "$NETWORK_NAME" \
    --format '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)"
  existing_gateway="$(docker network inspect "$NETWORK_NAME" \
    --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"

  echo "Network '$NETWORK_NAME' already exists (id: $exists_id)"
  echo "  Subnet : ${existing_subnet:-<unknown>}"
  echo "  Gateway: ${existing_gateway:-<unknown>}"

  if [[ -n "$existing_subnet" && "$existing_subnet" != "$SUBNET" ]]; then
    echo "WARNING: Existing subnet differs from desired SUBNET=$SUBNET" >&2
    echo "If you need to change it, you must remove & recreate the network:" >&2
    echo "  docker network rm $NETWORK_NAME" >&2
    echo "  $0 $NETWORK_NAME" >&2
  fi

  exit 0
fi

echo "Creating Docker network '$NETWORK_NAME'..."
docker network create \
  --driver bridge \
  --subnet "$SUBNET" \
  --gateway "$GATEWAY" \
  --attachable \
  "$NETWORK_NAME" >/dev/null

echo "Created:"
docker network inspect "$NETWORK_NAME" --format \
  '  Name: {{.Name}}
  ID: {{.Id}}
  Driver: {{.Driver}}
  Subnet: {{(index .IPAM.Config 0).Subnet}}
  Gateway: {{(index .IPAM.Config 0).Gateway}}'

if [[ "$ENABLE_MASQ" == "true" ]]; then
  echo "Note: Docker bridge networks are NATed by default (MASQUERADE via DOCKER rules)."
fi

echo "Done."
