import json
import os
import pathlib

CONFIG_DIR = pathlib.Path(os.path.expanduser("~/.config/myna"))
CONFIG_PATH = CONFIG_DIR / "config.json"

DEFAULTS = {
    "engine_url": "http://127.0.0.1:8765",
    "ollama_url": "http://127.0.0.1:11434",
    "voice": "af_heart",
    "lang_code": "a",
    "model": "prince-canuma/Kokoro-82M",
    "summary_model": "qwen3.5:4b",
    "speed": 1.0,
    "chunk_chars": 1500,
    "daemon_port": 8766,
}


def load_config() -> dict:
    cfg = dict(DEFAULTS)
    if CONFIG_PATH.exists():
        cfg.update(json.loads(CONFIG_PATH.read_text()))
    return cfg
