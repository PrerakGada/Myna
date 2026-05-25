#!/usr/bin/env bash
# dist/sign.sh — codesign Myna.app with Developer ID, hardened runtime, timestamp.
#
# Inputs (env):
#   DEVELOPER_ID_APPLICATION  — e.g. "Developer ID Application: Rashid Azar (TEAMID)"
#   KEYCHAIN_PATH             — optional; specific keychain holding the cert
#   APP_PATH                  — optional; default dist/export/Myna.app
#
# Usage:
#   dist/sign.sh [--dry-run] [--help]
#
# Notes:
#   - Hardened runtime is required for notarization.
#   - --timestamp requires a network round-trip to Apple's TSA.
#   - We sign deeply (nested frameworks like Sparkle.framework get re-signed),
#     and explicitly pass --entitlements pointing at Myna.entitlements so the
#     same flags set by Xcode at archive time are preserved.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$SCRIPT_DIR/_lib.sh"

SCRIPT_HELP="$(sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d')"
parse_common_args "$@"

ROOT="$(repo_root)"
APP_PATH="${APP_PATH:-$ROOT/dist/export/Myna.app}"
ENTITLEMENTS="$ROOT/apps/macos/Resources/Myna.entitlements"

log "sign.sh — app=$APP_PATH"

if [ "${DRY_RUN:-0}" != "1" ]; then
  require_cmd codesign
  require_env DEVELOPER_ID_APPLICATION
  [ -d "$APP_PATH" ]      || die "no .app at $APP_PATH (run dist/build.sh first)"
  [ -f "$ENTITLEMENTS" ]  || die "no entitlements at $ENTITLEMENTS"
fi

keychain_arg=""
if [ -n "${KEYCHAIN_PATH:-}" ]; then
  keychain_arg="--keychain '$KEYCHAIN_PATH'"
fi

# Sign nested helpers/frameworks first (Sparkle ships Autoupdate.app + XPCs).
# `codesign --deep` is no longer trusted as the only step; modern guidance is
# to sign each nested executable individually.
if [ "${DRY_RUN:-0}" != "1" ]; then
  # Discover everything that needs signing inside the bundle (depth-first).
  mapfile -t targets < <(find "$APP_PATH/Contents" \
    \( -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.app' \) \
    -print | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)
  for t in "${targets[@]}"; do
    [ "$t" = "$APP_PATH" ] && continue
    log "sign nested: $t"
    # shellcheck disable=SC2086
    codesign --force --options runtime --timestamp \
      $keychain_arg \
      --sign "$DEVELOPER_ID_APPLICATION" \
      "$t"
  done
else
  warn "dry-run: skipping nested-bundle discovery"
fi

# Sign the main app last (this seals the outer bundle hash).
run "codesign --force --options runtime --timestamp \
       $keychain_arg \
       --entitlements '$ENTITLEMENTS' \
       --sign '$DEVELOPER_ID_APPLICATION' \
       '$APP_PATH'"

# Verify.
run "codesign --verify --deep --strict --verbose=2 '$APP_PATH'"
run "spctl --assess --type execute --verbose=2 '$APP_PATH' || true"

ok "signed $APP_PATH"
