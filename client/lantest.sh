#!/usr/bin/env bash
# Throughput test against the iperf3 peer (macOS, also works on Linux).
# Usage: lantest.sh [peer-ip-or-name]
# Without an argument the peer is found automatically: 169.254.99.1, then
# iperf-peer.local, then pikvm.local, then a scan of the local /24 for
# Raspberry Pi devices with port 5201 open.
# LANTEST_PEERS="name-or-ip ..." replaces the list of names tried before the scan.
# Compatible with bash 3.2 (macOS default).
TARGET="$1"
DURATION=10
IPERF_PORT=5201
OS=$(uname -s)

if ! command -v iperf3 >/dev/null 2>&1; then
  echo "iperf3 not found. On macOS: brew install iperf3   (Debian/Ubuntu: apt install iperf3)" >&2
  exit 2
fi

# --- Finding the peer -------------------------------------------------------

FIND_TMP=$(mktemp "${TMPDIR:-/tmp}/lantest-find.XXXXXX") || exit 2

# run_bounded <seconds> <command...>: run a command, kill it after <seconds>.
# Works without coreutils' timeout (not present on macOS). Output goes to the
# caller's redirection; do not use inside $( ), the watchdog would hold it open.
run_bounded() {
  secs=$1; shift
  "$@" &
  cmd_pid=$!
  ( sleep "$secs"; kill "$cmd_pid" 2>/dev/null ) >/dev/null 2>&1 &
  dog_pid=$!
  wait "$cmd_pid"
  rc=$?
  kill "$dog_pid" 2>/dev/null
  wait "$dog_pid" 2>/dev/null
  return $rc
}

is_ipv4() {
  echo "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# resolve_v4 <name>: print its IPv4 addresses, one per line, or nothing (at most ~2 s).
resolve_v4() {
  if is_ipv4 "$1"; then echo "$1"; return; fi
  : > "$FIND_TMP"
  if [ "$OS" = "Darwin" ]; then
    run_bounded 2 dscacheutil -q host -a name "$1" > "$FIND_TMP" 2>/dev/null
    awk '/^ip_address:/ && !seen[$2]++ {print $2}' "$FIND_TMP"
  else
    run_bounded 2 getent ahostsv4 "$1" > "$FIND_TMP" 2>/dev/null
    awk '!seen[$1]++ {print $1}' "$FIND_TMP"
  fi
}

# first_open <name>: print the first of its IPv4 addresses that answers on
# port 5201 (a name can have a wired and a Wi-Fi address), or nothing.
first_open() {
  for a in $(resolve_v4 "$1"); do
    if port_open "$a"; then echo "$a"; return 0; fi
  done
  return 1
}

# port_open <ip>: TCP connect to port 5201, at most ~2 s.
port_open() {
  if [ "$OS" = "Darwin" ]; then
    run_bounded 2 nc -z -G 2 "$1" "$IPERF_PORT" >/dev/null 2>&1
  else
    # shellcheck disable=SC2016  # expanded by the inner bash
    run_bounded 2 bash -c ': > "/dev/tcp/$1/$2"' _ "$1" "$IPERF_PORT" >/dev/null 2>&1
  fi
}

# Raspberry Pi Foundation / Raspberry Pi Trading MAC prefixes.
PI_OUIS="b8:27:eb dc:a6:32 e4:5f:01 d8:3a:dd 2c:cf:67 28:cd:c1"

# scan_for_pi: sweep the primary interface's subnet (/24 or smaller), then
# probe port 5201 on every Raspberry Pi in the ARP table. Sets TARGET on success.
scan_for_pi() {
  if [ "$OS" = "Darwin" ]; then
    sdev=$(route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}')
    [ -n "$sdev" ] || { echo "Network scan skipped: no default route (no normal network)." >&2; return 1; }
    read -r myip hexmask <<< "$(ifconfig "$sdev" 2>/dev/null | awk '$1 == "inet" && $2 !~ /^169\.254\./ {print $2, $4; exit}')"
    [ -n "$myip" ] || { echo "Network scan skipped: $sdev has no IPv4 address." >&2; return 1; }
    maskint=$(printf '%d' "$hexmask" 2>/dev/null)
    prefix=0; m=$maskint
    while [ "$m" -gt 0 ]; do prefix=$((prefix + (m & 1))); m=$((m >> 1)); done
  else
    sdev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}')
    [ -n "$sdev" ] || { echo "Network scan skipped: no default route (no normal network)." >&2; return 1; }
    cidr=$(ip -4 -o addr show dev "$sdev" 2>/dev/null | awk '{print $4; exit}')
    myip=${cidr%/*}; prefix=${cidr#*/}
    [ -n "$myip" ] || { echo "Network scan skipped: $sdev has no IPv4 address." >&2; return 1; }
  fi
  if [ "$prefix" -lt 24 ]; then
    echo "Network scan skipped: $myip/$prefix on $sdev is too large to scan. Pass the peer's IP as argument." >&2
    return 1
  fi
  if [ "$prefix" -gt 30 ]; then
    echo "Network scan skipped: $myip/$prefix on $sdev has no other hosts." >&2
    return 1
  fi
  # /24 or smaller: only the last octet varies.
  size=$((1 << (32 - prefix)))
  base=${myip%.*}
  first=$(( ${myip##*.} / size * size ))
  echo "Scanning $base.$first/$prefix on $sdev for Raspberry Pi devices (takes a few seconds)..."
  i=1
  while [ "$i" -lt $((size - 1)) ]; do
    a="$base.$((first + i))"
    if [ "$a" != "$myip" ]; then
      if [ "$OS" = "Darwin" ]; then
        ping -c 1 -t 1 "$a" >/dev/null 2>&1 &
      else
        ping -c 1 -W 1 "$a" >/dev/null 2>&1 &
      fi
    fi
    i=$((i + 1))
  done
  wait
  # "<ip> <mac>" lines, MAC normalised to lower case with two-digit octets.
  if [ "$OS" = "Darwin" ]; then
    arp -an 2>/dev/null | awk '{ip = $2; gsub(/[()]/, "", ip); print ip, $4}'
  else
    ip neigh show dev "$sdev" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "lladdr") print $1, $(i+1)}'
  fi | awk '{n = split(tolower($2), o, ":"); if (n != 6) next
             mac = ""; for (i = 1; i <= 6; i++) mac = mac (i > 1 ? ":" : "") (length(o[i]) == 1 ? "0" : "") o[i]
             print $1, mac}' > "$FIND_TMP"
  while read -r a mac; do
    for oui in $PI_OUIS; do
      case "$mac" in "$oui":*) ;; *) continue ;; esac
      [ "${a%.*}" = "$base" ] || continue
      n=${a##*.}
      if [ "$n" -le "$first" ] || [ "$n" -ge $((first + size - 1)) ]; then continue; fi
      if port_open "$a"; then
        TARGET=$a
        echo "Peer found: $a (Raspberry Pi, found by network scan)"
        return 0
      fi
    done
  done < "$FIND_TMP"
  echo "Network scan: no Raspberry Pi with port $IPERF_PORT open on $base.$first/$prefix." >&2
  return 1
}

