"""Tests for POST /v2/summarize."""

from .v2_helpers import make_client


def test_v2_summarize_returns_summary():
    client, fp, app = make_client()
    app.state.summarize = lambda text, **kw: "SHORT"
    r = client.post("/v2/summarize", json={"text": "this is a long body"})
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["summary"] == "SHORT"


def test_v2_summarize_rejects_empty():
    client, fp, app = make_client()
    r = client.post("/v2/summarize", json={"text": "   "})
    assert r.status_code == 400
    detail = r.json().get("detail", r.json())
    assert detail["reason"] == "empty"


def test_v2_summarize_passes_model_and_url_from_config():
    captured = {}

    def fake_summarize(text, **kw):
        captured.update(kw)
        return "SUMMARY"

    client, fp, app = make_client(config_overrides={
        "summary_model": "qwen3.5:7b",
        "ollama_url": "http://127.0.0.1:11434",
    })
    app.state.summarize = fake_summarize
    r = client.post("/v2/summarize", json={"text": "long body"})
    assert r.status_code == 200
    assert captured["model"] == "qwen3.5:7b"
    assert captured["base_url"] == "http://127.0.0.1:11434"


def test_v2_summarize_passes_text_unchanged():
    seen = {}

    def fake_summarize(text, **kw):
        seen["text"] = text
        return "ok"

    client, fp, app = make_client()
    app.state.summarize = fake_summarize
    client.post("/v2/summarize", json={"text": "the quick brown fox"})
    assert seen["text"] == "the quick brown fox"


def test_v2_summarize_strips_surrounding_whitespace_before_rejecting():
    client, fp, app = make_client()
    # Whitespace-only is empty.
    r = client.post("/v2/summarize", json={"text": "\n\t  "})
    assert r.status_code == 400
