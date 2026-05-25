"""Tests for GET /v2/health."""

import json
import time

import myna

from .v2_helpers import FIXTURES_DIR, make_client


def test_v2_health_shape_matches_fixture():
    fixture = json.loads((FIXTURES_DIR / "health-response.json").read_text())
    client, fp, app = make_client()
    r = client.get("/v2/health")
    assert r.status_code == 200
    body = r.json()
    assert set(body.keys()) == set(fixture.keys())


def test_v2_health_returns_ok():
    client, fp, app = make_client()
    r = client.get("/v2/health").json()
    assert r["ok"] is True


def test_v2_health_includes_version():
    client, fp, app = make_client()
    r = client.get("/v2/health").json()
    assert r["version"] == myna.__version__
    assert r["version"] == "0.2.0"


def test_v2_health_engine_up_field():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: True
    app.state.last_engine_check_at = 0.0
    assert client.get("/v2/health").json()["engine_up"] is True
    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0
    assert client.get("/v2/health").json()["engine_up"] is False


def test_v2_health_fast_when_engine_cached():
    """A recent (<1s) engine check is reused — no second engine_up call."""
    calls = {"n": 0}

    def counting_up(base_url, **kw):
        calls["n"] += 1
        return True

    client, fp, app = make_client()
    app.state.engine_up = counting_up
    app.state.last_engine_check_at = 0.0
    client.get("/v2/health")  # triggers first real check
    first = calls["n"]
    assert first >= 1
    # Immediately call again — should reuse the cached value.
    client.get("/v2/health")
    assert calls["n"] == first


def test_v2_health_recheck_after_ttl():
    calls = {"n": 0}

    def counting_up(base_url, **kw):
        calls["n"] += 1
        return True

    client, fp, app = make_client()
    app.state.engine_up = counting_up
    app.state.last_engine_check_at = 0.0
    client.get("/v2/health")
    n1 = calls["n"]
    # Backdate the cache so the next call must re-check.
    app.state.last_engine_check_at = time.time() - 10.0
    client.get("/v2/health")
    assert calls["n"] == n1 + 1
