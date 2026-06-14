#!/usr/bin/env bash
# dist/setup.sh — one-command setup that finishes a Homebrew (cask) install of
# Myna. The cask installs Myna.app and the `myna-daemon` formula, but NOT the
# pieces a working install also needs:
#
#   • the mlx-audio TTS engine venv (Apple Silicon only) + a LaunchAgent
#   • the Kokoro voice model warm-up (lazy HuggingFace download, ~340 MB, once)
#   • the Claude Code Stop hook (so Claude outputs surface in the floating pill)
#   • making sure the daemon service is actually running
#
# Run after `brew install --cask PrerakGada/myna/myna`:
#
#   curl -fsSL https://raw.githubusercontent.com/PrerakGada/Myna/v0.3.1/dist/setup.sh | bash
#
# or, on a checkout / dev install:  ./dist/setup.sh   (also `myna setup`)
#
# Idempotent and best-effort: safe to re-run; it tells you exactly what it did.
set -euo pipefail

# The git ref to pull the CC hook from. The curl one-liner pins this to the
# release tag; a local checkout falls back to the working tree (see step 5).
MYNA_REF="${MYNA_REF:-v0.3.1}"
RAW="https://raw.githubusercontent.com/PrerakGada/Myna/${MYNA_REF}"
DAEMON_PORT="${MYNA_PORT:-8766}"
ENGINE_PORT="${MYNA_ENGINE_PORT:-8765}"
ENGINE_VENV="$HOME/.venvs/mlx-audio"
# Where a checkout of this script lives, so we can prefer the local hook.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || echo "")"

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }

# 0. Apple Silicon guard — MLX (mlx-audio's backend) is arm64-only.
[ "$(uname -m)" = "arm64" ] \
  || die "Myna's voice engine (MLX) needs Apple Silicon. This Mac is $(uname -m); the engine can't run here."

# 1. Locate python3.13 (brew installs it as a myna-daemon dependency).
PY=""
for c in python3.13 "$(brew --prefix 2>/dev/null)/bin/python3.13" \
         /opt/homebrew/bin/python3.13 "$HOME/.local/bin/python3.13"; do
  [ -n "$c" ] || continue
  if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then PY="$c"; break; fi
done
[ -n "$PY" ] || die "python3.13 not found. Install it with: brew install python@3.13"

# 2. Engine venv + mlx-audio.
if [ ! -d "$ENGINE_VENV" ]; then
  say "Creating voice-engine venv at $ENGINE_VENV"
  "$PY" -m venv "$ENGINE_VENV"
fi
say "Installing the voice engine (mlx-audio) — this can take a few minutes…"
"$ENGINE_VENV/bin/pip" install --quiet --upgrade pip
# The `[server]` extra is REQUIRED — it pulls uvicorn + fastapi + webrtcvad,
# which `mlx_audio.server` imports. Plain `mlx-audio` installs the library but
# NOT the HTTP server deps, so the engine crashes on startup with
# "ModuleNotFoundError: No module named 'uvicorn'" and the app stays offline.
"$ENGINE_VENV/bin/pip" install --quiet --upgrade 'mlx-audio[server]' \
  || die "mlx-audio install failed. Re-run, or: $ENGINE_VENV/bin/pip install 'mlx-audio[server]'"

# 3. Engine LaunchAgent — keeps the engine on 127.0.0.1:$ENGINE_PORT across reboots.
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/.cache/myna" "$HOME/Library/Logs"
ENGINE_PLIST="$HOME/Library/LaunchAgents/dev.myna.engine.plist"
cat > "$ENGINE_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.myna.engine</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ENGINE_VENV/bin/python</string>
    <string>-m</string><string>mlx_audio.server</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$ENGINE_PORT</string>
  </array>
  <key>WorkingDirectory</key><string>$HOME/.cache/myna</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/myna-engine.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/myna-engine.log</string>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/dev.myna.engine" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$ENGINE_PLIST" 2>/dev/null \
  || launchctl load "$ENGINE_PLIST" 2>/dev/null || true
say "Voice engine loaded on port $ENGINE_PORT"

# 4. Make sure the daemon (brew service) is up.
if ! curl -sf -m 2 "http://127.0.0.1:${DAEMON_PORT}/v2/health" >/dev/null 2>&1; then
  say "Starting myna-daemon"
  brew services start myna-daemon >/dev/null 2>&1 \
    || warn "couldn't start myna-daemon via brew — run: brew services start myna-daemon"
fi

# 5. Claude Code Stop hook — prefer a local checkout, else download from the tag.
HOOK_DIR="$HOME/.config/myna/hooks"
mkdir -p "$HOOK_DIR"
HOOK="$HOOK_DIR/myna-cc-announce.py"
say "Installing the Claude Code Stop hook"
if [ -n "$SELF_DIR" ] && [ -f "$SELF_DIR/../hooks/myna-cc-announce.py" ]; then
  cp "$SELF_DIR/../hooks/myna-cc-announce.py" "$HOOK"
elif ! curl -fsSL "$RAW/hooks/myna-cc-announce.py" -o "$HOOK" 2>/dev/null; then
  warn "couldn't fetch the CC hook from $RAW — the pill's Claude-output prompts won't fire."
  HOOK=""
fi
if [ -n "$HOOK" ]; then
  chmod +x "$HOOK"
  HOOK="$HOOK" python3 - <<'PY'
import json, os, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
data = json.loads(p.read_text()) if p.exists() else {}
hooks = data.setdefault("hooks", {})
stop = hooks.setdefault("Stop", [])
cmd = os.environ["HOOK"]
already = any(h.get("command") == cmd for g in stop for h in g.get("hooks", []))
if already:
    print("   Stop hook already registered")
else:
    stop.append({"hooks": [{"type": "command", "command": cmd}]})
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2))
    print("   registered Stop hook in ~/.claude/settings.json")
PY
fi

# 6. Warm the voice model (best-effort — triggers the one-time Kokoro download).
say "Warming the voice model (first run downloads ~340 MB; this may take a minute)…"
if curl -sf -m 180 -X POST "http://127.0.0.1:${DAEMON_PORT}/v2/synthesize" \
     -H 'Content-Type: application/json' \
     -d '{"text":"Myna is ready.","voice":"af_heart","speed":1.0,"mode":"full"}' \
     -o /dev/null 2>/dev/null; then
  say "Voice model ready."
else
  warn "warm-up didn't finish — the model will download on your first real read instead."
fi

# 7. Status summary.
echo
say "Setup summary"
d_ok=$(curl -sf -m 2 "http://127.0.0.1:${DAEMON_PORT}/v2/health" >/dev/null 2>&1 && echo "up" || echo "DOWN")
e_ok=$(curl -sf -m 2 "http://127.0.0.1:${ENGINE_PORT}/v1/models" >/dev/null 2>&1 && echo "up" || echo "starting/DOWN")
printf '   daemon  (127.0.0.1:%s): %s\n' "$DAEMON_PORT" "$d_ok"
printf '   engine  (127.0.0.1:%s): %s\n' "$ENGINE_PORT" "$e_ok"
echo
echo "Next:"
echo "  • Launch Myna.app and grant Accessibility (+ Automation for the Chrome hotkey) when prompted."
echo "  • Try the read-selection hotkey: ⌘⌥⇧S over some selected text."
echo "  • Restart Claude Code once so it picks up the Stop hook (then finish a turn → the pill prompts you to play it)."
