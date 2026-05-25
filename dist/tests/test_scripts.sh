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

SCRIPTS=(build.sh sign.sh notarize.sh dmg.sh appcast.sh)

# Stub credentials so scripts that require_env in dry-run mode also pass.
# (Currently our scripts only require_env when DRY_RUN=0, but we set them
# anyway so the test stays robust if that policy changes.)
export DEVELOPER_ID_APPLICATION="Developer ID Application: Test User (TESTTEAM00)"
export APPLE_ID="test@example.com"
export APPLE_TEAM_ID="TESTTEAM00"
export APPLE_ID_APP_PASSWORD="test-app-specific-password"
export SPARKLE_EDDSA_PRIVATE_KEY="VB1oLQU4trMsELZLWQXBQQ0NcZYHF/HpBs+4t0K6N3U="
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

echo
if [ "$fail" -eq 0 ]; then
  printf '==> %d pass, %d fail — OK\n' "$pass" "$fail"
  exit 0
else
  printf '==> %d pass, %d fail\n' "$pass" "$fail" >&2
  printf 'failed: %s\n' "${failed_scripts[*]}" >&2
  exit 1
fi
