#!/usr/bin/env bash
# dist/setup.sh — installs Myna's on-device voice stack.
#
# Who runs it:
#   • Myna.app's first-launch installer. The app bundles this script at
#     Myna.app/Contents/Resources/setup/setup.sh and streams its output into the
#     Setup window.
#   • `myna setup`, or ./dist/setup.sh from a checkout.
#
# What it installs, all inside your user account (no admin password, no
# Homebrew required):
#   check    Apple Silicon, macOS 14+, free disk space
#   runtime  uv (pinned, checksum-verified) and a private Python 3.13
#   engine   mlx-audio + the Kokoro G2P stack in ~/.venvs/mlx-audio (~600 MB)
#   service  the Myna daemon, which supervises the engine
#   model    the Kokoro-82M voice model (~340 MB, downloaded once)
#   claude   the Claude Code Stop + Notification hook, only if Claude Code is installed
#
# The daemon is managed one of two ways, picked automatically:
#   homebrew    the cask installed the `myna-daemon` formula; setup (re)starts
#               it with `brew services`.
#   standalone  no formula (the DMG download). Setup installs the daemon from
#               the source bundled inside Myna.app into ~/.venvs/myna-daemon and
#               runs it as the dev.myna.daemon LaunchAgent.
#   Override with MYNA_INSTALL_MODE=homebrew|standalone.
#
# Flags:
#   --update-daemon   bring the daemon up to this app's version and restart it.
#                     Standalone: reinstall from the bundled source. Homebrew:
#                     brew upgrade the formula. The app runs this after an update.
#
# Env:
#   MYNA_FORCE_ENGINE=1   reinstall the engine stack with --upgrade
#
# Output protocol, read by the app's installer UI (SetupController.swift):
#   @@step <id> <start|done|skip|fail> [detail]
#   ==> <human-readable progress>
#
# Idempotent: every step checks what is already there and reuses it.
set -Eeuo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo "")"
DAEMON_PORT="${MYNA_PORT:-8766}"
ENGINE_PORT="${MYNA_ENGINE_PORT:-8765}"
ENGINE_VENV="$HOME/.venvs/mlx-audio"
DAEMON_VENV="$HOME/.venvs/myna-daemon"
RUNTIME_DIR="$HOME/Library/Application Support/Myna/runtime"
AGENT_LABEL="dev.myna.daemon"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
# The executable the LaunchAgent runs; start_standalone_daemon swaps in the
# "Myna Voice" copy (see prepare_daemon_executable).
DAEMON_PROGRAM="$DAEMON_VENV/bin/python"
DAEMON_EXEC="$DAEMON_VENV/bin/Myna Voice"
BREW_LABEL="homebrew.mxcl.myna-daemon"
UID_NUM="$(id -u)"
PY_VERSION="3.13"
# uv is pinned and checksum-verified: it is the one binary this script downloads
# and runs directly. Bump both together.
UV_VERSION="0.12.9"
UV_SHA256="301f72afaf54060f92da7016cb0115bd077f43a9c8e39c1d8170a0bac80fd398"
export UV_PYTHON_INSTALL_DIR="$RUNTIME_DIR/python"

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*"; }

CURRENT_STEP=""
begin()  { CURRENT_STEP="$1"; shift; printf '@@step %s start %s\n' "$CURRENT_STEP" "$*"; }
finish() { printf '@@step %s done %s\n' "$CURRENT_STEP" "$*"; CURRENT_STEP=""; }
skip()   { printf '@@step %s skip %s\n' "$CURRENT_STEP" "$*"; CURRENT_STEP=""; }
# A failure that should not stop the rest of setup (the Claude Code hook).
soft_fail() { warn "$*"; printf '@@step %s fail %s\n' "$CURRENT_STEP" "$*"; CURRENT_STEP=""; }
die() {
  printf '\033[1;31mFAIL:\033[0m %s\n' "$*"
  [ -n "$CURRENT_STEP" ] && printf '@@step %s fail %s\n' "$CURRENT_STEP" "$*"
  exit 1
}
on_err() {
  local code=$?
  if [ -n "$CURRENT_STEP" ]; then
    printf '@@step %s fail setup stopped unexpectedly (line %s, exit %s)\n' "$CURRENT_STEP" "$1" "$code"
    CURRENT_STEP=""
  fi
}
trap 'on_err $LINENO' ERR

