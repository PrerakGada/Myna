"""Tests for POST /v2/synthesize (and /v2/synthesize-summary).

Spec: docs/native-app/API_CONTRACT.md § 2.
"""

import json
import urllib.parse

from .v2_helpers import make_client, parse_multipart


def _do_synth(client, payload, path="/v2/synthesize"):
    """POST and return (response, parsed_parts_or_None)."""
    r = client.post(path, json=payload)
    if r.headers.get("content-type", "").startswith("multipart/mixed"):
        return r, parse_multipart(r.content)
    return r, None


def test_v2_synthesize_streams_one_part_per_chunk():
    # Force three chunks by setting a tiny chunk_chars and providing three
    # sentences each shorter than the limit so they don't get hard-split.
    client, fp, app = make_client(config_overrides={"chunk_chars": 20})
    text = "First one. Second one. Third one."
    r, parts = _do_synth(client, {"text": text, "speed": 1.0, "mode": "full"})
    assert r.status_code == 200
    # 3 audio parts + 1 final JSON part
    audio_parts = [p for p in parts if p["headers"].get("Content-Type") == "audio/wav"]
    json_parts = [
        p for p in parts if p["headers"].get("Content-Type") == "application/json"
    ]
    assert len(audio_parts) == 3
    assert len(json_parts) == 1
    final = json.loads(json_parts[0]["body"])
    assert final["ok"] is True
    assert final["chunks"] == 3
    assert "session_id" in final


def test_v2_synthesize_part_headers_include_index_and_text():
    client, fp, app = make_client(config_overrides={"chunk_chars": 20})
    text = "First one. Second one. Third one."
    r, parts = _do_synth(client, {"text": text})
    assert r.status_code == 200
    audio_parts = [p for p in parts if p["headers"].get("Content-Type") == "audio/wav"]
    for i, p in enumerate(audio_parts):
        h = p["headers"]
        assert h["X-Chunk-Index"] == str(i)
        assert h["X-Chunk-Total-Estimate"] == str(len(audio_parts))
        assert "X-Chunk-Text" in h
        # urldecoded preview should look like real prose
        decoded = urllib.parse.unquote(h["X-Chunk-Text"])
        assert len(decoded) > 0


def test_v2_synthesize_returns_wav_bytes():
    client, fp, app = make_client()
    r, parts = _do_synth(client, {"text": "Hello there.", "mode": "full"})
    assert r.status_code == 200
    audio_parts = [p for p in parts if p["headers"].get("Content-Type") == "audio/wav"]
    assert len(audio_parts) >= 1
    for p in audio_parts:
        assert p["body"] == b"RIFFfake"


def test_v2_synthesize_rejects_empty():
    client, fp, app = make_client()
    r = client.post("/v2/synthesize", json={"text": "   "})
    assert r.status_code == 400
    body = r.json()
    detail = body.get("detail", body)
    assert detail["ok"] is False
    assert detail["reason"] == "empty"


def test_v2_synthesize_rejects_both_text_and_url():
    client, fp, app = make_client()
    r = client.post(
        "/v2/synthesize", json={"text": "hi", "url": "https://example.com"}
    )
    assert r.status_code == 400
    detail = r.json().get("detail", r.json())
    assert detail["reason"] == "both_text_and_url"


def test_v2_synthesize_rejects_neither():
    client, fp, app = make_client()
    r = client.post("/v2/synthesize", json={})
    assert r.status_code == 400
    detail = r.json().get("detail", r.json())
    assert detail["reason"] == "neither_text_nor_url"


def test_v2_synthesize_engine_down_returns_502():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: False
    # Bust the engine-status cache so the new value takes effect.
    app.state.last_engine_check_at = 0.0
    r = client.post("/v2/synthesize", json={"text": "hi"})
    assert r.status_code == 502
    body = r.json()
    assert body["ok"] is False
    assert body["reason"] == "engine_down"


def test_v2_synthesize_engine_error_returns_502():
    client, fp, app = make_client()

    def boom(text, **kw):
        raise RuntimeError("kokoro exploded")

    app.state.synthesize = boom
    r = client.post("/v2/synthesize", json={"text": "hi"})
    assert r.status_code == 502
    body = r.json()
    assert body["ok"] is False
    assert body["reason"] == "engine_error"
    assert "kokoro exploded" in body.get("detail", "")


