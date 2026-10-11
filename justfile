# Myna — task runner.  `just` with no args lists everything.
#
# 5 parts: apps/macos (Swift) · daemon/myna (Python) · site (Next.js)
#          cli/myna (bash) · dist+tap+workflows (release ops)

set shell := ["bash", "-uc"]
set positional-arguments

repo        := justfile_directory()
macos       := repo / "apps/macos"
daemon_port := env_var_or_default("MYNA_PORT", "8766")
engine_port := env_var_or_default("MYNA_ENGINE_PORT", "8765")

# Signing identity for the dev loop. Without it dev.sh ad-hoc-signs the Debug
# build, TCC treats it as a different app, and text capture silently fails —
# the single most misleading footgun in this repo. Override via env if needed.
signing_id := env_var_or_default("DEVELOPER_ID_APPLICATION", "Developer ID Application: MIND WEALTH (RC63N3VU27)")

app_log    := env_var("HOME") / "Library/Logs/Myna/myna.log"
engine_log := env_var("HOME") / "Library/Logs/myna-engine.log"
daemon_log := "/opt/homebrew/var/log/myna-daemon.log"

_default:
    @just --list --unsorted

# ─────────────────────────────────────────────────────────────────────
# Run — the app dev loop
#
# No hot reload here: a signed AppKit binary can't swap code in place.
# The loop is stop → build → sign → relaunch, ~9s (4s of it compiling).
# ─────────────────────────────────────────────────────────────────────

# Build, sign with Developer ID, launch the app — the main dev loop
start:
    @DEVELOPER_ID_APPLICATION="{{signing_id}}" bash {{macos}}/dev.sh

# Quit the running app (Debug build or installed Release)
stop:
    -@pkill -f "Myna.app/Contents/MacOS/Myna" && echo "stopped" || echo "not running"

# Stop, rebuild, relaunch
restart: stop start

# Rebuild + relaunch on every Swift save (auto-restart, not hot reload)
watch:
    @command -v watchexec >/dev/null || { echo "needs watchexec — brew install watchexec"; exit 1; }
    @echo "── watching {{macos}}/Sources · saves trigger a ~9s rebuild+relaunch · Ctrl-C to exit ──"
    @watchexec --exts swift --debounce 1s --on-busy-update=queue \
      --watch {{macos}}/Sources -- just start

# Watch app AND daemon together in one terminal (only needed when editing both)
watch-all:
    #!/usr/bin/env bash
    set -uo pipefail
    torn_down=0
    cleanup() {
      [ "$torn_down" = 1 ] && return 0
      torn_down=1
      echo ""
      echo "── stopping watchers, restoring the brew daemon ──"
      pkill -f "watchexec --exts swift" 2>/dev/null || true
      pkill -f "myna.app:create_app" 2>/dev/null || true
      brew services start myna-daemon >/dev/null 2>&1 || true
      echo "── done; \`just ps\` to confirm ──"
    }
    trap 'cleanup; exit 0' INT TERM
    trap cleanup EXIT
    # Sequenced, not raced: daemon-watch stops the brew service and starts the
    # engine, and that churn force-stops the Swift watcher's first build if
    # both come up at once.
    just daemon-watch &
    for _ in $(seq 60); do
      curl -sf -m 1 "http://127.0.0.1:{{daemon_port}}/v2/health" >/dev/null 2>&1 && break
      sleep 1
    done
    just watch &
    wait

# Debug build only — no sign, no launch
build:
    cd {{macos}} && xcodegen generate >/dev/null && xcodebuild \
      -scheme Myna -configuration Debug -destination 'platform=macOS' \
      -derivedDataPath build \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      build 2>&1 | tail -5

# Regenerate Myna.xcodeproj from project.yml
gen:
    cd {{macos}} && xcodegen generate

# Open the project in Xcode
xcode: gen
    open {{macos}}/Myna.xcodeproj

# Launch the installed /Applications release build
run-release:
    open -a /Applications/Myna.app

# Wipe Swift build artifacts
clean:
    rm -rf {{macos}}/build {{macos}}/.build {{macos}}/DerivedData

# ─────────────────────────────────────────────────────────────────────
# Debug
# ─────────────────────────────────────────────────────────────────────