# ── what this Mac already has ────────────────────────────────────────────────

BREW=""
for b in "$(command -v brew 2>/dev/null || true)" /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -n "$b" ] && [ -x "$b" ]; then BREW="$b"; break; fi
done

BREW_FORMULA=0
if [ -n "$BREW" ] && [ -d "$(dirname "$(dirname "$BREW")")/opt/myna-daemon" ]; then
  BREW_FORMULA=1
fi
MODE="${MYNA_INSTALL_MODE:-}"
if [ -z "$MODE" ]; then
  if [ "$BREW_FORMULA" = "1" ]; then MODE="homebrew"; else MODE="standalone"; fi
fi
if [ "$MODE" = "standalone" ] && [ "$BREW_FORMULA" = "1" ]; then
  die "Homebrew's myna-daemon is installed, so Homebrew manages Myna here. Run: brew uninstall myna-daemon — then run setup again for a standalone install."
fi

# Daemon source: bundled beside this script inside Myna.app, or the checkout.
DAEMON_SRC=""
for c in "$SELF_DIR/daemon" "$SELF_DIR/../daemon"; do
  if [ -n "$SELF_DIR" ] && [ -f "$c/pyproject.toml" ] && [ -d "$c/myna" ]; then
    DAEMON_SRC="$(cd "$c" && pwd)"; break
  fi
done
BUNDLED_VERSION=""
if [ -n "$DAEMON_SRC" ]; then
  BUNDLED_VERSION="$(sed -n 's/^__version__ = "\(.*\)"$/\1/p' "$DAEMON_SRC/myna/__init__.py")"
fi
# Git ref for anything fetched from GitHub (only when not bundled).
if [ -n "$BUNDLED_VERSION" ]; then
  MYNA_REF="${MYNA_REF:-v$BUNDLED_VERSION}"
else
  MYNA_REF="${MYNA_REF:-main}"
fi

# A Python 3.13 already on the machine — only used if uv can't be downloaded.
PY=""
for c in python3.13 /opt/homebrew/bin/python3.13 "$HOME/.local/bin/python3.13"; do
  if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
done

# The full engine stack — `mlx-audio` alone is NOT enough to synthesize:
#   • [server] → uvicorn + fastapi + webrtcvad (mlx_audio.server imports these;
#                without it the engine crashes and the app shows "offline")
#   • misaki + num2words + spacy + phonemizer + espeakng-loader → Kokoro's G2P.
#                Without these /v1/models works but real TTS dies with
#                "Kokoro requires the optional 'misaki' package".
# spacy etc. are installed DIRECTLY (not via `misaki[en]`) because that extra
# pins old spacy/blis versions with no cp313 wheel that fail to compile.
#
# misaki is PINNED <0.8: mlx-audio declares no misaki constraint, so an unpinned
# install grabs the latest. misaki >=0.8 calls `EspeakWrapper.set_data_path()`,
# which the plain `phonemizer` we install does not have — Kokoro's G2P crashes
# at import and EVERY synthesize 502s. 0.7.x is the proven-good line.
#
# mlx-audio is pinned to the 0.5 line: the engine catalog (daemon/myna/engines.py)
# tunes each model's settings against 0.5.7, where the four engines were
# measured. sentencepiece is Pocket TTS's tokenizer; mlx-audio doesn't pull it.
ENGINE_PKGS=('mlx-audio[server]>=0.5.7,<0.6' 'misaki<0.8' num2words spacy phonemizer espeakng-loader sentencepiece)

