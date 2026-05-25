#!/usr/bin/env bash
# dist/build.sh — generate Xcode project, archive Myna, export .app
#
# Outputs:
#   dist/build/Myna.xcarchive
#   dist/export/Myna.app
#
# Usage:
#   dist/build.sh [--dry-run] [--help]
#
# Env:
#   VERSION              — marketing version (default: from GITHUB_REF or project.yml)
#   CONFIGURATION        — Release | Debug (default: Release)
#   SCHEME               — xcodebuild scheme (default: Myna)
#   ARCHS                — "arm64 x86_64" (default; universal binary)
#
# Notes:
#   No signing happens here. dist/sign.sh handles that on the .app this script
#   leaves behind in dist/export/Myna.app.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

SCRIPT_HELP="$(sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d')"
parse_common_args "$@"

CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="${SCHEME:-Myna}"
ARCHS="${ARCHS:-arm64 x86_64}"
VERSION="$(version_from_tag)"

ROOT="$(repo_root)"
APP_DIR="$ROOT/apps/macos"
BUILD_DIR="$ROOT/dist/build"
EXPORT_DIR="$ROOT/dist/export"
ARCHIVE_PATH="$BUILD_DIR/Myna.xcarchive"

log "build.sh — version=$VERSION configuration=$CONFIGURATION archs=$ARCHS"

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_cmd xcodebuild
  require_cmd xcodegen
fi

run "mkdir -p '$BUILD_DIR' '$EXPORT_DIR'"
run "rm -rf '$ARCHIVE_PATH' '$EXPORT_DIR/Myna.app'"

# 1) Regenerate the Xcode project from project.yml (declarative source of truth).
run "cd '$APP_DIR' && xcodegen generate"

# 2) Archive (Release config, universal binary).
#    We deliberately disable code signing here; sign.sh re-signs the .app.
run "xcodebuild archive \
       -project '$APP_DIR/Myna.xcodeproj' \
       -scheme '$SCHEME' \
       -configuration '$CONFIGURATION' \
       -archivePath '$ARCHIVE_PATH' \
       -destination 'generic/platform=macOS' \
       ARCHS='$ARCHS' \
       ONLY_ACTIVE_ARCH=NO \
       MARKETING_VERSION='$VERSION' \
       CODE_SIGN_IDENTITY='' \
       CODE_SIGNING_REQUIRED=NO \
       CODE_SIGNING_ALLOWED=NO"

# 3) Extract the .app from the archive's Products dir.
run "cp -R '$ARCHIVE_PATH/Products/Applications/Myna.app' '$EXPORT_DIR/Myna.app'"

# 4) Sanity-check the bundle.
if [ "${DRY_RUN:-0}" != "1" ]; then
  [ -d "$EXPORT_DIR/Myna.app" ] || die "expected $EXPORT_DIR/Myna.app to exist"
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                "$EXPORT_DIR/Myna.app/Contents/Info.plist" 2>/dev/null || echo "?")
  short_ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "$EXPORT_DIR/Myna.app/Contents/Info.plist" 2>/dev/null || echo "?")
  ok "built $EXPORT_DIR/Myna.app (bundle_id=$bundle_id, version=$short_ver)"
else
  ok "dry-run complete"
fi
