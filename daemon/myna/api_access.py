"""Who may call the daemon, the API key, and the render API's request log.

The daemon normally binds 127.0.0.1 and only this Mac can reach it. The API
pane can turn on local-network access (`api_lan` in config), which makes the
daemon bind 0.0.0.0 on its next start. From then on anyone on the Wi-Fi can
reach the port, so every request passes through `AccessMiddleware`:

  * Callers on this Mac (loopback) are served as before and never need a key.
    They must still name a loopback Host: that is the DNS-rebinding defence
    this middleware took over from Starlette's TrustedHostMiddleware (a web
    page can point its own hostname at 127.0.0.1, but not change the Host
    header its browser sends).
  * Anyone else gets `/v1/*` only, and only with `Authorization: Bearer <key>`.
    `/v2/*`, `/speak`, `/stop` and everything else that controls this Mac is
    403 to them, whatever key they send. With LAN access off they get 403 for
    everything, even if the socket is still bound wide while a restart is
    pending.

A connection from this Mac to its own LAN address arrives from that address,
not from 127.0.0.1, so it is treated as a LAN caller too. That is deliberate.

The key is `myna-` plus 32 url-safe random characters from `secrets`,
compared in constant time. Settings persist to config.json only from the
daemon the app talks to (see `ApiAccess.primary`). The request log is in
memory, the last 200 requests, and never holds the text sent to be spoken,
only its length.
"""

from __future__ import annotations

import hmac
import ipaddress
import logging
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from collections import deque
from typing import Callable, Optional

from starlette.responses import JSONResponse, PlainTextResponse

logger = logging.getLogger(__name__)

_LOOPBACK_HOST_NAMES = {"127.0.0.1", "localhost"}
LOG_SIZE = 200
_LAN_URLS_TTL_S = 30.0


def bind_host(cfg: dict) -> str:
    """The address the daemon listens on: all interfaces with LAN access on,
    loopback otherwise."""
    return "0.0.0.0" if cfg.get("api_lan") else "127.0.0.1"


def is_loopback_client(host: Optional[str]) -> bool:
    """Whether a request's peer address is this Mac.

    uvicorn always reports the TCP peer's IP. No peer at all means a Unix
    socket (local by definition); "testclient" is Starlette's TestClient.
    Anything else that isn't an IP is not trusted.
    """
    if host is None or host == "testclient":
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_loopback


def _host_name(host_header: str) -> str:
    if host_header.startswith("["):
        return host_header[1:].split("]", 1)[0]
    return host_header.split(":", 1)[0]


def openai_error(status: int, code: str, message: str, param: Optional[str] = None) -> JSONResponse:
    """OpenAI's error body, so OpenAI SDKs raise a readable exception."""
    kind = "server_error" if status >= 500 else "invalid_request_error"
    return JSONResponse(
        status_code=status,
        content={"error": {"message": message, "type": kind, "param": param, "code": code}},
    )


def new_key() -> str:
    return "myna-" + secrets.token_urlsafe(24)