engine_ready() {
  [ -x "$ENGINE_VENV/bin/python" ] || return 1
  "$ENGINE_VENV/bin/python" - <<'PY' >/dev/null 2>&1
import importlib.util as u, sys
need = ["mlx_audio", "misaki", "num2words", "spacy", "en_core_web_sm",
        "phonemizer", "espeakng_loader", "uvicorn", "fastapi", "webrtcvad",
        "sentencepiece"]
if not all(u.find_spec(m) is not None for m in need):
    sys.exit(1)
# The engine catalog is tuned against mlx-audio 0.5.7 (see ENGINE_PKGS); an
# older install from before the pin counts as stale so it gets upgraded.
from importlib.metadata import version
if tuple(int(p) for p in version("mlx-audio").split(".")[:3] if p.isdigit()) < (0, 5, 7):
    sys.exit(1)
# Functional gate, not just presence: the exact import that explodes with an
# incompatible misaki/phonemizer pair, so a broken install gets repaired.
try:
    import misaki.espeak  # noqa: F401
except Exception:
    sys.exit(1)
sys.exit(0)
PY
}

venv_ok() {
  [ -x "$1/bin/python" ] && "$1/bin/python" -c 'import sys' >/dev/null 2>&1
}

installed_daemon_version() {
  venv_ok "$DAEMON_VENV" || return 0
  "$DAEMON_VENV/bin/python" -c 'import myna; print(myna.__version__)' 2>/dev/null || true
}

daemon_up() { curl -sf -m 2 "http://127.0.0.1:${DAEMON_PORT}/v2/health" >/dev/null 2>&1; }
engine_up() { curl -sf -m 2 "http://127.0.0.1:${ENGINE_PORT}/v1/models" >/dev/null 2>&1; }

wait_for() {  # wait_for <check-fn> <seconds>
  local i=0
  while [ "$i" -lt "$(( $2 * 2 ))" ]; do
    "$1" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

UV=""
ensure_uv() {
  [ -n "$UV" ] && return 0
  local dir="$RUNTIME_DIR/uv-$UV_VERSION"
  if [ -x "$dir/uv" ]; then UV="$dir/uv"; return 0; fi
  say "Downloading uv $UV_VERSION, a fast Python installer (~16 MB)…"
  local tmp got
  tmp="$(mktemp -d)"
  if curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp/uv.tar.gz" \
       "https://github.com/astral-sh/uv/releases/download/$UV_VERSION/uv-aarch64-apple-darwin.tar.gz"; then
    got="$(shasum -a 256 "$tmp/uv.tar.gz" | awk '{print $1}')"
    if [ "$got" = "$UV_SHA256" ]; then
      tar -xzf "$tmp/uv.tar.gz" -C "$tmp"
      mkdir -p "$dir"
      mv "$tmp/uv-aarch64-apple-darwin/uv" "$dir/uv"
      chmod +x "$dir/uv"
      UV="$dir/uv"
    else
      warn "the uv download didn't match its checksum (got $got) — not using it"
    fi
  fi
  rm -rf "$tmp"
  if [ -z "$UV" ] && command -v uv >/dev/null 2>&1; then
    UV="$(command -v uv)"
    warn "using the uv already on this Mac ($UV)"
  fi
  [ -n "$UV" ]
}

make_venv() {  # make_venv <dir>
  venv_ok "$1" && return 0
  if [ -e "$1" ]; then
    warn "rebuilding a broken environment at $1"
    rm -rf "$1"
  fi
  mkdir -p "$(dirname "$1")"
  if ensure_uv; then
    # --seed adds pip, which `python -m venv` would have: libraries in the
    # engine stack reach for it at runtime.
    "$UV" venv --quiet --seed --managed-python --python "$PY_VERSION" "$1"
  elif [ -n "$PY" ]; then
    "$PY" -m venv "$1"
  else
    die "couldn't download the Python installer. Check your internet connection and try again."
  fi
}

# Kokoro's text processor (misaki) needs spaCy's small English model. Left to
# itself it downloads the model during the first read by shelling out to pip,
# which in a venv without pip leaves that read hanging forever. Install it
# here instead, at the version spaCy itself reports as compatible.
ensure_spacy_model() {
  "$ENGINE_VENV/bin/python" -c 'import en_core_web_sm' >/dev/null 2>&1 && return 0
  say "Installing the English language model for the voice…"
  local url
  url="$("$ENGINE_VENV/bin/python" - <<'PY'
from spacy import about
from spacy.cli.download import get_compatibility, get_version
name = "en_core_web_sm"
version = get_version(name, get_compatibility())
print(f"{about.__download_url__}/{name}-{version}/{name}-{version}-py3-none-any.whl")
PY
)" || return 1
  if [ -n "$UV" ]; then
    "$UV" pip install --quiet --python "$ENGINE_VENV/bin/python" "$url"
  else
    "$ENGINE_VENV/bin/python" -m pip install --quiet "$url"
  fi
}

