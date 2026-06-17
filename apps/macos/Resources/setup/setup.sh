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
# Run after `brew install --cask prerakgada/tap/myna`:
#
#   curl -fsSL https://raw.githubusercontent.com/PrerakGada/Myna/v0.3.2/dist/setup.sh | bash
#
# or, on a checkout / dev install:  ./dist/setup.sh   (also `myna setup`)
#
# Idempotent and best-effort: safe to re-run; it tells you exactly what it did.
set -euo pipefail

# The git ref to pull the CC hook from. The curl one-liner pins this to the
# release tag; a local checkout falls back to the working tree (see step 5).
MYNA_REF="${MYNA_REF:-v0.3.2}"
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

# 2. Engine venv + mlx-audio.  IDEMPOTENT + cache-friendly.
#    The engine stack is ~600 MB of wheels, so re-running setup or upgrading
#    Myna used to re-download ALL of it every time (the venv survives a cask
#    reinstall, but `pip install --upgrade` re-resolved the whole tree against
#    PyPI and re-fetched anything with a newer release). Now:
#      • if the venv already imports the whole stack, skip pip entirely
#        (a ~30 ms import probe — the common case on re-install / upgrade);
#      • when the installer DOES run we DON'T pass `--upgrade`, so an already-
#        installed package counts as satisfied and is left alone (only
#        genuinely-missing pieces are fetched), and the installer's wheel cache
#        (~/.cache/uv or ~/.cache/pip) makes any real download reusable next time.
#    The install itself prefers `uv` over pip (see below) for a faster cold run.
#    Set MYNA_FORCE_ENGINE=1 to force a clean `--upgrade` of the whole stack.
#
#    The full engine stack — `mlx-audio` alone is NOT enough to synthesize:
#      • [server]  → uvicorn + fastapi + webrtcvad (mlx_audio.server imports
#                    these; without it the engine crashes, app shows "offline")
#      • misaki + num2words + spacy + phonemizer + espeakng-loader → Kokoro's
#                    G2P. Without these /v1/models works but real TTS dies with
#                    "Kokoro requires the optional 'misaki' package".
#    We install spacy/etc. DIRECTLY (not via `misaki[en]`) because that extra
#    pins old spacy/blis versions with no cp313 wheel that fail to compile.
ENGINE_PKGS=('mlx-audio[server]' misaki num2words spacy phonemizer espeakng-loader)

engine_ready() {
  [ -x "$ENGINE_VENV/bin/python" ] || return 1
  "$ENGINE_VENV/bin/python" - <<'PY' >/dev/null 2>&1
import importlib.util as u, sys
need = ["mlx_audio", "misaki", "num2words", "spacy",
        "phonemizer", "espeakng_loader", "uvicorn", "fastapi", "webrtcvad"]
sys.exit(0 if all(u.find_spec(m) is not None for m in need) else 1)
PY
}

if [ ! -d "$ENGINE_VENV" ]; then
  say "Creating voice-engine venv at $ENGINE_VENV"
  "$PY" -m venv "$ENGINE_VENV"
fi

if [ "${MYNA_FORCE_ENGINE:-0}" != "1" ] && engine_ready; then
  say "Voice engine already installed — reusing it (set MYNA_FORCE_ENGINE=1 to reinstall)"
else
  # Pick the fastest available installer. Prefer `uv` (Astral) — parallel
  # downloads + a far faster resolver: ~3x quicker than pip on a cold install
  # in our benchmark (12s vs 34s), and bigger on slow/high-latency links. If uv
  # isn't on PATH, bootstrap it into the venv (a tiny wheel, no system change);
  # if even that fails, fall back to plain pip. Always works, just faster when
  # uv is around. uv's cache also hardlinks into venvs, so recreating the venv
  # later is near-instant.
  UV_BIN="$(command -v uv 2>/dev/null || true)"
  if [ -z "$UV_BIN" ]; then
    "$ENGINE_VENV/bin/pip" install --quiet uv >/dev/null 2>&1 \
      && [ -x "$ENGINE_VENV/bin/uv" ] && UV_BIN="$ENGINE_VENV/bin/uv" || true
  fi
  pip_up=""; [ "${MYNA_FORCE_ENGINE:-0}" = "1" ] && pip_up="--upgrade"
  if [ -n "$UV_BIN" ]; then
    say "Installing the voice engine with uv — first run pulls ~600 MB; later runs reuse the cache…"
    # shellcheck disable=SC2086
    "$UV_BIN" pip install --python "$ENGINE_VENV/bin/python" --quiet $pip_up "${ENGINE_PKGS[@]}" \
      || die "engine install (uv) failed. Re-run, or install the packages above manually."
  else
    say "Installing the voice engine with pip (install \`uv\` for ~3x faster setup) — this can take a few minutes…"
    "$ENGINE_VENV/bin/pip" install --quiet --upgrade pip
    # shellcheck disable=SC2086
    "$ENGINE_VENV/bin/pip" install --quiet $pip_up "${ENGINE_PKGS[@]}" \
      || die "engine install failed. Re-run, or install the packages above manually."
  fi
