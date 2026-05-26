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

  # ---------------------------------------------------------------------------
  # Sparkle.framework needs Sparkle-aware handling.
  #
  # Sparkle 2 ships a framework whose bundle is unusual: it has BOTH a flat
  # layout (Sparkle.framework/Updater.app, Sparkle.framework/XPCServices/...)
  # AND a versioned layout (Versions/B/Updater.app, Versions/Current → B).
  # When Xcode embeds it via SPM and runs embed-and-sign, the symlinks get
  # dereferenced and you end up with three real copies of each helper —
  # signing all three from a generic find loop wedges the framework's internal
  # structure and codesign refuses the root with:
  #   "bundle format is ambiguous (could be app or framework)"
  #
  # Sparkle's official recommendation: sign only what's inside Versions/B
  # (the "current" Version), bottom-up, then sign Versions/B itself, then sign
  # the framework root. Exclude this framework from the generic loop below.
  # ---------------------------------------------------------------------------
  sign_sparkle() {
    local sparkle="$1"
    [ -d "$sparkle" ] || return 0
    local current_ver="B"
    if [ -L "$sparkle/Versions/Current" ]; then
      current_ver=$(readlink "$sparkle/Versions/Current")
    fi
    log "sparkle: detected current version = $current_ver"
    local ver_dir="$sparkle/Versions/$current_ver"

    # Sign Versions/B/* bottom-up, NOT --deep. These are the canonical
    # binaries codesign expects to be individually signed.
    for inner in \
      "$ver_dir/Autoupdate" \
      "$ver_dir/Updater.app/Contents/MacOS/Autoupdate" \
      "$ver_dir/XPCServices/Downloader.xpc" \
      "$ver_dir/XPCServices/Installer.xpc" \
      "$ver_dir/Updater.app" \
      "$ver_dir"
    do
      if [ -e "$inner" ]; then
        log "sparkle sign: $inner"
        # shellcheck disable=SC2086
        codesign --force --options runtime --timestamp \
          $keychain_arg \
          --sign "$DEVELOPER_ID_APPLICATION" \
          "$inner"
      fi
    done

    # Framework root: Xcode's embed-and-sign on CI flattens Sparkle's
    # top-level symlinks (Updater.app, XPCServices/, etc.) into real
    # duplicate directories. Codesign then refuses the root with
    # "bundle format is ambiguous (could be app or framework)" because
    # the bundle now contains both flat and versioned layouts.
    #
    # `--deep` here re-signs everything from the framework root with a
    # consistent designated requirement and resolves the ambiguity. This
    # is the documented Sparkle-shipping idiom and what Sparkle's own
    # codesign helper uses. Apple discourages --deep on FINAL APP sigs
    # (we don't use it on Myna.app), but it's the standard for embedded
    # versioned frameworks where Xcode's bundle handling diverges.
    log "sparkle sign (root, --deep): $sparkle"
    # shellcheck disable=SC2086
    codesign --force --deep --options runtime --timestamp \
      $keychain_arg \
      --sign "$DEVELOPER_ID_APPLICATION" \
      "$sparkle"
  }
  sign_sparkle "$APP_PATH/Contents/Frameworks/Sparkle.framework"

  # ---------------------------------------------------------------------------
  # Generic depth-first sign for everything else. Explicitly exclude Sparkle
  # (handled above) so we don't re-sign and re-break it.
  #
  # NOTE: `mapfile`/`readarray` is bash 4+; macOS GitHub Actions runners ship
  # bash 3.2 and bail with "command not found". Use a `while read` loop.
  # Per AUDIT_REPORT.md Lane B 🟡 #1.
  # ---------------------------------------------------------------------------
  targets=()
  while IFS= read -r t; do
    [ -n "$t" ] && targets+=("$t")
  done < <(find "$APP_PATH/Contents" \
    -not -path "*/Sparkle.framework*" \
    \( -name '*.framework' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.app' \) \
    -type d \
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