# Install ENGINE_PKGS into the engine venv. Without --upgrade, pip still moves
# any package whose installed version falls outside its pin (mlx-audio <0.5.7).
install_engine_pkgs() {
  local pip_up=""
  if [ "${MYNA_FORCE_ENGINE:-0}" = "1" ]; then pip_up="--upgrade"; fi
  if [ -n "$UV" ]; then
    say "Installing the voice engine — about 600 MB the first time…"
    # shellcheck disable=SC2086
    "$UV" pip install --quiet --python "$ENGINE_VENV/bin/python" $pip_up "${ENGINE_PKGS[@]}"
  else
    say "Installing the voice engine with pip — this can take a few minutes…"
    "$ENGINE_VENV/bin/python" -m pip install --quiet --upgrade pip
    # shellcheck disable=SC2086
    "$ENGINE_VENV/bin/python" -m pip install --quiet $pip_up "${ENGINE_PKGS[@]}"
  fi
}

# --update-daemon only: an engine installed by an older Myna (before mlx-audio
# was pinned to 0.5.7 and sentencepiece added) runs Kokoro but not the other
# engines. Upgrade it in place. No venv at all is the app's full-setup case,
# not this one. Failure is a warning: the old engine still speaks.
ENGINE_UPGRADED=0
refresh_stale_engine() {
  [ -x "$ENGINE_VENV/bin/python" ] || return 0
  engine_ready && return 0
  say "Upgrading the voice engine for this version of Myna…"
  ensure_uv || true
  if install_engine_pkgs && ensure_spacy_model && engine_ready; then
    ENGINE_UPGRADED=1
  else
    warn "couldn't upgrade the voice engine; Kokoro keeps working. Run Myna's setup again to retry."
  fi
}

# ── the daemon (standalone mode) ─────────────────────────────────────────────

install_daemon() {
  local src="$DAEMON_SRC" fetched="" stage
  if [ -z "$src" ]; then
    say "Downloading the Myna daemon ($MYNA_REF)…"
    fetched="$(mktemp -d)"
    curl -fsSL --retry 3 "https://codeload.github.com/PrerakGada/Myna/tar.gz/$MYNA_REF" \
      | tar -xz -C "$fetched" --strip-components=1 \
      || die "couldn't download the Myna daemon. Check your internet connection and try again."
    src="$fetched/daemon"
  fi
  # Build from a scratch copy: setuptools writes build/ and *.egg-info beside
  # the source, and the bundled copy lives inside the signed, read-only app.
  stage="$(mktemp -d)"
  cp -R "$src/pyproject.toml" "$src/myna" "$stage/"
  find "$stage" -name __pycache__ -type d -prune -exec rm -rf {} +
  say "Installing the Myna daemon…"
  "$UV" pip install --quiet --python "$DAEMON_VENV/bin/python" --reinstall-package myna "$stage" \
    || die "couldn't install the Myna daemon's Python packages. Check your internet connection and try again."
  rm -rf "$stage"
  if [ -n "$fetched" ]; then rm -rf "$fetched"; fi
}

