import os

import uvicorn

from .app import create_app
from .config import load_config


def main() -> None:
    # Only the real daemon (`python -m myna`) reaches here — never the
    # in-process test harnesses — so this is the safe place to arm engine
    # autostart. The lifespan also honours the engine_autostart config flag,
    # so users/dev can still opt out via config.json.
    os.environ.setdefault("MYNA_ENGINE_AUTOSTART", "1")
    cfg = load_config()
    uvicorn.run(create_app(cfg), host="127.0.0.1", port=cfg["daemon_port"])


if __name__ == "__main__":
    main()
