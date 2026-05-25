"""Regression tests for the Lane C audit fixes.

Each test pins a specific bug the auditor caught, so it cannot return silently.

- 🔴 #1 — /v2/voices happy path must not leak `engine: null`
- 🔴 #2 — /v2/extract success body must not leak `title/byline/reason: null`
         and /v2/summarize success must not leak `reason: null`
- 🟡 #1 — /v2/synthesize must clamp speed into [0.5, 2.0]
"""

from tests.v2_helpers import make_client, parse_multipart


# ----- 🔴 #1 — /v2/voices happy path key-set must match fixture exactly -----

def test_v2_voices_engine_up_response_has_no_engine_key():
    """Happy path: response body keys must be exactly {voices}."""
    client, _, _ = make_client()
    r = client.get("/v2/voices")
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"voices"}, f"unexpected keys: {set(body)}"
    assert "engine" not in body, "engine field must be absent on happy path"


def test_v2_voices_engine_down_still_emits_engine_down():
    """Down path: response body must be exactly {voices: [], engine: 'down'}."""
    client, _, _ = make_client(engine_up=lambda base_url, **kw: False)
    r = client.get("/v2/voices")
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"voices", "engine"}
    assert body == {"voices": [], "engine": "down"}


# ----- 🔴 #2 — /v2/extract success keys match fixture; failure has only {ok, reason} -----

def test_v2_extract_success_string_return_has_no_null_fields():
    """When `extract` returns a plain str, body is {ok, text} — no nulls."""
    client, _, _ = make_client(extract=lambda url: "ARTICLE BODY")
    r = client.post("/v2/extract", json={"url": "https://example.com/a"})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"ok", "text"}, f"unexpected keys: {set(body)}"
    assert body == {"ok": True, "text": "ARTICLE BODY"}


def test_v2_extract_success_dict_return_includes_title_byline():
    """When `extract` returns a dict with title/byline, those keys appear; reason does not."""
    client, _, _ = make_client(
        extract=lambda url: {"text": "BODY", "title": "T", "byline": "B"}
    )
    r = client.post("/v2/extract", json={"url": "https://example.com/a"})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"ok", "text", "title", "byline"}
    assert "reason" not in body
    assert body == {"ok": True, "text": "BODY", "title": "T", "byline": "B"}


def test_v2_extract_failure_has_only_ok_and_reason():
    """Failure body has no `text/title/byline` keys, only {ok, reason}."""
    client, _, _ = make_client(extract=lambda url: None)
    r = client.post("/v2/extract", json={"url": "https://example.com/a"})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"ok", "reason"}
    assert body == {"ok": False, "reason": "extract_failed"}


def test_v2_summarize_success_has_no_reason_field():
    """Success body is {ok, summary} — no leaked reason: null."""
    client, _, _ = make_client(summarize=lambda text, **kw: "SHORT")
    r = client.post("/v2/summarize", json={"text": "long body"})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"ok", "summary"}
    assert body == {"ok": True, "summary": "SHORT"}


# ----- 🟡 #1 — /v2/synthesize must clamp `speed` into [0.5, 2.0] -----

def test_v2_synthesize_speed_clamped_too_high():
    """speed=10.0 must be clamped to 2.0 before reaching engine.synthesize."""
    seen_speeds: list[float] = []

    def spy(text, *, speed, **kw):
        seen_speeds.append(speed)
        return b"RIFFfake"

    client, _, _ = make_client(synthesize=spy)
    r = client.post(
        "/v2/synthesize",
        json={"text": "Hello.", "speed": 10.0},
    )
    assert r.status_code == 200
    assert seen_speeds, "synthesize was never invoked"
    assert all(s == 2.0 for s in seen_speeds), (
        f"expected speed clamped to 2.0, got {seen_speeds}"
    )


def test_v2_synthesize_speed_clamped_too_low():
    """speed=0.1 must be clamped to 0.5."""
    seen_speeds: list[float] = []

    def spy(text, *, speed, **kw):
        seen_speeds.append(speed)
        return b"RIFFfake"

    client, _, _ = make_client(synthesize=spy)
    r = client.post(
        "/v2/synthesize",
        json={"text": "Hello.", "speed": 0.1},
    )
    assert r.status_code == 200
    assert seen_speeds
    assert all(s == 0.5 for s in seen_speeds)


def test_v2_synthesize_speed_in_range_passes_through():
    """speed=1.25 must reach engine unchanged."""
    seen_speeds: list[float] = []

    def spy(text, *, speed, **kw):
        seen_speeds.append(speed)
        return b"RIFFfake"

    client, _, _ = make_client(synthesize=spy)
    r = client.post(
        "/v2/synthesize",
        json={"text": "Hello.", "speed": 1.25},
    )
    assert r.status_code == 200
    assert all(s == 1.25 for s in seen_speeds)


def test_v2_synthesize_speed_boundary_two_passes():
    """Exact upper bound 2.0 is accepted unchanged."""
    seen_speeds: list[float] = []
    client, _, _ = make_client(
        synthesize=lambda text, *, speed, **kw: (seen_speeds.append(speed) or b"RIFF")
    )
    r = client.post("/v2/synthesize", json={"text": "Hi.", "speed": 2.0})
    assert r.status_code == 200
    assert all(s == 2.0 for s in seen_speeds)


def test_v2_synthesize_speed_boundary_half_passes():
    """Exact lower bound 0.5 is accepted unchanged."""
    seen_speeds: list[float] = []
    client, _, _ = make_client(
        synthesize=lambda text, *, speed, **kw: (seen_speeds.append(speed) or b"RIFF")
    )
    r = client.post("/v2/synthesize", json={"text": "Hi.", "speed": 0.5})
    assert r.status_code == 200
    assert all(s == 0.5 for s in seen_speeds)


# ----- Multipart shape unchanged by the fixes -----

def test_v2_synthesize_multipart_shape_unchanged_after_clamp():
    """The audit fixes must not change the streaming protocol shape."""
    client, _, _ = make_client()
    with client.stream(
        "POST", "/v2/synthesize", json={"text": "Hello there.", "speed": 1.0}
    ) as r:
        body = b"".join(r.iter_bytes())
    parts = parse_multipart(body)
    # at least one audio part + the final JSON part
    assert len(parts) >= 2
    audio_parts = [p for p in parts if p["headers"].get("Content-Type") == "audio/wav"]
    json_parts = [
        p for p in parts if p["headers"].get("Content-Type") == "application/json"
    ]
    assert len(audio_parts) >= 1
    assert len(json_parts) == 1
    # final JSON shape
    import json as _json
    final = _json.loads(json_parts[0]["body"])
    assert set(final) >= {"ok", "chunks", "session_id"}
    assert final["ok"] is True
