"""Tests for GET /v2/model/status.

The daemon doesn't actually own the Kokoro model (see app.py header
comment), so this endpoint is a read-only diagnostic — there are no
suspend/resume actions to test.
"""

from .v2_helpers import make_client


def test_model_status_shape():
    client, _, _ = make_client()
    r = client.get("/v2/model/status")
    assert r.status_code == 200
    body = r.json()
    assert set(body.keys()) == {
        "model_loaded",
        "engine_url",
        "daemon_rss_mb",
        "daemon_pid",
        "suspend_supported",
        "engine_memory_mb",
        "engine_pid",
    }


def test_model_status_reflects_engine_state_up():
    client, _, app = make_client()
    app.state.engine_up = lambda base_url, **kw: True
    app.state.last_engine_check_at = 0.0  # bust cache

    r = client.get("/v2/model/status")
    assert r.status_code == 200
    body = r.json()
    assert body["model_loaded"] is True


def test_model_status_reflects_engine_state_down():
    client, _, app = make_client()
    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0  # bust cache

    r = client.get("/v2/model/status")
    assert r.status_code == 200
    body = r.json()
    assert body["model_loaded"] is False


def test_suspend_not_supported_by_daemon():
    # The daemon is a thin proxy to an out-of-process engine, so it
    # can't meaningfully suspend a model it doesn't own. The Swift app
    # should hide the "Pause Myna" toggle when this flag is False.
    client, _, _ = make_client()
    r = client.get("/v2/model/status")
    assert r.json()["suspend_supported"] is False


def test_daemon_rss_is_non_negative():
    client, _, _ = make_client()
    r = client.get("/v2/model/status")
    rss = r.json()["daemon_rss_mb"]
    assert isinstance(rss, (int, float))
    assert rss >= 0


def test_daemon_pid_matches_current_process():
    import os

    client, _, _ = make_client()
    r = client.get("/v2/model/status")
    assert r.json()["daemon_pid"] == os.getpid()


def test_engine_url_echoes_config():
    client, _, _ = make_client(
        config_overrides={"engine_url": "http://127.0.0.1:9999"}
    )
    r = client.get("/v2/model/status")
    assert r.json()["engine_url"] == "http://127.0.0.1:9999"
