import os
import sys

import uvicorn

from . import api_access
from .app import create_app
from .config import load_config


def main() -> None:
    # Only the real daemon (`python -m myna`) reaches here — never the
    # in-process test harnesses — so this is the safe place to arm engine
    # autostart. The lifespan also honours the engine_autostart config flag,
    # so users/dev can still opt out via config.json.
    os.environ.setdefault("MYNA_ENGINE_AUTOSTART", "1")
    cfg = load_config()
    app = create_app(cfg, persist_config=True)
    # Loopback only, unless the API pane has turned on local-network access
    # (`api_lan`), which binds every interface (myna.api_access).
    host = api_access.bind_host(cfg)
    server = uvicorn.Server(uvicorn.Config(app, host=host, port=cfg["daemon_port"]))
    access = app.state.api_access
    access.bound_lan = host != "127.0.0.1"
    # Changing LAN access asks for a rebind: stop serving (in-flight
    # responses finish, the lifespan stops the engine and the render
    # worker), then re-exec below with the new bind address.
    access.request_restart = lambda: setattr(server, "should_exit", True)
    # Open /reading/events streams end once this turns true; uvicorn waits on
    # every open response before it stops.
    app.state.shutting_down = lambda: server.should_exit
    app.state.service_port = cfg["daemon_port"]
    server.run()
    if access.restart_requested:
        api_access.reexec()
    if not server.started:
        sys.exit(3)  # what uvicorn.run does when startup fails (port taken)


if __name__ == "__main__":
    main()