def test_v2_synthesize_url_extracts_first():
    seen = {}

    def fake_extract(url):
        seen["url"] = url
        return "EXTRACTED ARTICLE TEXT"

    captured_synth = []

    def fake_synth(text, **kw):
        captured_synth.append(text)
        return b"RIFFfake"

    client, fp, app = make_client()
    app.state.extract = fake_extract
    app.state.synthesize = fake_synth
    r = client.post(
        "/v2/synthesize", json={"url": "https://example.com/x", "mode": "full"}
    )
    assert r.status_code == 200
    assert seen["url"] == "https://example.com/x"
    # The chunker received the extracted text.
    assert captured_synth and "EXTRACTED" in captured_synth[0]


def test_v2_synthesize_summary_mode_summarizes_first():
    summarized = {"calls": 0}

    def fake_summarize(text, **kw):
        summarized["calls"] += 1
        return "SHORT SUMMARY"

    captured = []

    def fake_synth(text, **kw):
        captured.append(text)
        return b"RIFFfake"

    client, fp, app = make_client()
    app.state.summarize = fake_summarize
    app.state.synthesize = fake_synth
    r = client.post(
        "/v2/synthesize", json={"text": "long article body", "mode": "summary"}
    )
    assert r.status_code == 200
    assert summarized["calls"] == 1
    # synthesize received the summary, not the original.
    assert captured and "SHORT SUMMARY" in captured[0]


def test_v2_synthesize_summary_alias_endpoint_forces_summary_mode():
    summarized = {"calls": 0}

    def fake_summarize(text, **kw):
        summarized["calls"] += 1
        return "SHORTER"

    client, fp, app = make_client()
    app.state.summarize = fake_summarize
    # Note: mode="full" in payload but the endpoint must override to summary.
    r = client.post(
        "/v2/synthesize-summary", json={"text": "long body", "mode": "full"}
    )
    assert r.status_code == 200
    assert summarized["calls"] == 1


def test_v2_synthesize_respects_voice_override():
    captured = {}

    def fake_synth(text, **kw):
        captured["voice"] = kw.get("voice")
        return b"RIFFfake"

    client, fp, app = make_client()
    app.state.synthesize = fake_synth
    r = client.post(
        "/v2/synthesize",
        json={"text": "hello", "voice": "am_michael", "mode": "full"},
    )
    assert r.status_code == 200
    assert captured["voice"] == "am_michael"


def test_v2_synthesize_respects_speed_in_synthesize_call():
    captured = {}

    def fake_synth(text, **kw):
        captured["speed"] = kw.get("speed")
        return b"RIFFfake"

    client, fp, app = make_client()
    app.state.synthesize = fake_synth
    r = client.post(
        "/v2/synthesize", json={"text": "hello", "speed": 1.5, "mode": "full"}
    )
    assert r.status_code == 200
    assert captured["speed"] == 1.5


def test_v2_synthesize_does_not_touch_player():
    client, fp, app = make_client()
    r = client.post("/v2/synthesize", json={"text": "Hello there."})
    assert r.status_code == 200
    # No play/pause/resume/stop calls.
    assert not any(c[0] in {"play", "pause", "resume", "stop"} for c in fp.calls)


def test_v2_synthesize_session_id_echoed_when_provided():
    client, fp, app = make_client()
    r, parts = _do_synth(
        client, {"text": "hello", "session_id": "abc-123"}
    )
    json_parts = [
        p for p in parts if p["headers"].get("Content-Type") == "application/json"
    ]
    final = json.loads(json_parts[0]["body"])
    assert final["session_id"] == "abc-123"


def test_v2_synthesize_url_extract_failure_returns_400():
    client, fp, app = make_client()
    app.state.extract = lambda url: None
    r = client.post(
        "/v2/synthesize", json={"url": "https://example.com/dead"}
    )
    assert r.status_code == 400
    detail = r.json().get("detail", r.json())
    assert detail["reason"] == "extract_failed"
