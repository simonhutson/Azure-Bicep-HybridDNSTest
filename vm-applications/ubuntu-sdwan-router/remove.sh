#!/usr/bin/env bash
set -euo pipefail

rm -f /etc/sysctl.d/99-sdwan-router-appliance.conf
sysctl --system || true
rm -rf /opt/sdwan-router-appliance

echo 'Ubuntu SD-WAN/router appliance marker and sysctl configuration removed. Installed packages were left in place.'