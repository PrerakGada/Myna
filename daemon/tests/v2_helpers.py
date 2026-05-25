"""Shared test helpers for v2 endpoint tests.

Keeps each v2 test file focused on its endpoint while still mirroring the
v1 test pattern of injecting fakes via app.state attributes.
"""

import pathlib

from fastapi.testclient import TestClient

from myna.app import create_app


FIXTURES_DIR = (
    pathlib.Path(__file__).resolve().parents[2]
    / "docs"
    / "native-app"
    / "fixtures"
)


class FakePlayer:
    """Trip-wire player — fails the test on any call.

    v2 endpoints must NEVER touch the daemon's internal Player.
    """

    def __init__(self):
        self.calls: list = []

    def _record(self, name, *args, **kwargs):
        self.calls.append((name, args, kwargs))

    def play(self, *a, **kw):
        self._record("play", *a, **kw)

    def pause(self, *a, **kw):
        self._record("pause", *a, **kw)

    def resume(self, *a, **kw):
        self._record("resume", *a, **kw)

    def stop(self, *a, **kw):
        self._record("stop", *a, **kw)

    def status(self):
        # status() is allowed — /v2/status reports it for diagnostics.
        return {"state": "idle", "now_playing": None}


def make_client(config_overrides=None, **state_overrides):
    """Build a TestClient with sensible v2 defaults.

    Defaults:
      synthesize → returns b"RIFFfake"
      engine_up  → True
      summarize  → "SUMMARY"
      extract    → "EXTRACTED"
      player     → FakePlayer (will record any v2-side misuse)

    `config_overrides` are merged into the loaded config before create_app.
    `state_overrides` are setattr'd on app.state after create_app.
    """
    from myna.config import load_config

    cfg = load_config()
    if config_overrides:
        cfg.update(config_overrides)

    app = create_app(cfg)
    fp = FakePlayer()
    app.state.player = fp
    app.state.synthesize = lambda text, **kw: b"RIFFfake"
    app.state.engine_up = lambda base_url, **kw: True
    app.state.summarize = lambda text, **kw: "SUMMARY"
    app.state.extract = lambda url: "EXTRACTED"
    for k, v in state_overrides.items():
        setattr(app.state, k, v)
    return TestClient(app), fp, app


def parse_multipart(body: bytes, boundary: bytes = b"mynachunk"):
    """Minimal parser for the /v2/synthesize multipart/mixed format.

    Returns a list of dicts with keys: headers (dict), body (bytes).
    The final --boundary-- terminator part is dropped.
    """
    sep = b"--" + boundary
    parts: list[dict] = []
    # Split, drop the leading empty piece (everything before the first boundary).
    segments = body.split(sep)
    for seg in segments[1:]:
        if seg.startswith(b"--"):
            # closing boundary
            continue
        # Each segment starts with \r\n then headers\r\n\r\nbody\r\n
        if seg.startswith(b"\r\n"):
            seg = seg[2:]
        try:
            header_blob, payload = seg.split(b"\r\n\r\n", 1)
        except ValueError:
            continue
        headers = {}
        for line in header_blob.split(b"\r\n"):
            if not line:
                continue
            if b":" in line:
                k, v = line.split(b":", 1)
                headers[k.decode().strip()] = v.decode().strip()
        # Trim trailing \r\n that comes before the next boundary marker.
        if payload.endswith(b"\r\n"):
            payload = payload[:-2]
        parts.append({"headers": headers, "body": payload})
    return parts