# Daemon + engine reachability (exit 1 if either is down)
doctor:
    @bash {{repo}}/cli/myna doctor

# Full daemon status: state, engine, config, recent registry
status:
    @curl -sf -m 3 http://127.0.0.1:{{daemon_port}}/v2/status | python3 -m json.tool

# One-line health check
health:
    @curl -sf -m 3 http://127.0.0.1:{{daemon_port}}/v2/health | python3 -m json.tool

# Speak text through the daemon — `just speak "hello world"`
speak *TEXT:
    @bash {{repo}}/cli/myna "$@"

# Speak a summary instead of the full text
speak-summary *TEXT:
    @bash {{repo}}/cli/myna --summary "$@"

# Stop whatever is currently being read aloud
stop-playback:
    @curl -sf -X POST http://127.0.0.1:{{daemon_port}}/stop >/dev/null && echo "playback stopped"

# Available voices
voices:
    @curl -sf -m 5 http://127.0.0.1:{{daemon_port}}/v2/voices | python3 -m json.tool

# Recent Claude Code announcements the app can replay
registry:
    @curl -sf -m 3 http://127.0.0.1:{{daemon_port}}/v2/registry/list | python3 -m json.tool

# Tail the app log
logs:
    tail -f {{app_log}}

# Tail the daemon log (brew service stdout+stderr)
logs-daemon:
    tail -f {{daemon_log}}

# Tail the voice engine log
logs-engine:
    tail -f {{engine_log}}

# Tail app + daemon + engine together, prefixed
logs-all:
    @tail -f {{app_log}} {{daemon_log}} {{engine_log}}

# Floating-pill UserDefaults state (position anchor, visibility)
pill:
    @defaults read dev.myna.app 2>/dev/null | grep -iE "pill" || echo "no pill keys set (all defaults)"

# Clear the saved pill position anchor
pill-reset:
    -@defaults delete dev.myna.app dev.myna.app.pillAnchor.present 2>/dev/null
    -@defaults delete dev.myna.app dev.myna.app.pillAnchor.displayID 2>/dev/null
    -@defaults delete dev.myna.app dev.myna.app.pillAnchor.fx 2>/dev/null
    -@defaults delete dev.myna.app dev.myna.app.pillAnchor.fy 2>/dev/null
    -@defaults delete dev.myna.app "NSWindow Frame dev.myna.app.pillFrame" 2>/dev/null
    @echo "pill anchor cleared — restart the app"

# Dump every app preference
defaults-dump:
    @defaults read dev.myna.app

# Daemon config overrides (~/.config/myna/config.json)
config:
    @if [ -s ~/.config/myna/config.json ]; then python3 -m json.tool ~/.config/myna/config.json; \
     else echo "no ~/.config/myna/config.json — running pure defaults (daemon/myna/config.py)"; fi

# ─────────────────────────────────────────────────────────────────────
# Services — daemon supervises the engine as a child (one brew service)
# ─────────────────────────────────────────────────────────────────────

# Start the daemon service
daemon-start:
    brew services start myna-daemon

# Stop the daemon service (also stops the engine child)
daemon-stop:
    brew services stop myna-daemon

# Restart the daemon service
daemon-restart:
    brew services restart myna-daemon

# What's actually running, on which ports
ps:
    @echo "── brew service ──"
    @brew services list | grep -i myna || echo "  none"
    @echo "── processes ──"
    @pgrep -fl "python.*-m myna|mlx_audio.server|Myna.app/Contents/MacOS/Myna" || echo "  none"
    @echo "── ports ──"
    @lsof -nP -iTCP:{{daemon_port}},{{engine_port}} -sTCP:LISTEN 2>/dev/null || echo "  nothing listening"

