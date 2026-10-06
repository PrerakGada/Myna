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

echo "==> appcast sparkle:version wiring"
# Regression guard for the dead-appcast bug (v0.1.0..v0.4.6): release.yml
# omitted BUILD, appcast.sh defaulted it to 1, and every published item
# advertised build 1 against installed builds of 1..16 — so Sparkle never
# offered an update to anyone. Nothing failed visibly; only the XML was wrong.
assert_ok "release.yml passes BUILD to appcast.sh" \
  grep -q 'BUILD: ${{ steps.build.outputs.build }}' "$ROOT/.github/workflows/release.yml"
assert_ok "release.yml resolves BUILD from CURRENT_PROJECT_VERSION" \
  grep -q 'CURRENT_PROJECT_VERSION' "$ROOT/.github/workflows/release.yml"
assert_ok "appcast.sh emits sparkle:version from BUILD" \
  grep -q '<sparkle:version>\$BUILD</sparkle:version>' "$ROOT/dist/appcast.sh"
assert_ok "appcast.sh warns when BUILD is unset" \
  grep -q 'WARNING: BUILD unset' "$ROOT/dist/appcast.sh"
# The manual full-rebuild workflow had the same bug until 0.5.1 — running it
# would have re-stamped every item as build 1 and stopped all updates.
assert_ok "appcast.yml passes each DMG's own BUILD to appcast.sh" \
  grep -q 'BUILD="$build"' "$ROOT/.github/workflows/appcast.yml"
assert_ok "appcast.yml reads BUILD from the DMG's CFBundleVersion" \
  grep -q 'Print :CFBundleVersion' "$ROOT/.github/workflows/appcast.yml"
# The build number must actually be greater than the last shipped one, or the
# update is invisible even with correct wiring.
proj_build=$(grep -E '^[[:space:]]*CURRENT_PROJECT_VERSION:' "$ROOT/apps/macos/project.yml" | grep -oE '[0-9]+' | head -1)
if [ -n "$proj_build" ] && [ "$proj_build" -ge 16 ]; then
  printf '  ok   CURRENT_PROJECT_VERSION resolves (%s)\n' "$proj_build"
  pass=$((pass+1))
else
  printf '  FAIL CURRENT_PROJECT_VERSION unreadable or stale (got %s)\n' "${proj_build:-none}" >&2
  fail=$((fail+1))
  failed_scripts+=("project.yml build number")
fi

echo "==> setup.sh --update-daemon on a Homebrew install"
# Sparkle updates the app, but a Homebrew install's daemon is the myna-daemon
# formula; --update-daemon must brew-upgrade it and restart a running service.
# Stubs: a fake Homebrew prefix (brew + opt/ link) and launchctl on PATH, and a
# static file server standing in for the daemon's /v2/health.
BREW_T="$(mktemp -d)"
mkdir -p "$BREW_T/prefix/bin" "$BREW_T/prefix/Cellar/myna-daemon/0.5.1" \
         "$BREW_T/prefix/Cellar/myna-daemon/0.5.2" "$BREW_T/stubs" "$BREW_T/www/v2"
touch "$BREW_T/www/v2/health"
cat > "$BREW_T/prefix/bin/brew" <<'SH'
#!/bin/bash
echo "brew $*" >> "$STUB_LOG"
case "$1" in
  upgrade)
    [ "${STUB_UPGRADE:-move}" = "fail" ] && exit 1
    [ "${STUB_UPGRADE:-move}" = "move" ] && ln -sfn ../Cellar/myna-daemon/0.5.2 "$(dirname "$0")/../opt/myna-daemon"
    exit 0 ;;
