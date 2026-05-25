#!/usr/bin/env bash
# dist/dmg.sh — wrap Myna.app in a DMG.
#
# Inputs (env):
#   APP_PATH      — default dist/export/Myna.app
#   VERSION       — default from tag / project.yml
#   OUT_DIR       — default dist/out
#   BACKGROUND    — optional path to a .png background (default dist/dmg-background.png)
#   USE_CREATE_DMG — "1" to prefer the `create-dmg` brew package; default "auto"
#                    (use create-dmg if installed, else fall back to hdiutil).
#
# Output:
#   $OUT_DIR/Myna-$VERSION.dmg
#
# Usage:
#   dist/dmg.sh [--dry-run] [--help]
#
# Notes:
#   The DMG itself is NOT signed by this script. Use dist/sign.sh on the
#   resulting .dmg afterwards (release.yml's sign-dmg job does this).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

SCRIPT_HELP="$(sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d')"
parse_common_args "$@"

ROOT="$(repo_root)"
APP_PATH="${APP_PATH:-$ROOT/dist/export/Myna.app}"
OUT_DIR="${OUT_DIR:-$ROOT/dist/out}"
BACKGROUND="${BACKGROUND:-$ROOT/dist/dmg-background.png}"
VERSION="$(version_from_tag)"
USE_CREATE_DMG="${USE_CREATE_DMG:-auto}"

DMG="$OUT_DIR/Myna-$VERSION.dmg"

log "dmg.sh — app=$APP_PATH version=$VERSION out=$DMG"

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_cmd hdiutil
  [ -d "$APP_PATH" ] || die "no .app at $APP_PATH (run dist/build.sh first)"
fi

run "mkdir -p '$OUT_DIR'"
run "rm -f '$DMG'"

# Decide which tool to use.
tool="hdiutil"
if [ "$USE_CREATE_DMG" = "1" ] || \
   { [ "$USE_CREATE_DMG" = "auto" ] && command -v create-dmg >/dev/null 2>&1; }; then
  tool="create-dmg"
fi

log "using: $tool"

if [ "$tool" = "create-dmg" ]; then
  bg_arg=""
  if [ -f "$BACKGROUND" ]; then
    bg_arg="--background '$BACKGROUND'"
  else
    warn "no background image at $BACKGROUND (DMG will use default)"
  fi
  # shellcheck disable=SC2086
  run "create-dmg \
        --volname 'Myna $VERSION' \
        --window-pos 200 120 \
        --window-size 600 380 \
        --icon-size 100 \
        --icon 'Myna.app' 150 190 \
        --hide-extension 'Myna.app' \
        --app-drop-link 450 190 \
        --no-internet-enable \
        $bg_arg \
        '$DMG' \
        '$APP_PATH'"
else
  # Hand-rolled hdiutil. Build a staging dir with the .app + an Applications symlink.
  STAGE="$ROOT/dist/build/dmg-stage"
  run "rm -rf '$STAGE' && mkdir -p '$STAGE'"
  run "cp -R '$APP_PATH' '$STAGE/'"
  run "ln -s /Applications '$STAGE/Applications'"
  # Create compressed DMG.
  run "hdiutil create \
        -volname 'Myna $VERSION' \
        -srcfolder '$STAGE' \
        -ov \
        -format UDZO \
        -fs HFS+ \
        '$DMG'"
  run "rm -rf '$STAGE'"
fi

if [ "${DRY_RUN:-0}" != "1" ]; then
  [ -f "$DMG" ] || die "DMG was not created at $DMG"
  size=$(stat -f '%z' "$DMG" 2>/dev/null || stat -c '%s' "$DMG")
  ok "created $DMG (${size} bytes)"
else
  ok "dry-run complete"
fi

# Emit the path for callers (CI consumes via stdout).
printf '%s\n' "$DMG"
