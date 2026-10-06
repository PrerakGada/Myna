"""summary_style on /v2/synthesize and /v2/summarize, GET /v2/summarize/status,
and summary failures as 503 JSON (myna.summary_routes)."""

from myna.summarize import SummaryUnavailable
from myna.v2_types import V2SummarizeReq, V2SynthesizeReq

from .v2_helpers import make_client


def _recording_summarize(seen):
    def fake(text, **kw):
        seen.update(kw, text=text)
        return "SHORT"

    return fake


def test_request_models_take_an_optional_style():
    assert V2SynthesizeReq(text="x").summary_style is None
    assert V2SynthesizeReq(text="x", mode="summary", summary_style="key_points").summary_style == "key_points"
    assert V2SummarizeReq(text="x", summary_style="plain_english").summary_style == "plain_english"


def test_synthesize_passes_the_style_to_the_summarizer():
    seen = {}
    client, _, app = make_client(summarize=_recording_summarize(seen))
    r = client.post(
        "/v2/synthesize",
        json={"text": "long body", "mode": "summary", "summary_style": "action_items"},
    )
    assert r.status_code == 200
    assert seen["style"] == "action_items"
    assert seen["text"] == "long body"


def test_synthesize_without_a_style_passes_none():
    seen = {}
    client, _, _ = make_client(summarize=_recording_summarize(seen))
    r = client.post("/v2/synthesize", json={"text": "long body", "mode": "summary"})
    assert r.status_code == 200
    assert seen["style"] is None


def test_full_reads_never_summarize_even_with_a_style():
    seen = {}
    client, _, _ = make_client(summarize=_recording_summarize(seen))
    r = client.post("/v2/synthesize", json={"text": "body", "summary_style": "tldr"})
    assert r.status_code == 200
    assert seen == {}


def test_summarize_endpoint_passes_the_style():
    seen = {}
    client, _, _ = make_client(summarize=_recording_summarize(seen))
    r = client.post("/v2/summarize", json={"text": "long body", "summary_style": "key_points"})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "summary": "SHORT"}
    assert seen["style"] == "key_points"


def test_a_failed_summary_is_503_with_a_reason():
    def failing(text, **kw):
        raise SummaryUnavailable("summary_model_missing", "qwen3.5:4b not found")

    client, _, app = make_client(summarize=failing)
    r = client.post("/v2/synthesize", json={"text": "long body", "mode": "summary"})
    assert r.status_code == 503
    assert r.json() == {"ok": False, "reason": "summary_model_missing", "detail": "qwen3.5:4b not found"}
    # The read never started, so the state machine isn't left thinking.
    assert app.state.machine.snapshot()["state"] != "thinking"

    r = client.post("/v2/summarize", json={"text": "long body"})
    assert r.status_code == 503
    assert r.json()["reason"] == "summary_model_missing"


def test_status_reports_the_ollama_probe_and_styles():
    probed = {}

    def probe(**kw):
        probed.update(kw)
        return {"state": "model_missing", "model": kw["model"], "url": kw["base_url"]}

    client, _, _ = make_client(
        config_overrides={"summary_model": "qwen3.5:4b", "ollama_url": "http://127.0.0.1:11434"},
        ollama_status=probe,
    )
    r = client.get("/v2/summarize/status")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["ollama"] == {"state": "model_missing", "model": "qwen3.5:4b", "url": "http://127.0.0.1:11434"}
    assert body["styles"] == ["tldr", "key_points", "action_items", "plain_english"]
    assert body["default_style"] == "tldr"
    assert probed == {"base_url": "http://127.0.0.1:11434", "model": "qwen3.5:4b"}
