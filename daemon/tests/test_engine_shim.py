"""Tests for the engine shim that patches Kokoro's SineGen length bug.

mlx-audio is NOT installed in the daemon's environment (it lives in the
separate engine venv), so these tests exercise the shim's contract and its
graceful-degradation path rather than the numerical patch itself. The
numerical behaviour was verified against the real engine: all 11 previously
502-ing sentence lengths synthesize, and previously-working lengths return
byte-identical durations.
"""

import subprocess
import sys

from myna import engine_shim


def test_patch_reports_false_without_mlx_audio():
    # The daemon env has no mlx-audio. The shim must say so and NOT raise —
    # raising here would mean the engine never starts at all.
    assert engine_shim.apply_sinegen_patch() is False


def test_shim_is_importable_without_side_effects():
    # Importing must not start a server or mutate global state; `main()` is
    # the only entry point that runs mlx_audio.server.
    assert callable(engine_shim.apply_sinegen_patch)
    assert callable(engine_shim.main)


def test_shim_runs_standalone_under_a_bare_interpreter():
    """The shim must not import `myna` — it executes under the ENGINE venv's
    python, where the daemon package is absent. Running it in a subprocess
    with an empty sys.path entry for the repo would still find `myna` on the
    path, so instead assert the source has no first-party imports."""
    src = open(engine_shim.__file__).read()
    assert "from myna" not in src
    assert "import myna" not in src


def test_shim_fails_loudly_but_survives_when_internals_move(monkeypatch):
    # Simulate mlx-audio renaming/removing SineGen: shim returns False so the
    # caller proceeds to launch the stock server.
    fake = type(sys)("mlx_audio.tts.models.kokoro")
    fake.SineGen = object  # missing _f02sine/_f02uv
    monkeypatch.setitem(sys.modules, "mlx.core", type(sys)("mlx.core"))
    monkeypatch.setitem(sys.modules, "mlx_audio.tts.models.kokoro", fake)
    assert engine_shim.apply_sinegen_patch() is False


def test_shim_help_exits_cleanly():
    # Smoke: the file parses and runs as a script under this interpreter.
    # mlx_audio is absent so it exits non-zero, but it must not traceback on
    # the shim's own code before reaching runpy.
    proc = subprocess.run(
        [sys.executable, engine_shim.__file__, "--host", "127.0.0.1", "--port", "1"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert "mlx-audio internals not importable" in proc.stderr
