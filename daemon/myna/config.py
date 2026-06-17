import json
import os
import pathlib

CONFIG_DIR = pathlib.Path(os.path.expanduser("~/.config/myna"))
CONFIG_PATH = CONFIG_DIR / "config.json"

DEFAULTS = {
    "engine_url": "http://127.0.0.1:8765",
    # The daemon supervises the mlx-audio engine as a CHILD process so the
    # whole voice stack is managed by one brew service (myna-daemon) instead
    # of a separate dev.myna.engine LaunchAgent. `engine_venv` is the
    # setup.sh-built venv holding mlx-audio + the Kokoro G2P stack. Set
    # `engine_autostart` false to run the engine yourself (dev) — the daemon
    # then just proxies to `engine_url`. Autostart is additionally gated on the
    # MYNA_ENGINE_AUTOSTART env var (set only by `python -m myna`) so test
    # harnesses that build the app in-process never spawn a real engine.
    "engine_venv": "~/.venvs/mlx-audio",
    "engine_autostart": True,
    "engine_log": "~/Library/Logs/myna-engine.log",
    "ollama_url": "http://127.0.0.1:11434",
    "voice": "af_heart",
    "lang_code": "a",
    "model": "prince-canuma/Kokoro-82M",
    "summary_model": "qwen3.5:4b",
    "summary_think": False,
    "summary_timeout": 60.0,
    "speed": 1.0,
    "chunk_chars": 1500,
    # Time-to-first-audio optimization: the first chunk is capped at this many
    # words so Kokoro can return playable audio within ~300ms instead of waiting
    # on a 1500-char first chunk that takes 1.5-3s to synthesize. Subsequent
    # chunks use `chunk_chars` and are prefetched one ahead of playback so the
    # buffer never empties (YouTube-style).
    "first_chunk_max_words": 15,
    "daemon_port": 8766,
    # Karaoke subtitle ribbon (S12). Bound to MynaKaraoke sidecar via
    # ~/.myna/karaoke.sock; off here means the daemon never tries to
    # connect or spawn the binary. Set to false to disable entirely.
    "karaoke": {"enabled": True},
}


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    return cfg
