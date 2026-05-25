"""Tests for GET /v2/voices.

Spec: API_CONTRACT.md § 2 and the fixture at
docs/native-app/fixtures/voices-response.json.
"""

import json

import myna.app as app_mod

from .v2_helpers import FIXTURES_DIR, make_client


class _SpyHttpx:
    """Captures calls to httpx.get and returns a configurable response."""

    def __init__(self, payload=None, exc=None):
        self.calls: list[tuple[str, dict]] = []
        self._payload = payload
        self._exc = exc

    def __call__(self, url, timeout=None, **kw):
        self.calls.append((url, {"timeout": timeout, **kw}))
        if self._exc:
            raise self._exc

        class R:
            def __init__(self, payload):
                self._payload = payload

            def raise_for_status(self):
                pass

            def json(self):
                return self._payload

        return R(self._payload)


def test_v2_voices_shape_matches_fixture(monkeypatch):
    fixture = json.loads((FIXTURES_DIR / "voices-response.json").read_text())
    client, fp, app = make_client()
    # Engine returns the fixture's id list — endpoint should produce the
    # same shape (id/label/lang/default), with af_heart as default per cfg.
    payload = {"voices": [{"id": v["id"]} for v in fixture["voices"]]}
    spy = _SpyHttpx(payload=payload)
    monkeypatch.setattr(app_mod.httpx, "get", spy)
    r = client.get("/v2/voices")
    assert r.status_code == 200
    body = r.json()
    # Same set of voice ids
    fixture_ids = {v["id"] for v in fixture["voices"]}
    body_ids = {v["id"] for v in body["voices"]}
    assert fixture_ids.issubset(body_ids)
    # Every voice has all four keys
    for v in body["voices"]:
        assert set(v.keys()) >= {"id", "label", "lang", "default"}
    # Exactly one default and it's the configured voice (af_heart).
    defaults = [v for v in body["voices"] if v["default"]]
    assert len(defaults) == 1
    assert defaults[0]["id"] == "af_heart"


def test_v2_voices_queries_engine_on_first_call(monkeypatch):
    client, fp, app = make_client()
    spy = _SpyHttpx(payload={"voices": ["af_heart", "af_bella"]})
    monkeypatch.setattr(app_mod.httpx, "get", spy)
    client.get("/v2/voices")
    # The first http call after the cached engine_up is the voices fetch.
    assert any("/v1/voices" in url for url, _ in spy.calls)


def test_v2_voices_cached_for_5_minutes(monkeypatch):
    client, fp, app = make_client()
    spy = _SpyHttpx(payload={"voices": ["af_heart"]})
    monkeypatch.setattr(app_mod.httpx, "get", spy)
    client.get("/v2/voices")
    client.get("/v2/voices")
    client.get("/v2/voices")
    voice_fetches = [u for u, _ in spy.calls if "/v1/voices" in u]
    assert len(voice_fetches) == 1


def test_v2_voices_cache_expires(monkeypatch):
    client, fp, app = make_client()
    spy = _SpyHttpx(payload={"voices": ["af_heart"]})
    monkeypatch.setattr(app_mod.httpx, "get", spy)
    client.get("/v2/voices")
    # Simulate cache expiry by zeroing the cache timestamp.
    app.state.voices_cache_at = 0.0
    client.get("/v2/voices")
    voice_fetches = [u for u, _ in spy.calls if "/v1/voices" in u]
    assert len(voice_fetches) == 2


def test_v2_voices_engine_down_returns_empty():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0
    r = client.get("/v2/voices")
    assert r.status_code == 200
    body = r.json()
    assert body["voices"] == []
    assert body.get("engine") == "down"


def test_v2_voices_includes_default_voice_marker(monkeypatch):
    client, fp, app = make_client(config_overrides={"voice": "am_michael"})
    spy = _SpyHttpx(payload={"voices": ["af_heart", "am_michael", "af_bella"]})
    monkeypatch.setattr(app_mod.httpx, "get", spy)
    r = client.get("/v2/voices").json()
    defaults = [v for v in r["voices"] if v["default"]]
    assert len(defaults) == 1
    assert defaults[0]["id"] == "am_michael"


def test_v2_voices_falls_back_to_hardcoded_when_engine_endpoint_404s(
    monkeypatch,
):
    client, fp, app = make_client()

    def boom(url, timeout=None, **kw):
        raise RuntimeError("404")

    monkeypatch.setattr(app_mod.httpx, "get", boom)
    # engine_up is the lambda from make_client (returns True), so we'll reach
    # the fetch path which fails and falls back.
    r = client.get("/v2/voices").json()
    ids = {v["id"] for v in r["voices"]}
    # The four documented Kokoro voice ids
    assert {"af_heart", "af_bella", "am_michael", "am_adam"}.issubset(ids)
