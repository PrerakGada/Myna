import myna.summarize as s


def test_prompt_includes_text_and_no_markdown_instruction():
    p = s.build_summary_prompt("ARTICLE BODY")
    assert "ARTICLE BODY" in p
    assert "no markdown" in p.lower() or "no markdown" in p.lower()
    assert "listening" in p.lower()


def test_summarize_posts_to_ollama_and_returns_response(monkeypatch):
    captured = {}

    class FakeResp:
        def raise_for_status(self):
            pass

        def json(self):
            return {"response": "  short spoken summary  "}

    def fake_post(url, json, timeout):
        captured["url"] = url
        captured["json"] = json
        return FakeResp()

    monkeypatch.setattr(s.httpx, "post", fake_post)
    out = s.summarize("long text", model="qwen3.5:4b", base_url="http://x:11434")
    assert out == "short spoken summary"
    assert captured["url"] == "http://x:11434/api/generate"
    assert captured["json"]["model"] == "qwen3.5:4b"
    assert captured["json"]["stream"] is False
    assert "long text" in captured["json"]["prompt"]
    # think defaults off so reasoning models return in seconds, not minutes
    assert captured["json"]["think"] is False


def test_summarize_think_can_be_enabled(monkeypatch):
    captured = {}

    class FakeResp:
        def raise_for_status(self):
            pass

        def json(self):
            return {"response": "summary"}

    monkeypatch.setattr(
        s.httpx,
        "post",
        lambda url, json, timeout: captured.update(json=json) or FakeResp(),
    )
    s.summarize("t", model="m", base_url="http://x", think=True)
    assert captured["json"]["think"] is True