# Hot-reload the daemon from source — reloads on every .py save (Ctrl-C to exit)
daemon-watch:
    #!/usr/bin/env bash
    set -euo pipefail
    brew services stop myna-daemon 2>/dev/null || true
    just engine
    echo "── daemon :{{daemon_port}} hot-reloads on save · engine stays warm ──"
    echo "── Ctrl-C, then \`just daemon-start\` to restore the brew service ──"
    cd {{repo}}
    # No MYNA_ENGINE_AUTOSTART: the reload daemon must never own the engine,
    # or every reload would kill and respawn it.
    exec uv run --quiet --with-editable ./daemon \
      uvicorn --factory myna.app:create_app --reload --reload-dir {{repo}}/daemon/myna \
      --timeout-graceful-shutdown 2 --host 127.0.0.1 --port {{daemon_port}}

# Run the daemon in the foreground from source, no reload (owns the engine)
daemon-fg:
    @brew services stop myna-daemon 2>/dev/null || true
    @echo "── foreground daemon; Ctrl-C then \`just daemon-start\` to restore ──"
    cd {{repo}} && MYNA_ENGINE_AUTOSTART=1 uv run --with-editable ./daemon python -m myna

# Start the voice engine standalone so it survives daemon reloads
engine:
    #!/usr/bin/env bash
    set -euo pipefail
    if curl -sf -m 2 "http://127.0.0.1:{{engine_port}}/v1/models" >/dev/null 2>&1; then
      echo "engine already up on :{{engine_port}}"; exit 0
    fi
    py="$HOME/.venvs/mlx-audio/bin/python"
    [ -x "$py" ] || { echo "engine venv missing — run \`just setup\`"; exit 1; }
    # Same espeak env EngineSupervisor._engine_env injects; without it Kokoro's
    # phonemizer 502s on every synth.
    export PHONEMIZER_ESPEAK_LIBRARY="$("$py" -c 'import espeakng_loader as e; print(e.get_library_path())')"
    export ESPEAK_DATA_PATH="$("$py" -c 'import espeakng_loader as e; print(e.get_data_path())')"
    # Via engine_shim.py, same as EngineSupervisor — it patches Kokoro's
    # SineGen length bug, without which ~1/3 of sentences 502.
    nohup "$py" {{repo}}/daemon/myna/engine_shim.py --host 127.0.0.1 --port {{engine_port}} >> "{{engine_log}}" 2>&1 &
    for _ in $(seq 30); do
      if curl -sf -m 1 "http://127.0.0.1:{{engine_port}}/v1/models" >/dev/null 2>&1; then
        echo "engine up on :{{engine_port}}"; exit 0
      fi
      sleep 0.5
    done
    echo "engine did not come up — tail {{engine_log}}"; exit 1

# Stop a standalone engine started by `just engine`
engine-stop:
    -@pkill -f "mlx_audio.server" && echo "engine stopped" || echo "not running"

# Install the engine venv, model, CC hook, launchagent
setup:
    bash {{repo}}/dist/setup.sh

# ─────────────────────────────────────────────────────────────────────
# Test & lint
# ─────────────────────────────────────────────────────────────────────

# Everything CI runs, in CI's order — run this before pushing
ci: lint build test-swift-ci test-daemon test-dist
    @echo "✅ all CI jobs pass locally"

# Swift + daemon + dist tests
test: test-swift test-daemon test-dist

# Swift tests, full suite (audio + toast suites work locally, unlike CI)
test-swift: gen
    cd {{macos}} && xcodebuild test -scheme Myna \
      -destination 'platform=macOS' -derivedDataPath build \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      2>&1 | tail -20

# Swift tests with CI's skips (AudioPlayer + CCToast need a window server / audio device)
test-swift-ci: gen
    cd {{macos}} && xcodebuild test -scheme Myna \
      -destination 'platform=macOS' -derivedDataPath build \
      -skip-testing:MynaTests/AudioPlayerTests \
      -skip-testing:MynaTests/CCToastControllerTests \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      2>&1 | tail -20

# One Swift suite — `just test-swift-only PillStateTests`
test-swift-only SUITE: gen
    cd {{macos}} && xcodebuild test -scheme Myna \
      -destination 'platform=macOS' -derivedDataPath build \
      -only-testing:MynaTests/{{SUITE}} \
      CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
      2>&1 | tail -20

# Daemon tests (uv resolves pytest — no venv to manage)
test-daemon *ARGS:
    cd {{repo}} && uv run --quiet --with pytest --with pytest-asyncio \
      --with-editable ./daemon pytest daemon/tests -q "$@"

