#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  frr \
  frr-pythontools \
  iproute2 \
  jq \
  nftables \
  strongswan \
  tcpdump \
  traceroute \
  wireguard

install -d -m 0755 /opt/sdwan-router-appliance

cat >/etc/sysctl.d/99-sdwan-router-appliance.conf <<'EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF

sysctl --system

for daemon in zebra bgpd staticd ospfd; do
  if grep -q "^${daemon}=" /etc/frr/daemons; then
    sed -i "s/^${daemon}=.*/${daemon}=yes/" /etc/frr/daemons
  else
    echo "${daemon}=yes" >>/etc/frr/daemons
  fi
done

if [ ! -s /etc/frr/frr.conf ]; then
  cat >/etc/frr/frr.conf <<EOF
frr defaults traditional
hostname $(hostname)
log syslog informational
ip forwarding
line vty
EOF
  chown frr:frr /etc/frr/frr.conf
  chmod 0640 /etc/frr/frr.conf
fi

systemctl enable --now frr
systemctl enable --now strongswan-starter || true
systemctl enable --now wg-quick@wg0 || true

cat >/opt/sdwan-router-appliance/README.txt <<'EOF'
Ubuntu SD-WAN/router appliance baseline installed.

Installed components:
- FRRouting for dynamic routing and BGP simulation.
- WireGuard for lightweight overlay tunnels.
- strongSwan for IPsec tunnel simulation.
- Linux forwarding defaults for appliance routing.

This package intentionally does not create BGP peers, tunnel keys, or customer-specific route policy.
Apply those as VM-specific configuration after deployment.
EOF

touch /opt/sdwan-router-appliance/installed