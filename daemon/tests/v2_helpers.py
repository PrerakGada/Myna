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


def make_client(config_overrides=None, registry_path=None, **state_overrides):
    """Build a TestClient with sensible v2 defaults.

    Defaults:
      synthesize → returns b"RIFFfake"
      engine_up  → True
      summarize  → "SUMMARY"
      extract    → "EXTRACTED"
      player     → FakePlayer (will record any v2-side misuse)
      v2_registry → fresh in-memory (path in a tempfile per call if provided)
      wardrobe   → tmpdir-backed VoiceWardrobe (no user state collision)
      detect_language → returns None (langid is optional in tests)

    `config_overrides` are merged into the loaded config before create_app.
    `registry_path` (Path|None): override the v2 registry persistence path
        — tests should pass a tmp_path to avoid touching ~/.cache/myna.
    `state_overrides` are setattr'd on app.state after create_app.
    """
    import tempfile

    import copy

    from myna.config import DEFAULTS
    from myna.v2_registry import V2Registry
    from myna.voice_wardrobe import VoiceWardrobe

    # Built-in defaults, never the developer's ~/.config/myna/config.json —
    # a real config (say, a different engine) must not change test results.
    cfg = copy.deepcopy(DEFAULTS)
    # Disable karaoke for tests by default — make_client() callers that
    # want to exercise the karaoke path should override via state_overrides.
    cfg["karaoke"] = {"enabled": False}
    if config_overrides:
        cfg.update(config_overrides)

    app = create_app(cfg)
    fp = FakePlayer()
    app.state.player = fp
    app.state.synthesize = lambda text, **kw: b"RIFFfake"
    app.state.engine_up = lambda base_url, **kw: True
    # Never reach a real engine: report the configured model as loaded.
    app.state.loaded_models = lambda base_url, **kw: [cfg["model"]]
    app.state.summarize = lambda text, **kw: "SUMMARY"
    app.state.extract = lambda url: "EXTRACTED"
    if registry_path is not None:
        app.state.v2_registry = V2Registry(path=registry_path)
    # Isolate wardrobe state so test runs don't pollute the user's
    # ~/.config/myna/voice_wardrobe.json. Each test gets a fresh tmpdir.
    tmpdir = tempfile.mkdtemp(prefix="myna-wardrobe-")
    import pathlib

    app.state.wardrobe = VoiceWardrobe(path=pathlib.Path(tmpdir) / "voice_wardrobe.json")
    # Same for the user's own voices and the library download cache. The
    # library never reaches the network in tests: a download is an error
    # unless a test installs its own fetch.
    from myna.voice_library import VoiceLibrary
    from myna.voice_store import VoiceStore

    def _no_network(url):
        raise RuntimeError(f"test tried to download {url}")

    app.state.voice_store = VoiceStore(root=pathlib.Path(tmpdir) / "voices")
    app.state.voice_library = VoiceLibrary(cache_dir=pathlib.Path(tmpdir) / "library", fetch=_no_network)
    # An empty pronunciation list, in memory: tests that aren't about
    # pronunciations mustn't change when the starter list does, and none
    # may touch ~/.config/myna/pronunciations.json.
    from myna.pronunciations import PronunciationStore

    app.state.pronunciations = PronunciationStore(None, starter=())
    # Tests default to "language detection finds nothing" so v2 synthesize
    # tests don't accidentally gain X-Myna-Detected-Lang headers.
    app.state.detect_language = lambda text: None
    for k, v in state_overrides.items():
        setattr(app.state, k, v)
    # base_url="http://127.0.0.1" so requests carry Host: 127.0.0.1,
    # which the TrustedHostMiddleware accepts. (Default TestClient base
    # is http://testserver — that would be rejected by the middleware,
    # since "testserver" isn't a deployed host name.)
    return TestClient(app, base_url="http://127.0.0.1"), fp, app


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