class ApiAccess:
    """API access settings and the request log. One per app, at
    `app.state.api_access`."""

    def __init__(self, cfg: dict, *, save_config: Callable[[dict], None], persist_config: bool):
        self._cfg = cfg
        self._save = save_config
        self._persist_config = persist_config
        self._lock = threading.Lock()
        self.lan_enabled = bool(cfg.get("api_lan"))
        # What this process actually listens on. `python -m myna` binds from
        # config (see __main__), so this starts equal to the setting; the two
        # differ only while a rebind is pending.
        self.bound_lan = self.lan_enabled
        self._key: Optional[str] = cfg.get("api_key") or None
        self.log: deque = deque(maxlen=LOG_SIZE)
        # Set by __main__ when running as the service: a callable that stops
        # the server so __main__ can re-exec it. None under uvicorn --factory
        # and in tests, where a LAN change waits for a manual restart.
        self.request_restart: Optional[Callable[[], None]] = None
        self.restart_requested = False
        self._lan_urls: tuple[float, list[str]] = (0.0, [])

    # ----- identity -----

    def primary(self, port: Optional[int]) -> bool:
        """Whether this is the daemon the app talks to (the configured port,
        with persistence on). A second daemon on another port — a dev
        worktree, a test instance — shares the user's config.json but must
        not write api_lan into it: that would rebind the user's real daemon
        on its next start."""
        return self._persist_config and port == self._cfg.get("daemon_port")

    # ----- key -----

    def key_matches(self, given: Optional[str]) -> bool:
        key = self._key
        if not key or not given:
            return False
        return hmac.compare_digest(given.encode(), key.encode())

    def ensure_key(self, port: Optional[int]) -> str:
        with self._lock:
            if not self._key:
                self._key = new_key()
                self._save_if_primary(port, {"api_key": self._key})
            return self._key

    def regenerate_key(self, port: Optional[int]) -> str:
        with self._lock:
            self._key = new_key()
            self._save_if_primary(port, {"api_key": self._key})
            return self._key

    def _save_if_primary(self, port: Optional[int], updates: dict) -> None:
        self._cfg.update(updates)
        if not self.primary(port):
            return
        try:
            self._save(updates)
        except OSError as exc:
            logger.warning("couldn't save API settings: %s", exc)

    # ----- LAN -----

    def set_lan(self, enabled: bool, port: Optional[int]) -> None:
        key = self.ensure_key(port)
        with self._lock:
            if enabled == self.lan_enabled:
                return
            self.lan_enabled = enabled
            # The key goes with it, so a config that says LAN is on always
            # holds the key LAN callers were given.
            self._save_if_primary(port, {"api_lan": enabled, "api_key": key})
            if self.lan_enabled != self.bound_lan and self.request_restart is not None:
                self.restart_requested = True
                # Let this response reach the caller before the server stops.
                threading.Timer(0.3, self.request_restart).start()

    @property
    def restart_pending(self) -> bool:
        return self.lan_enabled != self.bound_lan

    def lan_urls(self, port: int) -> list[str]:
        at, hosts = self._lan_urls
        if time.monotonic() - at > _LAN_URLS_TTL_S:
            hosts = _lan_hosts()
            self._lan_urls = (time.monotonic(), hosts)
        return [f"http://{h}:{port}/v1" for h in hosts]

    def settings(self, port: int, *, loopback: bool) -> dict:
        key = self.ensure_key(port)
        return {
            "base_url": f"http://127.0.0.1:{port}/v1",
            "lan_enabled": self.lan_enabled,
            "lan_urls": self.lan_urls(port),
            "api_key": key if loopback else None,
            "requires_key_on_lan": True,
            "restart_pending": self.restart_pending,
        }

    # ----- log -----

    def record(self, entry: dict) -> None:
        self.log.append(entry)

    def recent(self, limit: int) -> list[dict]:
        limit = max(0, min(limit, LOG_SIZE))
        return list(reversed(self.log))[:limit] if limit else []


def _lan_hosts() -> list[str]:
    """This Mac's non-loopback IPv4 addresses (Wi-Fi, Ethernet, Tailscale…),
    then its Bonjour name. What another device would put in a URL."""
    hosts: list[str] = []
    try:
        out = subprocess.run(["/sbin/ifconfig"], capture_output=True, text=True, timeout=2).stdout
        for ip in re.findall(r"^\s*inet (\d+\.\d+\.\d+\.\d+)", out, flags=re.M):
            addr = ipaddress.ip_address(ip)
            if not (addr.is_loopback or addr.is_link_local) and ip not in hosts:
                hosts.append(ip)
    except (OSError, subprocess.SubprocessError, ValueError):
        pass
    try:
        name = subprocess.run(
            ["/usr/sbin/scutil", "--get", "LocalHostName"], capture_output=True, text=True, timeout=2
        ).stdout.strip()
        if name:
            hosts.append(f"{name}.local")
    except (OSError, subprocess.SubprocessError):
        pass
    return hosts


def _loggable(method: str, path: str) -> bool:
    """/v1/* always. /v2/renders* except the status polls Studio makes every
    second, which would push everything else out of a 200-entry log."""
    if path.startswith("/v1/"):
        return True
    if path == "/v2/renders" or path.startswith("/v2/renders/"):
        return method != "GET" or path.endswith("/audio")
    return False


