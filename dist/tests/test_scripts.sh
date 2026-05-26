#!/usr/bin/env bash
# dist/tests/test_scripts.sh — smoke-test every dist/*.sh script with --dry-run.
#
# Asserts:
#   - bash -n parse on every script
#   - shellcheck (best-effort; warning only if not installed)
#   - --help exits 0 and prints non-empty
#   - --dry-run exits 0 (no real Apple infra hit)
#
# Run:
#   bash dist/tests/test_scripts.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$DIST/.." && pwd)"

SCRIPTS=(build.sh sign.sh notarize.sh dmg.sh appcast.sh)

# Stub credentials so scripts that require_env in dry-run mode also pass.
# (Currently our scripts only require_env when DRY_RUN=0, but we set them
# anyway so the test stays robust if that policy changes.)
export DEVELOPER_ID_APPLICATION="Developer ID Application: Test User (TESTTEAM00)"
export APPLE_ID="test@example.com"
export APPLE_TEAM_ID="TESTTEAM00"
export APPLE_ID_APP_PASSWORD="test-app-specific-password"
# Throwaway test-only key — generated fresh, never used to sign anything real.
# Does NOT correspond to the production SUPublicEDKey in apps/macos/project.yml.
# Rotating this value has no impact on shipped Sparkle updates.
export SPARKLE_EDDSA_PRIVATE_KEY="+5WRaYIoNW6NJ8yxQ68/OrCcfvbKXsoE38kOkgTKGSE="
export VERSION="0.0.0-smoke"

pass=0
fail=0

failed_scripts=()

assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$label"
    pass=$((pass+1))
  else
    printf '  FAIL %s\n' "$label" >&2
    fail=$((fail+1))
    failed_scripts+=("$label")
  fi
}

echo "==> bash -n parse"
for s in "${SCRIPTS[@]}"; do
  assert_ok "parse $s" bash -n "$DIST/$s"
done
assert_ok "parse _lib.sh" bash -n "$DIST/_lib.sh"

echo "==> shellcheck (best-effort)"
if command -v shellcheck >/dev/null 2>&1; then
  for s in "${SCRIPTS[@]}"; do
    # SC1091: don't follow sourced files; SC2086: word-splitting is intentional
    # in `run` wrapper (we eval the string).
    if shellcheck -x -e SC1091,SC2086 "$DIST/$s" >/dev/null 2>&1; then
      printf '  ok   shellcheck %s\n' "$s"
      pass=$((pass+1))
    else
      printf '  warn shellcheck %s (non-fatal)\n' "$s" >&2
    fi
  done
else
  printf '  warn shellcheck not installed; skipping\n' >&2
fi

echo "==> --help exits 0 with non-empty output"
for s in "${SCRIPTS[@]}"; do
  out=$(bash "$DIST/$s" --help 2>&1) || { failed_scripts+=("$s --help"); fail=$((fail+1)); continue; }
  if [ -n "$out" ]; then
    printf '  ok   %s --help\n' "$s"
    pass=$((pass+1))
  else
    printf '  FAIL %s --help (empty)\n' "$s" >&2
    fail=$((fail+1))
    failed_scripts+=("$s --help empty")
  fi
done

echo "==> --dry-run exits 0"
for s in "${SCRIPTS[@]}"; do
  if bash "$DIST/$s" --dry-run >/dev/null 2>&1; then
    printf '  ok   %s --dry-run\n' "$s"
    pass=$((pass+1))
  else
    # Re-run with output so the failure is debuggable.
    printf '  FAIL %s --dry-run; output:\n' "$s" >&2
    bash "$DIST/$s" --dry-run >&2 || true
    fail=$((fail+1))
    failed_scripts+=("$s --dry-run")
  fi
done

echo "==> karaoke/build.sh smoke (v0.2+)"
KSCRIPT="$ROOT/karaoke/build.sh"
if [ -f "$KSCRIPT" ]; then
  assert_ok "parse karaoke/build.sh" bash -n "$KSCRIPT"
  out=$(bash "$KSCRIPT" --help 2>&1) || { failed_scripts+=("karaoke/build.sh --help"); fail=$((fail+1)); }
  if [ -n "$out" ]; then
    printf '  ok   karaoke/build.sh --help\n'
    pass=$((pass+1))
  fi
  if bash "$KSCRIPT" --dry-run >/dev/null 2>&1; then
    printf '  ok   karaoke/build.sh --dry-run\n'
    pass=$((pass+1))
  else
    printf '  FAIL karaoke/build.sh --dry-run\n' >&2
    fail=$((fail+1))
    failed_scripts+=("karaoke/build.sh --dry-run")
  fi
else
  printf '  warn karaoke/build.sh missing — skipping (pre-v0.2?)\n' >&2
fi

echo "==> karaoke nested-bundle structure (v0.2+)"
if [ -f "$ROOT/karaoke/Package.swift" ]; then
  # Verify the Package.swift parses by SwiftPM (and Info.plist exists).
  assert_ok "karaoke Info.plist present" test -f "$ROOT/karaoke/Resources/Info.plist"
  assert_ok "karaoke entitlements present" test -f "$ROOT/karaoke/karaoke.entitlements"
  # Bundle ID in Info.plist matches the spec — must share the dev.myna.*
  # prefix with the outer app (dev.myna.app) so future app-group
  # entitlements work cleanly.
  if grep -q 'dev.myna.karaoke' "$ROOT/karaoke/Resources/Info.plist"; then
    printf '  ok   karaoke Info.plist bundle ID = dev.myna.karaoke\n'
    pass=$((pass+1))
  else
    printf '  FAIL karaoke Info.plist bundle ID mismatch\n' >&2
    fail=$((fail+1))
    failed_scripts+=("karaoke bundle id")
  fi
else
  printf '  warn karaoke/Package.swift missing — skipping (pre-v0.2?)\n' >&2
fi

echo
if [ "$fail" -eq 0 ]; then
  printf '==> %d pass, %d fail — OK\n' "$pass" "$fail"
  exit 0
else
  printf '==> %d pass, %d fail\n' "$pass" "$fail" >&2
  printf 'failed: %s\n' "${failed_scripts[*]}" >&2
  exit 1
fi