write_agent_plist() {
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.cache/myna"
  cat > "$AGENT_PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DAEMON_PROGRAM</string>
    <string>-m</string>
    <string>myna</string>
  </array>
  <key>WorkingDirectory</key><string>$HOME/.cache/myna</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>dev.myna.app</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PYTHONUNBUFFERED</key><string>1</string></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/myna-daemon.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/myna-daemon.log</string>
</dict>
</plist>
EOF
  mv "$AGENT_PLIST.tmp" "$AGENT_PLIST"
}

unload_label() {  # unload_label <label>
  launchctl bootout "gui/$UID_NUM/$1" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 20 ] && launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1; do
    sleep 0.25; i=$((i + 1))
  done
}

load_agent() {
  unload_label "$AGENT_LABEL"
  launchctl enable "gui/$UID_NUM/$AGENT_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENT_PLIST" 2>/dev/null \
    || launchctl load -w "$AGENT_PLIST" 2>/dev/null
}

# The old two-service layout ran the engine as its own agent; the daemon owns it now.
retire_legacy_engine_agent() {
  unload_label "dev.myna.engine"
  rm -f "$HOME/Library/LaunchAgents/dev.myna.engine.plist"
}

# macOS names a background item after its executable, so a daemon run as
# bin/python appears as "python" in the "Background Items Added" notice and in
# Login Items. Run it from a copy of the venv's interpreter called "Myna Voice"
# instead; the copy still finds the venv through pyvenv.cfg.
prepare_daemon_executable() {
  local real
  real="$("$DAEMON_VENV/bin/python" -c 'import os, sys; print(os.path.realpath(sys.executable))')" || return 1
  cp -f "$real" "$DAEMON_EXEC.tmp" && chmod 755 "$DAEMON_EXEC.tmp" && mv -f "$DAEMON_EXEC.tmp" "$DAEMON_EXEC" || return 1
  "$DAEMON_EXEC" -c 'import myna' >/dev/null 2>&1
}

start_standalone_daemon() {
  retire_legacy_engine_agent
  # A leftover Homebrew service would fight us for the port.
  if [ -f "$HOME/Library/LaunchAgents/$BREW_LABEL.plist" ]; then
    warn "retiring a leftover Homebrew myna-daemon service"
    unload_label "$BREW_LABEL"
    rm -f "$HOME/Library/LaunchAgents/$BREW_LABEL.plist"
  fi
  make_venv "$DAEMON_VENV"
  if [ "${1:-}" = "force" ] || [ -z "$BUNDLED_VERSION" ] \
     || [ "$(installed_daemon_version)" != "$BUNDLED_VERSION" ]; then
    install_daemon
  else
    say "Myna daemon $BUNDLED_VERSION already installed"
  fi
  if prepare_daemon_executable; then
    DAEMON_PROGRAM="$DAEMON_EXEC"
  else
    DAEMON_PROGRAM="$DAEMON_VENV/bin/python"
    warn "couldn't name the background service; it will show as \"python\" in Login Items"
  fi
  write_agent_plist
  load_agent || die "macOS didn't allow Myna's background service to start. Open System Settings → General → Login Items & Extensions, allow Myna, then try again."
  wait_for daemon_up 30 || die "the Myna daemon didn't start. Details are in ~/Library/Logs/myna-daemon.log."
}

# ── --update-daemon ──────────────────────────────────────────────────────────

