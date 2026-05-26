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

# 4) Build the karaoke sidecar (v0.2+) and nest it inside Myna.app.
#
#    Pipeline ordering matters here. The sidecar MUST be:
#    1. Built + signed at its own layer (karaoke/build.sh)
#    2. ditto'd (NOT cp -R — breaks xattrs / signatures) into
#         Myna.app/Contents/Resources/MynaKaraoke.app
#    3. The OUTER Myna.app then gets signed by dist/sign.sh, which re-seals
#       the nested bundle hash (this is correct — Apple's nested-bundle
#       signing model expects the outer to seal what's inside).
#
#    The sidecar build is *additive* to v0.1's flow. If karaoke/ doesn't
#    exist (e.g. cherry-pick onto an older branch), skip silently.
KARAOKE_DIR="$ROOT/karaoke"
if [ -d "$KARAOKE_DIR" ]; then
  log "building karaoke sidecar"
  # Sidecar's own build.sh handles its codesign if DEVELOPER_ID_APPLICATION
  # is set. In dry-run we just probe the script's --dry-run.
  if [ "${DRY_RUN:-0}" = "1" ]; then
    run "bash '$KARAOKE_DIR/build.sh' --dry-run"
  else
    run "(cd '$KARAOKE_DIR' && bash build.sh)"
    [ -d "$KARAOKE_DIR/MynaKaraoke.app" ] \
      || die "karaoke/MynaKaraoke.app missing after build"
  fi

  # Use ditto (NOT cp -R) — preserves extended attributes, hardlinks,
  # and most importantly any pre-existing codesign blobs that cp -R
  # silently strips. Lesson from v0.1.0 sign saga (commit a7fcbd2).
  run "mkdir -p '$EXPORT_DIR/Myna.app/Contents/Resources'"
  run "rm -rf '$EXPORT_DIR/Myna.app/Contents/Resources/MynaKaraoke.app'"
  run "ditto '$KARAOKE_DIR/MynaKaraoke.app' '$EXPORT_DIR/Myna.app/Contents/Resources/MynaKaraoke.app'"
else
  warn "no karaoke/ dir — skipping sidecar nest (pre-v0.2 branch?)"
fi

# 5) Sanity-check the bundle.
if [ "${DRY_RUN:-0}" != "1" ]; then
  [ -d "$EXPORT_DIR/Myna.app" ] || die "expected $EXPORT_DIR/Myna.app to exist"
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                "$EXPORT_DIR/Myna.app/Contents/Info.plist" 2>/dev/null || echo "?")
  short_ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "$EXPORT_DIR/Myna.app/Contents/Info.plist" 2>/dev/null || echo "?")
  ok "built $EXPORT_DIR/Myna.app (bundle_id=$bundle_id, version=$short_ver)"

  # Verify the karaoke sidecar landed correctly (if karaoke/ was present).
  if [ -d "$KARAOKE_DIR" ]; then
    NESTED="$EXPORT_DIR/Myna.app/Contents/Resources/MynaKaraoke.app"
    [ -d "$NESTED" ] || die "expected nested sidecar at $NESTED"
    [ -x "$NESTED/Contents/MacOS/MynaKaraoke" ] \
      || die "sidecar binary missing or not executable"
    nested_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                  "$NESTED/Contents/Info.plist" 2>/dev/null || echo "?")
    ok "nested sidecar at Resources/MynaKaraoke.app (bundle_id=$nested_id)"
  fi
else
  ok "dry-run complete"
fi
