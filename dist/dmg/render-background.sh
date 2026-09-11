#!/usr/bin/env bash
# dist/dmg/render-background.sh — re-render the DMG window art after editing
# background.html. Writes background.png (660×420), background@2x.png
# (1320×840) and background.tiff (both, for Finder's Retina lookup) beside
# this script. The outputs are committed, so CI never renders anything.
#
# Needs Google Chrome (headless screenshots) and tiffutil (ships with macOS).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME (set CHROME=…)" >&2; exit 1; }

shoot() {  # shoot <scale> <out.png>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
    --window-size=660,420 --force-device-scale-factor="$1" \
    --virtual-time-budget=8000 \
    --screenshot="$2" "file://$HERE/background.html" >/dev/null 2>&1
}

shoot 1 "$HERE/background.png"
shoot 2 "$HERE/background@2x.png"
tiffutil -cathidpicheck "$HERE/background.png" "$HERE/background@2x.png" -out "$HERE/background.tiff"
echo "rendered $HERE/background.{png,@2x.png,tiff}"