esac
exit 0
SH
cat > "$BREW_T/stubs/launchctl" <<'SH'
#!/bin/bash
echo "launchctl $*" >> "$STUB_LOG"
[ "$1" = "print" ] && [ "${STUB_LOADED:-1}" = "0" ] && exit 113
exit 0
SH
chmod +x "$BREW_T/prefix/bin/brew" "$BREW_T/stubs/launchctl"
health_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server "$health_port" --bind 127.0.0.1 --directory "$BREW_T/www" >/dev/null 2>&1 &
health_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf "http://127.0.0.1:$health_port/v2/health" >/dev/null && break; sleep 0.2; done
# brew_update_case <upgrade: move|none|fail> <service loaded: 1|0>; sets rc + STUB_LOG.
brew_update_case() {
  mkdir -p "$BREW_T/prefix/opt"
  ln -sfn ../Cellar/myna-daemon/0.5.1 "$BREW_T/prefix/opt/myna-daemon"
  export STUB_LOG="$BREW_T/log-$1-$2"; : > "$STUB_LOG"
  rc=0
  STUB_UPGRADE="$1" STUB_LOADED="$2" MYNA_PORT="$health_port" \
    PATH="$BREW_T/prefix/bin:$BREW_T/stubs:/usr/bin:/bin:/usr/sbin:/sbin" \
    bash "$DIST/setup.sh" --update-daemon > "$STUB_LOG.out" 2>&1 || rc=$?
}
brew_update_case move 1
assert_ok "new formula + running service: upgrades, restarts, exits 0" \
  bash -c "[ $rc = 0 ] && grep -q 'brew upgrade prerakgada/tap/myna-daemon' '$STUB_LOG' \
    && grep -q 'brew services restart myna-daemon' '$STUB_LOG' && grep -q 'Daemon 0.5.2' '$STUB_LOG.out'"
brew_update_case none 1
assert_ok "nothing newer in the tap: no restart" \
  bash -c "[ $rc = 0 ] && grep -q 'brew upgrade' '$STUB_LOG' && ! grep -q 'services restart' '$STUB_LOG'"
brew_update_case move 0
assert_ok "service stopped by the user: upgraded but not started" \
  bash -c "[ $rc = 0 ] && grep -q 'brew upgrade' '$STUB_LOG' && ! grep -q 'services' '$STUB_LOG'"
brew_update_case fail 1
assert_ok "brew upgrade fails: exits non-zero with the manual command" \
  bash -c "[ $rc != 0 ] && grep -q 'brew upgrade prerakgada/tap/myna-daemon' '$STUB_LOG.out'"
# An engine installed by an older Myna (mlx-audio below the 0.5.7 pin) must be
# upgraded in place, and the service restarted even when the formula didn't
# move, since the engine runs as the daemon's child. Fake HOME holding a stub
# engine python (stale until uv "installs") and a stub pinned uv.
ENG_HOME="$BREW_T/home"
mkdir -p "$ENG_HOME/.venvs/mlx-audio/bin" "$ENG_HOME/Library/Application Support/Myna/runtime/uv-0.12.9"
cat > "$ENG_HOME/.venvs/mlx-audio/bin/python" <<'SH'
#!/bin/bash
[ "$1" = "-c" ] && [ "$2" = "import sys" ] && exit 0
[ "$1" = "-" ] && cat >/dev/null
[ -f "$HOME/engine-upgraded" ]
SH
cat > "$ENG_HOME/Library/Application Support/Myna/runtime/uv-0.12.9/uv" <<'SH'
#!/bin/bash
echo "uv $*" >> "$STUB_LOG"
touch "$HOME/engine-upgraded"
SH
chmod +x "$ENG_HOME/.venvs/mlx-audio/bin/python" "$ENG_HOME/Library/Application Support/Myna/runtime/uv-0.12.9/uv"
HOME="$ENG_HOME" brew_update_case none 1
assert_ok "stale engine: upgraded to the pinned stack, service restarted" \
  bash -c "[ $rc = 0 ] && grep -q 'uv pip install.*mlx-audio\[server\]>=0.5.7' '$STUB_LOG' \
    && grep -q 'brew services restart myna-daemon' '$STUB_LOG'"
rm -f "$ENG_HOME/engine-upgraded"
printf '#!/bin/bash\necho "uv $*" >> "$STUB_LOG"; exit 1\n' \
  > "$ENG_HOME/Library/Application Support/Myna/runtime/uv-0.12.9/uv"
HOME="$ENG_HOME" brew_update_case none 1
assert_ok "engine upgrade fails: warns, daemon update still exits 0, no restart" \
  bash -c "[ $rc = 0 ] && grep -q 'couldn.t upgrade the voice engine' '$STUB_LOG.out' \
    && ! grep -q 'services restart' '$STUB_LOG'"
kill "$health_pid" 2>/dev/null || true
wait "$health_pid" 2>/dev/null || true
rm -rf "$BREW_T"

echo
if [ "$fail" -eq 0 ]; then
  printf '==> %d pass, %d fail — OK\n' "$pass" "$fail"
  exit 0
else
  printf '==> %d pass, %d fail\n' "$pass" "$fail" >&2
  printf 'failed: %s\n' "${failed_scripts[*]}" >&2
  exit 1
fi
