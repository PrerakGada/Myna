#!/usr/bin/env bash
# dev.sh — kill running Myna, regenerate Xcode project, build Debug, sign
# (so TCC permissions carry over from the installed /Applications/Myna.app),
# nest the karaoke sidecar, relaunch.
#
# Run from anywhere:    ~/Developer/myna/apps/macos/dev.sh
# Run from this dir:    ./dev.sh
#
# Env:
#   DEVELOPER_ID_APPLICATION  — e.g. "Developer ID Application: MIND WEALTH (RC63N3VU27)"
#                               If set, the Debug build is signed with your
#                               real Developer ID. macOS TCC then recognizes
#                               this Debug build as the same identity as the
#                               signed /Applications/Myna.app and your
#                               Accessibility / Input Monitoring / AppleEvents
#                               grants carry over automatically — hotkey +
#                               selection capture work without re-prompting.
#                               STRONGLY RECOMMENDED. If unset, the script
#                               builds an ad-hoc-signed Debug app and warns
#                               you that TCC will treat it as a different app.
#
# Background:
#   Without signing, the Debug build is ad-hoc and lives at a different bundle
#   path than the installed Release. TCC keys permissions on signature +
#   bundle identity, so an ad-hoc Debug app does NOT inherit grants from the
#   signed Release. You'd see "speak-selection: no text captured" in the log
#   even though the hotkey fires correctly. Signing the Debug build with the
#   same Developer ID + same bundle ID fixes this.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$HERE"

# 1. Kill any running instance so the relaunch picks up new code.
#    Matches both the Debug-from-build path AND any signed Release install.
pkill -f "Myna.app/Contents/MacOS/Myna" 2>/dev/null || true
sleep 1

# 2. Refresh the bundled setup script (the in-app "Finish setup" flow runs it),
#    then regenerate the Xcode project from project.yml (cheap; ~1-2s).
mkdir -p "$HERE/Resources/setup"
cp "$REPO/dist/setup.sh" "$HERE/Resources/setup/setup.sh"
xcodegen generate >/dev/null

# 3. Debug build (Xcode doesn't sign; we'll do it ourselves in step 5)
xcodebuild \
  -scheme Myna \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | tail -3

APP="$HERE/build/Build/Products/Debug/Myna.app"
[ -d "$APP" ] || { echo "no Myna.app at $APP" >&2; exit 1; }

# 4. Optionally build + nest the karaoke sidecar so end-to-end karaoke
#    works against this Debug build. Skip if karaoke/ isn't here (back-compat).
if [ -d "$REPO/karaoke" ] && [ -x "$REPO/karaoke/build.sh" ]; then
  echo "==> building + nesting karaoke sidecar"
  ( cd "$REPO/karaoke" && bash build.sh 2>&1 | tail -3 )
  SIDECAR="$REPO/karaoke/MynaKaraoke.app"
  if [ -d "$SIDECAR" ]; then
    rm -rf "$APP/Contents/Resources/MynaKaraoke.app"
    ditto "$SIDECAR" "$APP/Contents/Resources/MynaKaraoke.app"
    echo "    nested at Contents/Resources/MynaKaraoke.app"
  fi
fi

# 5. Sign with Developer ID if available — this is what makes TCC see the
#    Debug build as "the same app" as the installed Release, so all your
#    previously-granted permissions (Accessibility, Input Monitoring,
#    AppleEvents) just work.
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  echo "==> signing Debug build with Developer ID (TCC-compat)"
  ENTITLEMENTS="$HERE/Resources/Myna.entitlements"
  # --deep is OK here because this is dev-only (never notarized / distributed).
  # For Release signing the inside-out flow in dist/sign.sh is still the right
  # path; that flow handles Sparkle.framework's funky bundle layout.
  codesign --force --deep \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP" 2>&1 | tail -3
  echo "    signed as: $DEVELOPER_ID_APPLICATION"
else
  echo ""
  echo "⚠️  DEVELOPER_ID_APPLICATION not set — Debug build is ad-hoc-signed."
  echo "    macOS TCC will treat this as a different app from /Applications/Myna.app"
  echo "    and will NOT inherit your Accessibility / Input Monitoring grants."
  echo "    The hotkey will fire but text capture will silently fail."
  echo ""
  echo "    To fix: add this to your ~/.zshrc or ~/.bashrc:"
  echo "      export DEVELOPER_ID_APPLICATION=\"Developer ID Application: MIND WEALTH (RC63N3VU27)\""
  echo "    Then re-run dev.sh."
  echo ""
fi

# 6. Launch the freshly-built .app (from its build dir — Debug builds depend on
#    PackageFrameworks/Myna.debug.dylib resolving via @rpath which only works
#    from this location, NOT from /Applications).
open "$APP"
echo "Launched: $APP"
