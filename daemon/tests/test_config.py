import json

import myna.config as c


def test_defaults_when_no_file(monkeypatch, tmp_path):
    monkeypatch.setattr(c, "CONFIG_PATH", tmp_path / "nope.json")
    cfg = c.load_config()
    assert cfg["voice"] == "af_heart"
    assert cfg["daemon_port"] == 8766
    assert cfg["summary_model"] == "qwen3.5:4b"
    assert cfg["summary_think"] is False
    assert cfg["summary_timeout"] == 60.0


def test_file_overrides_defaults(monkeypatch, tmp_path):
    p = tmp_path / "config.json"
    p.write_text(json.dumps({"voice": "am_michael", "speed": 1.5}))
    monkeypatch.setattr(c, "CONFIG_PATH", p)
    cfg = c.load_config()
    assert cfg["voice"] == "am_michael"
    assert cfg["speed"] == 1.5
    assert cfg["daemon_port"] == 8766  # untouched default preserved