# Sparkle updates the app on a Homebrew install too, but the daemon there is the
# myna-daemon formula: only brew can move it, and `brew upgrade` leaves a running
# service on the old code until something restarts it.
update_brew_daemon() {
  local keg_link before after
  keg_link="$(dirname "$(dirname "$BREW")")/opt/myna-daemon"
  before="$(readlink "$keg_link" || true)"
  say "Upgrading Homebrew's myna-daemon"
  "$BREW" update --quiet >/dev/null 2>&1 || warn "brew update failed; trying the upgrade anyway"
  HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" upgrade prerakgada/tap/myna-daemon \
    || die "brew couldn't upgrade myna-daemon. Run: brew upgrade prerakgada/tap/myna-daemon"
  after="$(readlink "$keg_link" || true)"
  if [ "$before" = "$after" ] && [ "$ENGINE_UPGRADED" != 1 ]; then
    skip "Homebrew has no newer myna-daemon yet"
    return 0
  fi
  # Restart only a service that was running; never start one the user stopped.
  if launchctl print "gui/$UID_NUM/$BREW_LABEL" >/dev/null 2>&1; then
    "$BREW" services restart myna-daemon >/dev/null 2>&1 \
      || launchctl kickstart -k "gui/$UID_NUM/$BREW_LABEL" 2>/dev/null \
      || die "restart it manually: brew services restart myna-daemon"
    wait_for daemon_up 30 || die "myna-daemon didn't come back. Run: brew services restart myna-daemon"
  fi
  finish "Daemon ${after##*/}"
}

if [ "${1:-}" = "--update-daemon" ]; then
  begin service "Updating the background service"
  # Before the daemon restarts: the engine is its child, so the restart below
  # is what puts an upgraded engine into use.
  refresh_stale_engine
  if [ "$MODE" = "homebrew" ]; then
    update_brew_daemon
    exit 0
  fi
  ensure_uv || die "couldn't download the Python installer. Check your internet connection and try again."
  start_standalone_daemon force
  finish "Daemon $BUNDLED_VERSION"
  exit 0
fi

# ── check ────────────────────────────────────────────────────────────────────

begin check "Checking this Mac"
[ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] \
  || die "Myna's voice engine needs Apple Silicon (M1 or later). This Mac has an Intel processor."
os_version="$(sw_vers -productVersion)"
[ "${os_version%%.*}" -ge 14 ] \
  || die "Myna's voice engine needs macOS 14 Sonoma or later. This Mac runs macOS $os_version."
if ! engine_ready; then
  free_kb="$(df -Pk "$HOME" | awk 'NR==2 {print $4}')"
  [ "${free_kb:-0}" -ge 3000000 ] \
    || die "Myna needs about 3 GB of free disk space for its voice. This Mac has $(( ${free_kb:-0} / 1048576 )) GB free."
fi
say "Apple Silicon, macOS $os_version, daemon managed by $MODE"
finish "macOS $os_version"

# ── runtime ──────────────────────────────────────────────────────────────────

begin runtime "Preparing Python"
if engine_ready && { [ "$MODE" = "homebrew" ] || venv_ok "$DAEMON_VENV"; }; then
  say "Python runtime already in place"
  finish "Already installed"
elif ensure_uv; then
  say "Installing Python $PY_VERSION for Myna…"
  "$UV" python install --quiet "$PY_VERSION" \
    || die "couldn't download Python. Check your internet connection and try again."
  finish "Python $PY_VERSION"
elif [ "$MODE" = "homebrew" ] && [ -n "$PY" ]; then
  warn "uv unavailable — falling back to pip with $PY (slower)"
  finish "Python from Homebrew"
else
  die "couldn't download the Python installer. Check your internet connection and try again."
fi

# ── engine ───────────────────────────────────────────────────────────────────

begin engine "Installing the voice engine"
ENGINE_INSTALLED=0
if [ "${MYNA_FORCE_ENGINE:-0}" != "1" ] && engine_ready; then
  say "Voice engine already installed — reusing it"
  finish "Already installed"
else
  make_venv "$ENGINE_VENV"
  install_engine_pkgs || die "couldn't install the voice engine. Check your internet connection and try again."
  ensure_spacy_model \
    || die "couldn't download the English language model for the voice. Check your internet connection and try again."
  engine_ready || die "the voice engine installed but doesn't load. Try again, or report it at github.com/PrerakGada/Myna/issues."
  ENGINE_INSTALLED=1
  finish "Installed"
fi

# ── service ──────────────────────────────────────────────────────────────────

