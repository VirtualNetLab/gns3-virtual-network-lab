#!/usr/bin/env bash
set -euo pipefail
 
# Install runtime deps if Debian/Ubuntu base
#if command -v apt-get >/dev/null 2>&1; then
#  apt-get update
#  DEBIAN_FRONTEND=noninteractive apt-get install -y iproute2 iptables dnsmasq >/dev/null
#fi
 
/usr/local/bin/init-tap.sh
 
# Start GNS3 server (keep container alive)
exec gns3server --host 0.0.0.0 --port 3080 --config /etc/gns3/gns3_server.conf
