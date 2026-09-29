#!/usr/bin/env bash
# Turns a Raspberry Pi 4/5 (Raspberry Pi OS Lite, Bookworm or newer) into an
# always-on iperf3 peer for cable / throughput tests.
#
#   - The iperf3 server starts at every boot (port 5201), bound to eth0, so a
#     Wi-Fi address never answers and cannot be measured by mistake.
#   - eth0: DHCP first (20 s). If no address arrives, the fixed address
#     169.254.99.1/16 is used
#       -> on a bare cable without a router: reachable at 169.254.99.1
#       -> on a normal LAN: reachable at its DHCP address, or <hostname>.local
#   - The Pi never hands out addresses itself, so it is safe to plug into
#     someone else's network.
#
# Usage on the Pi (once, needs internet):
#   sudo bash setup-raspberry-pi-os.sh [--hostname NAME]
# The hostname defaults to "iperf-peer"; HOSTNAME_NEW=name works as well.
set -euo pipefail

FALLBACK_IP="169.254.99.1/16"
IFACE="eth0"
NEW_HOSTNAME="${HOSTNAME_NEW:-iperf-peer}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      [[ $# -ge 2 ]] || { echo "--hostname needs a value." >&2; exit 1; }
      NEW_HOSTNAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Please run with sudo." >&2
  exit 1
fi
command -v nmcli >/dev/null || { echo "NetworkManager is missing - use Raspberry Pi OS Bookworm or newer." >&2; exit 1; }

echo "== Installing packages"
# Debian would otherwise ask whether iperf3 should run as a service - we ship our own unit.
echo "iperf3 iperf3/start_daemon boolean false" | debconf-set-selections
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3 ethtool avahi-daemon

echo "== Setting up the iperf3 service"
cat > /etc/systemd/system/lantester-iperf3.service <<'UNIT'
[Unit]
Description=iperf3 server for LAN cable tests
After=network.target

[Service]
ExecStart=/usr/bin/iperf3 --server --bind-dev eth0
Restart=always
RestartSec=2
DynamicUser=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now lantester-iperf3.service

echo "== Network profiles for $IFACE"
# No more auto-generated "Wired connection" profiles, only our two.
# Old profiles are disabled, not deleted - deleting would drop a running SSH
# session over the cable. Everything takes effect after the reboot.
cat > /etc/NetworkManager/conf.d/90-lantester.conf <<'CONF'
[main]
no-auto-default=*
CONF
while IFS=: read -r name type; do
  if [[ $type == 802-3-ethernet && $name != lan-dhcp && $name != lan-direct ]]; then
    nmcli connection modify "$name" connection.autoconnect no
    echo "  disabled old profile: $name"
  fi
done < <(nmcli -t -f NAME,TYPE connection show)

if ! nmcli -t -f NAME connection show | grep -qx lan-dhcp; then
  # First choice: DHCP. If it fails after 20 s the profile counts as failed ...
  nmcli connection add type ethernet ifname "$IFACE" con-name lan-dhcp \
    connection.autoconnect yes connection.autoconnect-priority 10 connection.autoconnect-retries 1 \
    ipv4.method auto ipv4.dhcp-timeout 20 ipv4.may-fail no \
    ipv6.method auto ipv6.may-fail yes
fi
if ! nmcli -t -f NAME connection show | grep -qx lan-direct; then
  # ... and NetworkManager falls back to the fixed address (bare cable, no router).
  nmcli connection add type ethernet ifname "$IFACE" con-name lan-direct \
    connection.autoconnect yes connection.autoconnect-priority 0 \
    ipv4.method manual ipv4.addresses "$FALLBACK_IP" \
    ipv6.method link-local
fi

echo "== Hostname"
if [[ $(hostname) != "$NEW_HOSTNAME" ]]; then
  hostnamectl set-hostname "$NEW_HOSTNAME"
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
fi

echo
echo "Done. Reboot now (sudo reboot). Afterwards:"
echo "  Bare cable:    iperf3 -c ${FALLBACK_IP%/*}"
echo "  On a network:  iperf3 -c ${NEW_HOSTNAME}.local"
echo "Current link speed on the Pi:  ethtool $IFACE | grep Speed"
echo "Note: NetworkManager ignores carrier loss shorter than ~6 s. When moving the Pi"
echo "between networks, unplug the cable for at least 10 s, or reboot."
