#!/usr/bin/env bash
# karaoke/build.sh — build MynaKaraoke sidecar, wrap into .app, sign.
#
# Outputs:
#   karaoke/MynaKaraoke.app  — signed if DEVELOPER_ID_APPLICATION is set
#
# Usage:
#   bash karaoke/build.sh [--dry-run] [--help]
#
# Env:
#   DEVELOPER_ID_APPLICATION  — codesign identity (optional; skip-sign if unset)
#   KEYCHAIN_PATH             — optional specific keychain
#   VERSION                   — marketing version (default: read from Info.plist)
#
# Notes:
#   - arm64-only (mlx-audio is Apple Silicon only).
#   - Output .app is signed at this layer; dist/sign.sh ditto's it into
#     Myna.app/Contents/Resources/ WITHOUT re-signing the sidecar.
#   - Outer Myna.app sign re-seals the nested bundle hash; that's expected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- arg parsing ----------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
  esac
done

# --- logging helpers ------------------------------------------------------
log()  { printf '==> %s\n' "$*" >&2; }
ok()   { printf ' ok  %s\n' "$*" >&2; }
warn() { printf ' WARN %s\n' "$*" >&2; }
die()  { printf ' FAIL %s\n' "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf ' DRY %s\n' "$*" >&2
  else
    eval "$@"
  fi
}

# --- main -----------------------------------------------------------------
cd "$SCRIPT_DIR"

APP_NAME="MynaKaraoke"
APP="${APP_NAME}.app"

log "karaoke/build.sh — wrapping ${APP_NAME} for arm64"

# 1. swift build (release, arm64 only).
if [ "$DRY_RUN" = "1" ]; then
  printf ' DRY swift build -c release --arch arm64\n' >&2
else
  command -v swift >/dev/null 2>&1 \
    || die "swift toolchain not found on PATH"
  swift build -c release --arch arm64
fi

# 2. Locate built binary.
BIN_PATH=".build/release/${APP_NAME}"
if [ "$DRY_RUN" != "1" ]; then
  [ -f "$BIN_PATH" ] || die "expected built binary at ${BIN_PATH}"
fi

# 3. Wrap into .app skeleton.
run "rm -rf '${APP}'"
run "mkdir -p '${APP}/Contents/MacOS' '${APP}/Contents/Resources'"
run "cp '${BIN_PATH}' '${APP}/Contents/MacOS/${APP_NAME}'"
run "cp 'Resources/Info.plist' '${APP}/Contents/Info.plist'"
run "chmod +x '${APP}/Contents/MacOS/${APP_NAME}'"

# 4. Sign (only if DEVELOPER_ID_APPLICATION is set).
if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
  keychain_arg=""
  if [ -n "${KEYCHAIN_PATH:-}" ]; then
    keychain_arg="--keychain '${KEYCHAIN_PATH}'"
  fi

  ENTITLEMENTS_PATH="${SCRIPT_DIR}/karaoke.entitlements"
  [ -f "$ENTITLEMENTS_PATH" ] || die "no entitlements at ${ENTITLEMENTS_PATH}"

  # Sign the inner binary first, then the .app bundle.
  # --options runtime: hardened runtime is mandatory for notarization.
  # --timestamp: secure timestamp from Apple's TSA.
  run "codesign --force --options runtime --timestamp \
    $keychain_arg \
    --entitlements '${ENTITLEMENTS_PATH}' \
    --sign '${DEVELOPER_ID_APPLICATION}' \
    '${APP}/Contents/MacOS/${APP_NAME}'"

  run "codesign --force --options runtime --timestamp \
    $keychain_arg \
    --entitlements '${ENTITLEMENTS_PATH}' \
    --sign '${DEVELOPER_ID_APPLICATION}' \
    '${APP}'"

  run "codesign --verify --strict --verbose=2 '${APP}'"
  ok "signed ${APP}"
else
  warn "DEVELOPER_ID_APPLICATION unset — skipping sign (ad-hoc bundle only)"
fi

# 5. Sanity check Info.plist.
if [ "$DRY_RUN" != "1" ]; then
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
                "${APP}/Contents/Info.plist" 2>/dev/null || echo "?")
  short_ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                "${APP}/Contents/Info.plist" 2>/dev/null || echo "?")
  ok "built ${SCRIPT_DIR}/${APP} (bundle_id=${bundle_id}, version=${short_ver})"
else
  ok "dry-run complete"
fi
