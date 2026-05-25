"""Tests for GET /v2/status.

The shape is the contract — Lane A's Swift decoder loads the same fixture
file (docs/native-app/fixtures/status-response.json), so any drift here
breaks the Swift side at runtime.
"""

import json
import time

import myna

from .v2_helpers import FIXTURES_DIR, make_client


def _keys_deep(obj):
    """Set of sorted dotted-path key signatures for a JSON-ish object.

    Lists are normalized to their first item's keys (or [] for empty).
    """
    out: set[str] = set()

    def walk(node, prefix):
        if isinstance(node, dict):
            for k, v in node.items():
                p = f"{prefix}.{k}" if prefix else k
                out.add(p)
                walk(v, p)
        elif isinstance(node, list) and node:
            walk(node[0], f"{prefix}[]")

    walk(obj, "")
    return out


def test_v2_status_shape_matches_fixture():
    fixture = json.loads((FIXTURES_DIR / "status-response.json").read_text())
    client, fp, app = make_client()
    # Pre-populate registry so the items[] key path is exercised.
    app.state.registry.add("ECS", "Here is the first sixty characters of an announced message.")
    r = client.get("/v2/status")
    assert r.status_code == 200
    body = r.json()
    fixture_keys = _keys_deep(fixture)
    body_keys = _keys_deep(body)
    missing = fixture_keys - body_keys
    extra = body_keys - fixture_keys
    assert not missing, f"missing keys: {missing}"
    assert not extra, f"extra keys: {extra}"


def test_v2_status_engine_up_reflects_engine_check():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: True
    app.state.last_engine_check_at = 0.0
    r = client.get("/v2/status")
    assert r.json()["engine"]["status"] == "up"


def test_v2_status_engine_down_when_check_throws():
    client, fp, app = make_client()

    def boom(base_url, **kw):
        raise RuntimeError("connection refused")

    app.state.engine_up = boom
    app.state.last_engine_check_at = 0.0
    r = client.get("/v2/status")
    assert r.status_code == 200
    assert r.json()["engine"]["status"] == "down"


def test_v2_status_includes_uptime():
    client, fp, app = make_client()
    # Backdate started_at so uptime is observably > 0.
    app.state.started_at = time.time() - 5.0
    r1 = client.get("/v2/status").json()
    time.sleep(0.05)
    r2 = client.get("/v2/status").json()
    assert r1["daemon"]["uptime_s"] >= 5.0
    assert r2["daemon"]["uptime_s"] > r1["daemon"]["uptime_s"]


def test_v2_status_includes_daemon_version():
    client, fp, app = make_client()
    r = client.get("/v2/status").json()
    assert r["daemon"]["version"] == myna.__version__
    assert r["daemon"]["version"] == "0.2.0"


def test_v2_status_includes_registry_items():
    client, fp, app = make_client()
    client.post("/announce", json={"session_id": "s1", "label": "A", "text": "one"})
    client.post("/announce", json={"session_id": "s1", "label": "B", "text": "two"})
    r = client.get("/v2/status").json()
    assert r["registry"]["count"] == 2
    labels = [i["label"] for i in r["registry"]["items"]]
    assert labels == ["A", "B"]


def test_v2_status_v1_player_state_diagnostic_only():
    client, fp, app = make_client()
    r = client.get("/v2/status").json()
    # Field is present and has the documented shape, but Swift app ignores it.
    assert "v1_player" in r
    assert "state" in r["v1_player"]
    assert "now_playing" in r["v1_player"]


def test_v2_status_config_section_mirrors_loaded_config():
    client, fp, app = make_client(config_overrides={
        "voice": "am_michael",
        "chunk_chars": 999,
        "summary_model": "qwen3.5:7b",
        "lang_code": "b",
    })
    r = client.get("/v2/status").json()
    cfg = r["config"]
    assert cfg["voice"] == "am_michael"
    assert cfg["chunk_chars"] == 999
    assert cfg["summary_model"] == "qwen3.5:7b"
    assert cfg["lang_code"] == "b"