find_peer() {
  CANDIDATES=${LANTEST_PEERS:-"169.254.99.1 iperf-peer.local pikvm.local"}
  echo "=== Looking for the peer ==="
  for c in $CANDIDATES; do
    if a=$(first_open "$c"); then
      TARGET=$a
      if [ "$a" = "$c" ]; then echo "Peer found: $c"; else echo "Peer found: $c ($a)"; fi
      return 0
    fi
  done
  scan_for_pi && return 0
  echo >&2
  echo "No iperf3 peer found. Tried: $CANDIDATES, then a scan for Raspberry Pi devices." >&2
  echo "On a bare cable: wait about 30 s after plugging in until the computer has given itself" >&2
  echo "a 169.254.x.x address, turn Wi-Fi off, check the peer is powered and booted, run again." >&2
  echo "On a normal network: pass the peer's IP (from the router's device list) as argument," >&2
  echo "for example: $0 192.168.1.50" >&2
  return 1
}

if [ -z "$TARGET" ]; then
  find_peer || { rm -f "$FIND_TMP"; exit 1; }
  echo
elif ! is_ipv4 "$TARGET" && a=$(first_open "$TARGET"); then
  # A name: use the address that answers, not whichever iperf3 would pick.
  echo "Peer: $TARGET ($a)"
  TARGET=$a
fi
rm -f "$FIND_TMP"

DEV=""
echo "=== Route to $TARGET ==="
if [ "$OS" = "Darwin" ]; then
  DEV=$(route -n get "$TARGET" 2>/dev/null | awk '/interface:/ {print $2; exit}')
else
  DEV=$(ip route get "$TARGET" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}')
fi

if [ -z "$DEV" ]; then
  echo "No route to $TARGET found (yet)."