begin service "Starting the background service"
if [ "$MODE" = "homebrew" ]; then
  retire_legacy_engine_agent
  # A standalone agent from an earlier DMG install would fight brew for the port.
  if [ -f "$AGENT_PLIST" ] && grep -q "$DAEMON_VENV" "$AGENT_PLIST"; then
    warn "retiring the standalone daemon — Homebrew manages it now"
    unload_label "$AGENT_LABEL"
    rm -f "$AGENT_PLIST"
  fi
  if daemon_up && [ "$ENGINE_INSTALLED" = "1" ]; then
    say "Restarting myna-daemon so it picks up the new engine"
    "$BREW" services restart myna-daemon >/dev/null 2>&1 \
      || launchctl kickstart -k "gui/$UID_NUM/$BREW_LABEL" 2>/dev/null \
      || warn "restart it manually: brew services restart myna-daemon"
  elif ! daemon_up; then
    say "Starting myna-daemon"
    "$BREW" services start myna-daemon >/dev/null 2>&1 \
      || warn "couldn't start myna-daemon via brew — run: brew services start myna-daemon"
  fi
  wait_for daemon_up 30 || die "myna-daemon didn't start. Run: brew services restart myna-daemon"
  finish "Managed by Homebrew"
else
  ensure_uv || die "couldn't download the Python installer. Check your internet connection and try again."
  start_standalone_daemon
  finish "Running"
fi

# ── model ────────────────────────────────────────────────────────────────────

begin model "Downloading the voice"
MODEL_ID="${MYNA_VOICE_MODEL:-prince-canuma/Kokoro-82M}"
# huggingface_hub 1.x transfers via Xet; HF_XET_HIGH_PERFORMANCE maxes out its
# concurrency on a cold fetch and does nothing when the model is cached.
if "$ENGINE_VENV/bin/python" -c 'import hf_xet' 2>/dev/null; then export HF_XET_HIGH_PERFORMANCE=1; fi
# local_files_only returns instantly with no network when the snapshot is
# already cached; only a missing or partial cache downloads (and resumes).
"$ENGINE_VENV/bin/python" - "$MODEL_ID" <<'PY' || die "the voice model didn't finish downloading. Check your internet connection and try again — it resumes where it stopped."
import sys
from huggingface_hub import snapshot_download
model_id = sys.argv[1]
try:
    snapshot_download(model_id, local_files_only=True)
    print("\033[1;35m==>\033[0m Voice model already downloaded")
except Exception:
    print("\033[1;35m==>\033[0m Downloading the Kokoro voice model — about 340 MB…", flush=True)
    snapshot_download(model_id)
PY
say "Warming up the voice…"
# The daemon's supervisor spawns the engine within a few seconds of the venv
# existing; the first start imports MLX and can take a while on a cold disk.
if wait_for engine_up 90; then
  # Prime the model into engine memory so the first real read is instant. The
  # first synth pays the one-time model load, hence the generous timeout. Right
  # after the engine comes up the daemon can still answer 502 while the engine
  # is busy loading, so try a few times; otherwise that load lands on the
  # user's first hotkey press (~15 s of silence on a fresh Mac).
  warmed=0
  for _ in 1 2 3; do
    if curl -sf -m 180 -X POST "http://127.0.0.1:${DAEMON_PORT}/v2/synthesize" \
         -H 'Content-Type: application/json' \
         -d '{"text":"Myna is ready.","voice":"af_heart","speed":1.0,"mode":"full"}' \
         -o /dev/null 2>/dev/null; then
      warmed=1
      break
    fi
    sleep 4
  done
  if [ "$warmed" != "1" ]; then
    warn "the first warm-up read didn't finish; the first real read may take a few extra seconds"
  fi
  finish "Ready"
else
  warn "the voice engine is still starting — it will be ready in a moment"
  finish "Downloaded; the engine is still starting"
fi

# ── claude ───────────────────────────────────────────────────────────────────

begin claude "Connecting Claude Code"
if [ ! -d "$HOME/.claude" ]; then
  say "Claude Code isn't installed — skipping its hook"
  skip "Not installed on this Mac"
