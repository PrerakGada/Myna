#!/usr/bin/env bash
# dev.sh — kill running Myna, regenerate Xcode project, build Debug, relaunch.
#
# Run from anywhere:    ~/Developer/myna/apps/macos/dev.sh
# Run from this dir:    ./dev.sh
#
# That's it. No flags. Read the file if you want a different flow.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# 1. Kill any running instance so the relaunch picks up new code
pkill -f "Myna.app/Contents/MacOS/Myna" 2>/dev/null || true
sleep 1

# 2. Regenerate Xcode project from project.yml (cheap; ~1-2s)
xcodegen generate >/dev/null

# 3. Debug build (no signing — local dev only)
xcodebuild \
  -scheme Myna \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3

# 4. Launch the freshly-built .app
APP="$HERE/build/Build/Products/Debug/Myna.app"
[ -d "$APP" ] || { echo "no Myna.app at $APP" >&2; exit 1; }
open "$APP"
echo "Launched: $APP"