else
  echo "Interface: $DEV"
  # Wi-Fi warning
  IS_WIFI=0
  if [ "$OS" = "Darwin" ]; then
    PORT=$(networksetup -listallhardwareports 2>/dev/null | awk -v d="$DEV" '/^Hardware Port:/ {p = substr($0, 16)} /^Device:/ && $2 == d {print p; exit}')
    case "$PORT" in *Wi-Fi*|*AirPort*) IS_WIFI=1 ;; esac
  elif [ -d "/sys/class/net/$DEV/wireless" ]; then
    IS_WIFI=1
  fi
  if [ "$IS_WIFI" = 1 ]; then
    echo "WARNING: $DEV is Wi-Fi. This measures the wireless link, not the cable. Turn Wi-Fi off and use the wired interface." >&2
  fi
  # Link speed
  if [ "$OS" = "Darwin" ]; then
    MEDIA=$(ifconfig "$DEV" 2>/dev/null | sed -n 's/.*media: //p')
    echo "Link speed: ${MEDIA:-unknown}"
  else
    SPEED=""
    [ -r "/sys/class/net/$DEV/speed" ] && SPEED=$(cat "/sys/class/net/$DEV/speed" 2>/dev/null)
    if [ -z "$SPEED" ] || [ "$SPEED" = "-1" ]; then
      if command -v ethtool >/dev/null 2>&1; then
        SPEED=$(ethtool "$DEV" 2>/dev/null | awk '/Speed:/ {print $2}')
      else
        SPEED=""
      fi
    fi
    case "$SPEED" in *nknown*) SPEED="" ;; esac
    if [ -n "$SPEED" ] && [ "$SPEED" != "-1" ]; then
      echo "Link speed: $SPEED (Mbit/s unless stated)"
    else
      echo "Link speed: unknown"
    fi
  fi
fi

# Print the receiver Mbit/s from iperf3 output ($1 = file). Empty if not found.
HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

parse_json() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    e = d["end"]
    print("%.0f %d" % (e["sum_received"]["bits_per_second"] / 1e6, e["sum_sent"].get("retransmits", 0)))
except Exception:
    pass
' "$1"
}

parse_plain() {
  awk '/receiver/ {for (i = 2; i <= NF; i++) {
        if ($i == "Gbits/sec") v = $(i-1) * 1000
        else if ($i == "Mbits/sec") v = $(i-1)
        else if ($i == "Kbits/sec") v = $(i-1) / 1000
      }} END {if (v != "") printf "%.0f -\n", v}' "$1"
}

TMP=$(mktemp "${TMPDIR:-/tmp}/lantest.XXXXXX") || exit 2
trap 'rm -f "$TMP"' EXIT

# run_test <label> [extra iperf3 args]; sets RESULT_MBIT and RESULT_RETR
run_test() {
  label="$1"; shift
  echo
  echo "=== $label ($DURATION s) ==="
  RESULT_MBIT=""; RESULT_RETR="-"
  if [ "$HAVE_PY" = 1 ]; then
    iperf3 -c "$TARGET" -t "$DURATION" --connect-timeout 3000 -J "$@" > "$TMP" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
      # JSON error output carries an "error" field; show something readable
      python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("error", ""))
except Exception:
    print(open(sys.argv[1]).read())
' "$TMP" >&2
      return $rc
    fi
    out=$(parse_json "$TMP")
  else
    iperf3 -c "$TARGET" -t "$DURATION" --connect-timeout 3000 "$@" 2>&1 | tee "$TMP"
    rc=${PIPESTATUS[0]}
    [ "$rc" -ne 0 ] && return "$rc"
    out=$(parse_plain "$TMP")
  fi
  RESULT_MBIT=${out%% *}
  RESULT_RETR=${out##* }
  if [ -n "$RESULT_MBIT" ]; then
    echo "Receiver: $RESULT_MBIT Mbit/s (retransmits: $RESULT_RETR)"
  else
    echo "Could not read a result from the iperf3 output."
    RESULT_MBIT=0
  fi
  return 0
}

fail_unreachable() {
  echo >&2
  echo "iperf3 test to $TARGET failed - peer not reachable." >&2
  echo "On a bare cable: wait about 30 s after plugging in until the computer has given itself" >&2
  echo "a 169.254.x.x address, turn Wi-Fi off, and check the peer is powered and booted." >&2
  echo "On a normal network: pass the peer's DHCP address as argument." >&2
  exit 1
}

run_test "This computer -> peer" || fail_unreachable
FWD=$RESULT_MBIT
run_test "Peer -> this computer" -R || fail_unreachable
REV=$RESULT_MBIT

MIN=$FWD
[ "$REV" -lt "$MIN" ] && MIN=$REV

echo
echo "Result: $FWD Mbit/s forward, $REV Mbit/s reverse."
if [ "$MIN" -ge 800 ]; then
  echo "Verdict: OK - the path carries gigabit."
elif [ "$MIN" -ge 85 ] && [ "$FWD" -le 100 ] && [ "$REV" -le 100 ]; then
  echo "Verdict: the link runs at 100 Mbit/s only (about 94 Mbit/s expected). See README: 'Link only at 100 Mbit/s'."
else
  echo "Verdict: SUSPICIOUS - well below gigabit and not a clean 100 Mbit/s link. Check retransmits, the other end's port speed, the cable."
fi
exit 0
