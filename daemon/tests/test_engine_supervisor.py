"""Tests for the engine supervisor — the daemon owning the mlx-audio engine.

We never spawn a real engine here: engine_up + Popen are monkeypatched so we
assert the *decision* logic (when to spawn / re-spawn / leave alone) and the
launch command, deterministically.
"""

from myna.engine_supervisor import EngineSupervisor


class _FakeProc:
    def __init__(self, alive=True):
        self._alive = alive

    def poll(self):
        return None if self._alive else 0


def _make(tmp_path):
    venv = tmp_path / "venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "bin" / "python").write_text("")  # _spawn only checks existence
    return EngineSupervisor(
        engine_url="http://127.0.0.1:8765",
        venv_dir=str(venv),
        log_path=str(tmp_path / "engine.log"),
    )


def test_port_parsed_from_url(tmp_path):
    sup = EngineSupervisor(
        engine_url="http://127.0.0.1:9999",
        venv_dir=str(tmp_path),
        log_path=str(tmp_path / "l.log"),
    )
    assert sup._port == 9999
    assert sup._host == "127.0.0.1"


def test_no_spawn_when_engine_already_up(tmp_path, monkeypatch):
    sup = _make(tmp_path)
    monkeypatch.setattr("myna.engine_supervisor.engine_up", lambda url, **kw: True)
    spawned = []
    monkeypatch.setattr(sup, "_spawn", lambda: spawned.append(1))
    sup._ensure_running()
    assert spawned == []  # something already serving -> leave it alone


def test_spawns_when_engine_down(tmp_path, monkeypatch):
    sup = _make(tmp_path)
    monkeypatch.setattr("myna.engine_supervisor.engine_up", lambda url, **kw: False)
    spawned = []
    monkeypatch.setattr(sup, "_spawn", lambda: spawned.append(1))
    sup._ensure_running()
    assert spawned == [1]


def test_no_respawn_while_our_child_is_alive(tmp_path, monkeypatch):
    sup = _make(tmp_path)
    monkeypatch.setattr("myna.engine_supervisor.engine_up", lambda url, **kw: False)
    sup._proc = _FakeProc(alive=True)  # still coming up
    spawned = []
    monkeypatch.setattr(sup, "_spawn", lambda: spawned.append(1))
    sup._ensure_running()
    assert spawned == []


def test_respawns_after_our_child_died(tmp_path, monkeypatch):
    sup = _make(tmp_path)
    monkeypatch.setattr("myna.engine_supervisor.engine_up", lambda url, **kw: False)
    sup._proc = _FakeProc(alive=False)  # exited
    spawned = []
    monkeypatch.setattr(sup, "_spawn", lambda: spawned.append(1))
    sup._ensure_running()
    assert spawned == [1]


def test_spawn_command_and_espeak_env(tmp_path, monkeypatch):
    sup = _make(tmp_path)
    captured = {}

    def fake_popen(cmd, **kw):
        captured["cmd"] = cmd
        captured["env"] = kw.get("env", {})
        return _FakeProc(alive=True)

    monkeypatch.setattr("myna.engine_supervisor.subprocess.Popen", fake_popen)
    monkeypatch.setattr(
        sup,
        "_engine_env",
        lambda: {
            "PHONEMIZER_ESPEAK_LIBRARY": "/x/lib",
            "ESPEAK_DATA_PATH": "/x/data",
        },
    )
    sup._spawn()
    assert "mlx_audio.server" in captured["cmd"]
    assert "--port" in captured["cmd"] and "8765" in captured["cmd"]
    assert captured["env"]["PHONEMIZER_ESPEAK_LIBRARY"] == "/x/lib"


def test_spawn_noops_without_venv(tmp_path, monkeypatch):
    # No venv python on disk -> setup hasn't run -> don't spawn.
    sup = EngineSupervisor(
        engine_url="http://127.0.0.1:8765",
        venv_dir=str(tmp_path / "missing"),
        log_path=str(tmp_path / "l.log"),
    )
    called = []
    monkeypatch.setattr(
        "myna.engine_supervisor.subprocess.Popen",
        lambda *a, **k: called.append(1),
    )
    sup._spawn()
    assert called == []
    assert sup._proc is None
