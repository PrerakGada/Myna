#!/usr/bin/env bash
# dist/notarize.sh — submit Myna.app (or .dmg) to Apple notarytool, wait, staple.
#
# Inputs (env):
#   APPLE_ID                 — your Apple ID email
#   APPLE_TEAM_ID            — 10-char team ID (e.g. ABCDE12345)
#   APPLE_ID_APP_PASSWORD    — app-specific password from appleid.apple.com
#   TARGET                   — optional path to .app or .dmg
#                              (default: dist/export/Myna.app, or .dmg if present)
#
# Usage:
#   dist/notarize.sh [--dry-run] [--help]
#
# Notes:
#   notarytool wants a zip/dmg/pkg — not a raw .app. If TARGET is a .app, we
#   ditto-zip it to a tempfile first, submit the zip, then staple back to the
#   .app. If TARGET is already .dmg/.pkg/.zip, we submit directly and staple.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

SCRIPT_HELP="$(sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d')"
parse_common_args "$@"

ROOT="$(repo_root)"
TARGET="${TARGET:-$ROOT/dist/export/Myna.app}"
# If a DMG exists from dmg.sh, prefer it (notarize the artifact users download).
if [ -z "${TARGET_SET:-}" ] && [ -f "$ROOT/dist/out/Myna-$(version_from_tag).dmg" ]; then
  TARGET="$ROOT/dist/out/Myna-$(version_from_tag).dmg"
fi

log "notarize.sh — target=$TARGET"

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_cmd xcrun
  require_env APPLE_ID
  require_env APPLE_TEAM_ID
  require_env APPLE_ID_APP_PASSWORD
  [ -e "$TARGET" ] || die "no target at $TARGET"
fi

ext="${TARGET##*.}"
submit_path="$TARGET"
created_zip=""

if [ "$ext" = "app" ]; then
  zip="$ROOT/dist/build/$(basename "$TARGET").zip"
  run "mkdir -p '$(dirname "$zip")'"
  run "rm -f '$zip'"
  run "/usr/bin/ditto -c -k --keepParent '$TARGET' '$zip'"
  submit_path="$zip"
  created_zip="$zip"
fi

run "xcrun notarytool submit '$submit_path' \
       --apple-id \"\$APPLE_ID\" \
       --team-id \"\$APPLE_TEAM_ID\" \
       --password \"\$APPLE_ID_APP_PASSWORD\" \
       --wait \
       --timeout 30m"

# Staple to the original (not the zip).
case "$ext" in
  app|dmg|pkg)
    run "xcrun stapler staple '$TARGET'"
    run "xcrun stapler validate '$TARGET'"
    ;;
  zip)
    warn "cannot staple a .zip; users must re-download to get the staple"
    ;;
esac

if [ -n "$created_zip" ] && [ "${DRY_RUN:-0}" != "1" ]; then
  rm -f "$created_zip"
fi

ok "notarized $TARGET"
