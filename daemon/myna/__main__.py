import uvicorn

from .app import create_app
from .config import load_config


def main() -> None:
    cfg = load_config()
    uvicorn.run(create_app(cfg), host="127.0.0.1", port=cfg["daemon_port"])


if __name__ == "__main__":
    main()
