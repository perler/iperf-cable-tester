#!/usr/bin/env bash
# Turns a PiKVM (Arch Linux ARM, read-only root, systemd-networkd) into an
# always-on iperf3 peer for cable / throughput tests.
#
#   - installs iperf3 and runs "iperf3 --server" at boot (port 5201)
#   - adds the fixed address 169.254.99.1/16 to eth0 next to whatever DHCP gives
#   - enables avahi, so the PiKVM answers as <hostname>.local (default pikvm.local)
#   - never serves DHCP, so it is safe on someone else's network
#
# Run as root on the PiKVM. Idempotent: running it again changes nothing.
# Run "pikvm-update" first - partial upgrades on Arch can break things. This
# script deliberately does not update the system itself.
set -euo pipefail

UNIT=/etc/systemd/system/lantester-iperf3.service
DROPIN_DIR=/etc/systemd/network/eth0.network.d
DROPIN=$DROPIN_DIR/lantester.conf

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi
if ! command -v rw >/dev/null 2>&1 || [[ ! -d /etc/kvmd ]]; then
  echo "This does not look like a PiKVM (no 'rw' command or no /etc/kvmd). Aborting." >&2
  exit 1
fi

echo "Reminder: if you have not run 'pikvm-update' yet, do that first (and reboot if it"
echo "asks you to). Partial upgrades on Arch can break things."
echo

# Make the root filesystem writable; always return it to read-only on exit.
rw
trap 'ro' EXIT

echo "== Installing iperf3"
pacman -S --noconfirm --needed iperf3

echo "== iperf3 service"
tmp=$(mktemp)
cat > "$tmp" <<'UNITFILE'
[Unit]
Description=iperf3 server for LAN cable tests
After=network.target

[Service]
ExecStart=/usr/bin/iperf3 --server
Restart=always
RestartSec=2
DynamicUser=yes

[Install]
WantedBy=multi-user.target
UNITFILE
if ! cmp -s "$tmp" "$UNIT"; then
  install -m 644 "$tmp" "$UNIT"
  systemctl daemon-reload
  echo "  wrote $UNIT"
fi
rm -f "$tmp"
# The package's own iperf3.service stays disabled; we use our unit.
systemctl disable iperf3.service >/dev/null 2>&1 || true
systemctl enable --now lantester-iperf3.service

echo "== Fixed address on eth0"
# A drop-in, so the package's own eth0.network stays untouched.
mkdir -p "$DROPIN_DIR"
tmp=$(mktemp)
printf '[Network]\nAddress=169.254.99.1/16\n' > "$tmp"
if ! cmp -s "$tmp" "$DROPIN"; then
  install -m 644 "$tmp" "$DROPIN"
  echo "  wrote $DROPIN"
fi
rm -f "$tmp"
networkctl reload

echo "== Announce the hostname via mDNS (avahi)"
# PiKVM ships avahi but leaves it disabled. With it running, the PiKVM answers
# as <hostname>.local (pikvm.local by default), which the client scripts try.
pacman -S --noconfirm --needed avahi
systemctl enable --now avahi-daemon.service

echo
echo "Done. Verify:"
echo "  systemctl is-active lantester-iperf3   (should print: active)"
echo "  ip -4 addr show eth0                   (should list 169.254.99.1/16)"
echo "From a laptop on a bare cable:  iperf3 -c 169.254.99.1"
echo "Current link speed on the PiKVM:  cat /sys/class/net/eth0/speed"
echo "The root filesystem is returned to read-only now."