class AccessMiddleware:
    """Pure ASGI, so a streaming body isn't buffered. Reads the ApiAccess
    from app state at request time; without one it fails closed (loopback
    only)."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] not in ("http", "websocket"):
            await self.app(scope, receive, send)
            return

        client = scope.get("client")
        client_ip = client[0] if client else None
        loopback = is_loopback_client(client_ip)
        path = scope.get("path", "")
        method = scope.get("method", "GET")
        headers = {k.decode("latin-1").lower(): v.decode("latin-1") for k, v in scope.get("headers", [])}
        access: Optional[ApiAccess] = getattr(scope["app"].state, "api_access", None) if "app" in scope else None

        if scope["type"] == "websocket":
            # No websocket routes today; keep the same rules if one appears.
            if not loopback or _host_name(headers.get("host", "")) not in _LOOPBACK_HOST_NAMES:
                await send({"type": "websocket.close", "code": 1008})
                return
            await self.app(scope, receive, send)
            return

        log = access is not None and _loggable(method, path)
        started = time.monotonic()
        extra: dict = {}
        scope["myna.log"] = extra
        status_holder = {"status": 500}

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                status_holder["status"] = message["status"]
            await send(message)

        response = None
        if loopback:
            if _host_name(headers.get("host", "")) not in _LOOPBACK_HOST_NAMES:
                response = PlainTextResponse("Invalid host header", status_code=400)
        elif access is None or not access.lan_enabled:
            response = _forbidden(path, "This Mac's Myna only accepts requests from this Mac.")
        elif not path.startswith("/v1/"):
            response = _forbidden(path, "Only /v1/* is reachable from other devices.")
        else:
            auth = headers.get("authorization", "")
            given = auth[7:].strip() if auth[:7].lower() == "bearer " else None
            if not access.key_matches(given):
                response = openai_error(
                    401, "unauthorized",
                    "Missing or wrong API key. Send Authorization: Bearer <key> from Myna's API page.",
                )
                response.headers["WWW-Authenticate"] = "Bearer"

        try:
            if response is not None:
                await response(scope, receive, send_wrapper)
            else:
                await self.app(scope, receive, send_wrapper)
        finally:
            if log:
                access.record({
                    "at": round(time.time(), 3),
                    "method": method,
                    "path": path,
                    "client": client_ip or "local",
                    "user_agent": headers.get("user-agent"),
                    "status": status_holder["status"],
                    "ms": int((time.monotonic() - started) * 1000),
                    "chars": extra.get("chars"),
                    "format": extra.get("format"),
                    "voice": extra.get("voice"),
                    "audio_s": extra.get("audio_s"),
                })


def _forbidden(path: str, message: str):
    if path.startswith("/v1/"):
        return openai_error(403, "forbidden", message)
    return JSONResponse(status_code=403, content={"ok": False, "reason": "forbidden", "detail": message})


def reexec() -> None:
    """Replace this process with a fresh copy of itself, same interpreter,
    same arguments, same PID.

    Why exec rather than exit-and-be-relaunched: all three ways Myna's daemon
    runs start it as `<python> -m myna` under launchd with KeepAlive (the
    Homebrew service via `myna-daemon`, which execs the venv python; the
    standalone `dev.myna.daemon` agent via the "Myna Voice" copy of python;
    this Mac's `dev.myna.daemon.src` via ~/.venvs/myna-dev). KeepAlive would
    relaunch an exit, but launchd throttles a job that exits soon after
    starting (10 s by default), and a daemon run by hand wouldn't come back
    at all. exec is immediate, keeps the PID launchd is watching, and works
    in every mode. `sys.orig_argv` keeps argv[0] as launched, so the
    "Myna Voice" process name survives. If exec fails, exit non-zero and let
    KeepAlive bring it back.
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.flush()
        except Exception:
            pass
    exe = sys.executable
    argv = list(getattr(sys, "orig_argv", None) or [exe, "-m", "myna"])
    try:
        if exe:
            os.execv(exe, argv)
    except OSError as exc:
        logger.error("re-exec failed (%s); exiting so launchd restarts the daemon", exc)
    os._exit(75)
