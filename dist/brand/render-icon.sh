#!/usr/bin/env bash
# dist/brand/render-icon.sh — regenerate the app icon from app-icon.svg.
# Writes every size macOS asks for into
# apps/macos/Resources/Assets.xcassets/AppIcon.appiconset/ (committed, so CI
# never renders anything). Xcode compiles that set into AppIcon.icns +
# Assets.car at build time.
#
# Needs Google Chrome (headless screenshot with a transparent background) and
# sips (ships with macOS).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SET="$ROOT/apps/macos/Resources/Assets.xcassets/AppIcon.appiconset"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Google Chrome not found at $CHROME (set CHROME=…)" >&2; exit 1; }

mkdir -p "$SET"
MASTER="$SET/icon_512x512@2x.png"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars \
  --window-size=1024,1024 --default-background-color=00000000 \
  --screenshot="$MASTER" "file://$HERE/app-icon.svg" >/dev/null 2>&1

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  if [ "$double" -ne 1024 ]; then
    sips -z "$double" "$double" "$MASTER" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
  fi
done

cat > "$SET/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
[ -f "$SET/../Contents.json" ] || printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$SET/../Contents.json"
echo "rendered $SET"