# dist/ release-script smoke tests
test-dist:
    bash {{repo}}/dist/tests/test_scripts.sh

# SwiftLint, strict — this is the gate CI enforces
lint:
    cd {{macos}} && swiftlint --strict

# Violations only, grouped by rule
lint-report:
    @cd {{macos}} && swiftlint --strict 2>&1 | grep "error:" \
      | sed -E 's/.*\(([a-z_]+)\)$/\1/' | sort | uniq -c | sort -rn

# Autocorrect what SwiftLint can fix mechanically
lint-fix:
    cd {{macos}} && swiftlint --fix && swiftlint --strict

# Validate the GitHub workflow YAML
lint-workflows:
    @uv run --quiet --with pyyaml python3 -c \
      "import yaml, glob; [yaml.safe_load(open(f)) for f in glob.glob('{{repo}}/.github/workflows/*.yml')]" \
      && echo "workflows parse clean"

# ─────────────────────────────────────────────────────────────────────
# Site (Next.js)
# ─────────────────────────────────────────────────────────────────────

# Dev server
site:
    cd {{repo}}/site && npm run dev

site-build:
    cd {{repo}}/site && npm run build

# Lint + typecheck
site-check:
    cd {{repo}}/site && npm run lint && npm run typecheck

# ─────────────────────────────────────────────────────────────────────
# Release
# ─────────────────────────────────────────────────────────────────────

# Current version across all three files
version:
    @printf 'app     %s (build %s)\n' \
      "$(grep -E 'MARKETING_VERSION:' {{macos}}/project.yml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" \
      "$(grep -E 'CURRENT_PROJECT_VERSION:' {{macos}}/project.yml | grep -oE '[0-9]+')"
    @printf 'daemon  %s\n' "$(grep -E '^version' {{repo}}/daemon/pyproject.toml | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    @printf 'module  %s\n' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' {{repo}}/daemon/myna/__init__.py)"
    @printf 'latest tag  %s\n' "$(git -C {{repo}} describe --tags --abbrev=0)"

# Bump version in project.yml + pyproject + __init__ (edits only — no commit)
bump VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    build=$(grep -E 'CURRENT_PROJECT_VERSION:' {{macos}}/project.yml | grep -oE '[0-9]+')
    next=$((build + 1))
    sed -i '' -E 's/^( *MARKETING_VERSION: ).*/\1"{{VERSION}}"/'      {{macos}}/project.yml
    sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: ).*/\1\"${next}\"/"  {{macos}}/project.yml
    sed -i '' -E 's/^version = .*/version = "{{VERSION}}"/'           {{repo}}/daemon/pyproject.toml
    sed -i '' -E 's/^__version__ = .*/__version__ = "{{VERSION}}"/'   {{repo}}/daemon/myna/__init__.py
    echo "bumped to {{VERSION}} (build ${build} -> ${next})"
    git -C {{repo}} --no-pager diff --stat
    echo
    echo "next: update apps/macos/Resources/changelogs/, commit, then \`just release-push {{VERSION}}\`"

# Tag and push a release — triggers the signing/notarizing pipeline
release-push VERSION:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{repo}}
    [ -z "$(git status --porcelain)" ] || { echo "working tree dirty — commit the release bump first"; exit 1; }
    echo "HEAD: $(git log -1 --oneline)"
    read -rp "tag v{{VERSION}} and push to origin? [y/N] " ok
    [ "$ok" = y ] || { echo "aborted"; exit 1; }
    git tag "v{{VERSION}}"
    git push origin main --tags
    echo "watch: just release-watch"

# Watch the running release workflow
release-watch:
    gh run watch $(gh run list --workflow release.yml --limit 1 --json databaseId -q '.[0].databaseId')

# Why CI is red right now
ci-status:
    @gh run list --limit 5

# Verify the installed app is properly signed, notarized, stapled
verify-install:
    @spctl --assess --type execute --verbose=2 /Applications/Myna.app
    @codesign --verify --deep --strict --verbose=2 /Applications/Myna.app
    @stapler validate /Applications/Myna.app
    @defaults read /Applications/Myna.app/Contents/Info.plist CFBundleShortVersionString
