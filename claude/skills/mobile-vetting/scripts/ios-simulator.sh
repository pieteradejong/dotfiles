#!/usr/bin/env bash
#
# ios-simulator.sh — open URLs in real iOS Safari in the Xcode Simulator and screenshot them (D75).
#
#   ios-simulator.sh <out-dir> <url> [<url> ...]
#
# Playwright's WebKit is not iOS Safari: it has no browser bars, no notch, no on-screen keyboard.
# This catches what it misses. Uses the first available iPhone simulator, boots it if needed, and
# leaves it as it found it (shuts it down only if this script booted it). localhost works: the
# Simulator shares the Mac's network.
#
# Exit: 0 screenshots taken · 3 skipped (no Xcode or no iPhone simulator; not a failure) · 2 usage.
# bash 3.2 compatible (D21).

set -euo pipefail

[ $# -ge 2 ] || { echo "usage: ios-simulator.sh <out-dir> <url> [<url> ...]" >&2; exit 2; }
OUT="$1"; shift

if ! xcrun simctl help >/dev/null 2>&1; then
  echo "skipped: xcrun simctl not available (install Xcode to check real iOS Safari)"; exit 3
fi
LINE="$(xcrun simctl list devices available | grep -E '^ +iPhone' | head -1 || true)"
if [ -z "$LINE" ]; then
  echo "skipped: no iPhone simulator installed (Xcode > Settings > Components > iOS)"; exit 3
fi
UDID="$(printf '%s\n' "$LINE" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
NAME="$(printf '%s\n' "$LINE" | sed -E 's/^ +//; s/ \(.*//')"
BOOTED_HERE=0
if ! printf '%s\n' "$LINE" | grep -q '(Booted)'; then
  xcrun simctl boot "$UDID"; BOOTED_HERE=1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

mkdir -p "$OUT"
n=0
for url in "$@"; do
  n=$((n + 1))
  xcrun simctl openurl "$UDID" "$url"
  sleep "${SIM_WAIT:-4}"   # Safari has no load signal reachable from simctl; SIM_WAIT overrides
  shot="$OUT/ios-safari-$n.png"
  xcrun simctl io "$UDID" screenshot "$shot" >/dev/null
  echo "$NAME  $url  ->  $shot"
done

[ "$BOOTED_HERE" = 1 ] && xcrun simctl shutdown "$UDID"
exit 0