fi

# 3. The daemon now supervises the engine as a CHILD process — one brew
#    service (myna-daemon) for the whole voice stack. Evict any legacy
#    dev.myna.engine LaunchAgent from the old two-service layout so the daemon
#    is the sole owner and they don't fight over the port. (The daemon also
#    boots it out on its own startup; this covers fresh runs of setup.)
mkdir -p "$HOME/.cache/myna" "$HOME/Library/Logs"
launchctl bootout "gui/$(id -u)/dev.myna.engine" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/dev.myna.engine.plist"

# 4. (Re)start the daemon — on launch it spawns + supervises the mlx-audio
#    engine itself (it resolves the espeak/G2P env from the venv).
if curl -sf -m 2 "http://127.0.0.1:${DAEMON_PORT}/v2/health" >/dev/null 2>&1; then
  say "Restarting myna-daemon so it picks up the freshly-installed engine"
  brew services restart myna-daemon >/dev/null 2>&1 \
    || launchctl kickstart -k "gui/$(id -u)/homebrew.mxcl.myna-daemon" 2>/dev/null \
    || warn "restart it manually: brew services restart myna-daemon"
else
  say "Starting myna-daemon (it will start the voice engine)"
  brew services start myna-daemon >/dev/null 2>&1 \
    || warn "couldn't start myna-daemon via brew — run: brew services start myna-daemon"
fi
# Give the daemon's supervisor a moment to bring the engine up.
for _ in $(seq 1 20); do
  curl -sf -m 2 "http://127.0.0.1:${ENGINE_PORT}/v1/models" >/dev/null 2>&1 && break
  sleep 1
done
say "Voice engine managed by myna-daemon on port $ENGINE_PORT"

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

# 6. Pre-download the voice model so it's guaranteed cached before we finish.
#    The old approach warmed via a timeout-bounded /v2/synthesize call, which
#    "didn't finish" on slower networks and left users hitting 503s on first
#    read. snapshot_download resumes partial downloads and has no synth/HTTP
#    timeout to fight, so the model is fully cached when this returns.
say "Checking the voice model (~340 MB; downloads once, resumes if interrupted)…"
MODEL_ID="${MYNA_VOICE_MODEL:-prince-canuma/Kokoro-82M}"
# Speed up a COLD model fetch: huggingface_hub 1.x transfers via Xet (chunked,
# deduped, content-addressed; hf-xet already ships as a dependency, no install
# needed). HF_XET_HIGH_PERFORMANCE maxes out its concurrency. No effect when the
# model is already cached (the local_files_only fast path below does zero
# network). NB: the old hf_transfer flag is deprecated in 1.x — don't use it.
"$ENGINE_VENV/bin/python" -c 'import hf_xet' 2>/dev/null && export HF_XET_HIGH_PERFORMANCE=1
# Fast path: if the snapshot is already fully cached, local_files_only returns
# instantly with NO network — avoids re-verifying ~120 files against the Hub on
# every re-install / upgrade. Only a missing/partial cache hits the network.
if "$ENGINE_VENV/bin/python" - "$MODEL_ID" <<'PY'; then
import sys
from huggingface_hub import snapshot_download
model_id = sys.argv[1]
try:
    snapshot_download(model_id, local_files_only=True)
    print("   model already cached — skipping download")
except Exception:
    snapshot_download(model_id)
    print("   model downloaded")
PY
  say "Voice model ready."
  # Best-effort: prime the (now-cached) model into engine memory so the first
  # real read is instant. Generous timeout — the FIRST synth also pays the
  # one-time cold model load (can be tens of seconds); too short a timeout
  # makes curl disconnect mid-load. (The daemon now resets cleanly on such a
  # disconnect, but we still give it room so the prime actually succeeds.)
  curl -sf -m 180 -X POST "http://127.0.0.1:${DAEMON_PORT}/v2/synthesize" \
       -H 'Content-Type: application/json' \
       -d '{"text":"Myna is ready.","voice":"af_heart","speed":1.0,"mode":"full"}' \
       -o /dev/null 2>/dev/null || true
else
  warn "model download didn't finish — it'll download on your first read instead."
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
