#!/usr/bin/env bash
# Throughput test against the iperf3 peer (macOS, also works on Linux).
# Usage: lantest.sh [target-ip]      default target: 169.254.99.1
# Compatible with bash 3.2 (macOS default).
TARGET="${1:-169.254.99.1}"
DURATION=10

if ! command -v iperf3 >/dev/null 2>&1; then
  echo "iperf3 not found. On macOS: brew install iperf3   (Debian/Ubuntu: apt install iperf3)" >&2
  exit 2
fi

OS=$(uname -s)
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
    ifconfig "$DEV" 2>/dev/null | grep media || echo "Link speed: unknown"
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
if [ "$MIN" -ge 880 ]; then
  echo "Verdict: OK - the path carries gigabit."
elif [ "$MIN" -ge 85 ] && [ "$FWD" -le 100 ] && [ "$REV" -le 100 ]; then
  echo "Verdict: the link runs at 100 Mbit/s only (about 94 Mbit/s expected). See README: 'Link only at 100 Mbit/s'."
else
  echo "Verdict: SUSPICIOUS - well below gigabit and not a clean 100 Mbit/s link. Check retransmits, the other end's port speed, the cable."
fi
exit 0
