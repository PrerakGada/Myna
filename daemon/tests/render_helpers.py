"""Shared helpers for the render API tests (test_render_*.py).

The fake engine returns real 16-bit mono WAVs whose length is proportional to
the text, so concatenation, durations and encoders all see genuine audio.
"""

import io
import threading
import wave

from .v2_helpers import make_client

RATE = 24_000
FRAMES_PER_CHAR = 240  # 10 ms of audio per character


def make_wav(frames: int, rate: int = RATE, value: int = 1000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(value.to_bytes(2, "little", signed=True) * frames)
    return buf.getvalue()


def wav_frames(data: bytes) -> tuple[int, int]:
    with wave.open(io.BytesIO(data), "rb") as w:
        return w.getnframes(), w.getframerate()


class FakeEngine:
    """Records every synthesize call; returns a WAV sized by the text."""

    def __init__(self, fail_times: int = 0, exc: Exception | None = None):
        self.calls: list[dict] = []
        self.fail_times = fail_times
        self.exc = exc or RuntimeError("engine exploded")
        self.gate: threading.Event | None = None  # when set, calls block until it's set
        self.entered = threading.Event()
        self._lock = threading.Lock()

    def __call__(self, text, **kw):
        with self._lock:
            self.calls.append({"text": text, **kw})
            n = len(self.calls)
        self.entered.set()
        if self.gate is not None:
            assert self.gate.wait(10), "test gate never opened"
        if n <= self.fail_times:
            raise self.exc
        return make_wav(max(1, len(text)) * FRAMES_PER_CHAR)


def render_client(tmp_path, config_overrides=None, engine: FakeEngine | None = None, **kw):
    """make_client with a real-WAV fake engine and the renders folder in tmp."""
    engine = engine or FakeEngine()
    cfg = {"renders_dir": str(tmp_path / "renders")}
    cfg.update(config_overrides or {})
    client, player, app = make_client(config_overrides=cfg, synthesize=engine, **kw)
    # Never read the developer's real Hugging Face cache for voice files.
    hub = tmp_path / "hub"
    hub.mkdir(exist_ok=True)
    app.state.engine_store._hub = hub
    return client, app, engine
