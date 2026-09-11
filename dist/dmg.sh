#!/usr/bin/env bash
# dist/dmg.sh — wrap Myna.app in the drag-to-Applications disk image.
#
# Inputs (env):
#   APP_PATH   — default dist/export/Myna.app
#   VERSION    — default from tag / project.yml
#   OUT_DIR    — default dist/out
#   DMGBUILD   — dmgbuild executable (default: found on PATH; `pip install dmgbuild`)
#
# Output:
#   $OUT_DIR/Myna-$VERSION.dmg
#
# The window — background art, 112 pt icons, app left of the arrow and the
# Applications link right of it — is laid out by dmgbuild from
# dist/dmg/settings.py. dmgbuild writes the .DS_Store directly, with no Finder
# or AppleScript, so it lays out identically on CI. The art is
# dist/dmg/background.tiff (1x + 2x), rendered from background.html by
# dist/dmg/render-background.sh.
#
# Without dmgbuild it falls back to a plain hdiutil image (app + Applications
# link, no art), so a release never blocks on it.
#
# Usage:
#   dist/dmg.sh [--dry-run] [--help]
#
# Notes:
#   The DMG itself is NOT signed by this script. release.yml's sign-dmg job
#   signs and notarizes it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

SCRIPT_HELP="$(sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d')"
parse_common_args "$@"

ROOT="$(repo_root)"
APP_PATH="${APP_PATH:-$ROOT/dist/export/Myna.app}"
OUT_DIR="${OUT_DIR:-$ROOT/dist/out}"
VERSION="$(version_from_tag)"
DMGBUILD="${DMGBUILD:-$(command -v dmgbuild 2>/dev/null || true)}"
SETTINGS="$ROOT/dist/dmg/settings.py"
BACKGROUND="$ROOT/dist/dmg/background.tiff"
VOLUME_ICON="$APP_PATH/Contents/Resources/AppIcon.icns"

DMG="$OUT_DIR/Myna-$VERSION.dmg"

log "dmg.sh — app=$APP_PATH version=$VERSION out=$DMG"

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_cmd hdiutil
  [ -d "$APP_PATH" ] || die "no .app at $APP_PATH (run dist/build.sh first)"
fi

run "mkdir -p '$OUT_DIR'"
run "rm -f '$DMG'"

if [ -n "$DMGBUILD" ]; then
  log "using: dmgbuild ($DMGBUILD)"
  [ -f "$BACKGROUND" ] || die "missing DMG background at $BACKGROUND (run dist/dmg/render-background.sh)"
  icon_define=""
  if [ -f "$VOLUME_ICON" ]; then
    icon_define="-D icon='$VOLUME_ICON'"
  else
    warn "no AppIcon.icns in the app — the mounted volume keeps the default disk icon"
  fi
  run "'$DMGBUILD' -s '$SETTINGS' \
        -D app='$APP_PATH' \
        -D background='$BACKGROUND' \
        $icon_define \
        'Myna $VERSION' '$DMG'"
else
  warn "dmgbuild not found (pip install dmgbuild) — building a plain DMG without the window art"
  STAGE="$ROOT/dist/build/dmg-stage"
  run "rm -rf '$STAGE' && mkdir -p '$STAGE'"
  run "ditto '$APP_PATH' '$STAGE/Myna.app'"
  run "ln -s /Applications '$STAGE/Applications'"
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