else
  HOOK_DIR="$HOME/.config/myna/hooks"
  HOOK="$HOOK_DIR/myna-cc-announce.py"
  mkdir -p "$HOOK_DIR"
  hook_ok=0
  for c in "$SELF_DIR/myna-cc-announce.py" "$SELF_DIR/../hooks/myna-cc-announce.py"; do
    if [ -n "$SELF_DIR" ] && [ -f "$c" ]; then cp "$c" "$HOOK" && hook_ok=1; break; fi
  done
  if [ "$hook_ok" = "0" ] && curl -fsSL "https://raw.githubusercontent.com/PrerakGada/Myna/${MYNA_REF}/hooks/myna-cc-announce.py" -o "$HOOK" 2>/dev/null; then
    hook_ok=1
  fi
  if [ "$hook_ok" = "0" ]; then
    soft_fail "couldn't get the Claude Code hook — Claude replies won't reach Myna"
  else
    chmod +x "$HOOK"
    # Run the hook with the engine's Python rather than `python3`: on a Mac
    # without the Xcode command-line tools, /usr/bin/python3 is a stub that
    # pops an install dialog every time Claude finishes a turn.
    HOOK_CMD="\"$ENGINE_VENV/bin/python\" \"$HOOK\""
    if HOOK="$HOOK" HOOK_CMD="$HOOK_CMD" "$ENGINE_VENV/bin/python" - <<'PY'
import json, os, pathlib, sys, tempfile
p = pathlib.Path.home() / ".claude" / "settings.json"
try:
    data = json.loads(p.read_text()) if p.exists() else {}
except Exception as exc:
    print(f"warn: ~/.claude/settings.json isn't valid JSON ({exc}); leaving it untouched")
    sys.exit(1)
hook, cmd = os.environ["HOOK"], os.environ["HOOK_CMD"]
hooks = data.setdefault("hooks", {}) if isinstance(data, dict) else None
if not isinstance(hooks, dict):
    print("warn: ~/.claude/settings.json has an unexpected \"hooks\" shape; leaving it untouched")
    sys.exit(1)
# One script handles both events (it reads hook_event_name). Stop announces
# replies; Notification announces "needs you" prompts. Re-running setup
# rewrites a stale command in place and never adds a second entry.
for event in ("Stop", "Notification"):
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list):
        print(f"warn: ~/.claude/settings.json has an unexpected {event} hook list; leaving it untouched")
        sys.exit(1)
    found = False
    for group in groups:
        entries = group.get("hooks", []) if isinstance(group, dict) else []
        for h in entries if isinstance(entries, list) else []:
            if isinstance(h, dict) and "myna-cc-announce.py" in str(h.get("command", "")):
                found = True
                if h["command"] != cmd:
                    h["command"] = cmd
    if not found:
        groups.append({"hooks": [{"type": "command", "command": cmd}]})
fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".settings.", suffix=".json")
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, p)
print("\033[1;35m==>\033[0m Claude Code hooks (Stop, Notification) registered in ~/.claude/settings.json")
PY
    then
      finish "Connected"
    else
      soft_fail "couldn't update ~/.claude/settings.json — Claude replies won't reach Myna"
    fi
  fi
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo
say "Setup summary"
d_ok="DOWN"; daemon_up && d_ok="up"
e_ok="starting"; engine_up && e_ok="up"
printf '   daemon  (127.0.0.1:%s): %s — managed by %s\n' "$DAEMON_PORT" "$d_ok" "$MODE"
printf '   engine  (127.0.0.1:%s): %s\n' "$ENGINE_PORT" "$e_ok"
echo
echo "Next:"
echo "  • Grant Accessibility when Myna asks, so it can read your selection."
echo "  • Select some text anywhere and press ⌘⌥⇧S."
if [ -d "$HOME/.claude" ]; then
  echo "  • Restart Claude Code once so it picks up the hook."
fi
