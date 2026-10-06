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


# ----- styles, long text, failures (Apple-first summaries lane) -----

import httpx
import pytest


class _Resp:
    def __init__(self, text="summary"):
        self._text = text

    def raise_for_status(self):
        pass

    def json(self):
        return {"response": self._text}


def _capture_posts(monkeypatch, answer="summary"):
    prompts = []

    def fake_post(url, json, timeout):
        prompts.append(json)
        return _Resp(answer)

    monkeypatch.setattr(s.httpx, "post", fake_post)
    return prompts


@pytest.mark.parametrize("style", s.STYLES)
def test_every_style_has_its_own_prompt_and_the_listening_rules(style):
    p = s.build_summary_prompt("BODY", style)
    assert s.style_prompt(style) in p
    assert p.startswith(s.INSTRUCTIONS)
    assert "no markdown" in p.lower() and "bullet" in p.lower()
    assert "here is a summary" in p.lower()  # named as the preamble to avoid
    assert p.endswith("TEXT:\nBODY")


def test_styles_differ():
    assert len({s.style_prompt(x) for x in s.STYLES}) == len(s.STYLES)


def test_key_points_asks_for_spoken_ordinals_not_symbols():
    assert "First" in s.style_prompt("key_points") and "Second" in s.style_prompt("key_points")


def test_unknown_or_missing_style_reads_as_tldr():
    assert s.normalize_style(None) == "tldr"
    assert s.normalize_style("haiku") == "tldr"
    assert s.build_summary_prompt("x", "haiku") == s.build_summary_prompt("x", "tldr")


def test_summarize_sends_the_style_and_a_fixed_context(monkeypatch):
    prompts = _capture_posts(monkeypatch)
    s.summarize("short text", model="m", base_url="http://x", style="action_items")
    assert len(prompts) == 1
    assert s.style_prompt("action_items") in prompts[0]["prompt"]
    # Without num_ctx, Ollama drops the start of a long prompt: the instructions.
    assert prompts[0]["options"]["num_ctx"] == s.OLLAMA_NUM_CTX


def test_long_text_is_summarized_in_parts_then_reduced_in_the_style(monkeypatch):
    prompts = _capture_posts(monkeypatch, answer="digest")
    para = ("A sentence about the topic. " * 40).strip()
    text = "\n\n".join([para] * 30)  # ~34k characters
    s.summarize(text, model="m", base_url="http://x", style="key_points")
    parts = s.split_for_summary(text, s.PART_CHARS)
    assert len(parts) >= 2
    assert len(prompts) == len(parts) + 1
    for i, sent in enumerate(prompts[:-1]):
        assert f"part {i + 1} of {len(parts)}" in sent["prompt"]
    final = prompts[-1]["prompt"]
    assert s.style_prompt("key_points") in final and "digests of consecutive parts" in final


def test_long_plain_english_rewrites_each_part_and_joins_them(monkeypatch):
    calls = []

    def fake_post(url, json, timeout):
        calls.append(json)
        return _Resp(f"rewrite {len(calls)}")

    monkeypatch.setattr(s.httpx, "post", fake_post)
    text = "\n\n".join([("Plain words here. " * 60).strip()] * 12)
    out = s.summarize(text, model="m", base_url="http://x", style="plain_english")
    parts = s.split_for_summary(text, s.PLAIN_PART_CHARS)
    assert len(calls) == len(parts) >= 2
    assert out == "\n\n".join(f"rewrite {i + 1}" for i in range(len(parts)))


def test_split_keeps_parts_under_the_limit_and_loses_nothing():
    text = "\n\n".join(f"Paragraph {i}. " + "word " * 50 for i in range(40))
    parts = s.split_for_summary(text, 1000)
    assert all(len(p) <= 1000 for p in parts)
    assert " ".join(" ".join(parts).split()) == " ".join(text.split())


def test_split_breaks_a_giant_sentence_at_spaces():
    parts = s.split_for_summary("word " * 1000, 300)
    assert all(len(p) <= 300 for p in parts) and len(parts) > 10


def test_the_time_budget_stops_a_long_job(monkeypatch):
    _capture_posts(monkeypatch, answer="digest")
    ticks = iter(range(0, 10_000, 100))  # every call to the clock is 100 s later
    text = "\n\n".join([("A sentence. " * 100).strip()] * 40)
    with pytest.raises(s.SummaryUnavailable) as err:
        s.summarize(text, model="m", base_url="http://x", total_budget=150, clock=lambda: next(ticks))
    assert err.value.reason == "summary_timeout"


def _raise(exc):
    def fake_post(url, json, timeout):
        raise exc

    return fake_post


def test_ollama_down_is_a_named_failure(monkeypatch):
    monkeypatch.setattr(s.httpx, "post", _raise(httpx.ConnectError("refused")))
    monkeypatch.setattr(s, "ollama_installed", lambda: True)
    with pytest.raises(s.SummaryUnavailable) as err:
        s.summarize("t", model="m", base_url="http://x")
    assert err.value.reason == "ollama_not_running"
    monkeypatch.setattr(s, "ollama_installed", lambda: False)
    with pytest.raises(s.SummaryUnavailable) as err:
        s.summarize("t", model="m", base_url="http://x")
    assert err.value.reason == "ollama_not_installed"


def test_missing_model_is_a_named_failure(monkeypatch):
    request = httpx.Request("POST", "http://x/api/generate")
    response = httpx.Response(404, text='{"error":"model \\"m\\" not found"}', request=request)

    class NotFound:
        text = response.text

        def raise_for_status(self):
            raise httpx.HTTPStatusError("404", request=request, response=response)

    monkeypatch.setattr(s.httpx, "post", lambda url, json, timeout: NotFound())
    with pytest.raises(s.SummaryUnavailable) as err:
        s.summarize("t", model="m", base_url="http://x")
    assert err.value.reason == "summary_model_missing"


def test_timeout_is_a_named_failure(monkeypatch):
    monkeypatch.setattr(s.httpx, "post", _raise(httpx.ReadTimeout("slow")))
    with pytest.raises(s.SummaryUnavailable) as err:
        s.summarize("t", model="m", base_url="http://x")
    assert err.value.reason == "summary_timeout"


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("Here is a summary of the text:\nThe point.", "The point."),
        ("Sure, here's a summary: The point.", "The point."),
        ("- First, one.\n- Second, two.", "First, one.\nSecond, two."),
        ("1. First, one.\n2) Second, two.", "First, one.\nSecond, two."),
        ("## Summary\nThe **main** point.", "Summary\nThe main point."),
        ("Here the council voted: yes.", "Here the council voted: yes."),
        ("The year 2024 was long. It ended.", "The year 2024 was long. It ended."),
    ],
)
def test_tidy_drops_what_the_prompt_forbids(raw, expected):
    assert s.tidy(raw) == expected


def test_model_listed_needs_the_exact_tag():
    assert s.model_listed("qwen3.5:4b", ["qwen3.5:4b", "gemma4:12b"])
    assert not s.model_listed("qwen3.5:4b", ["qwen3.5:7b", "qwen2.5:14b"])
    assert s.model_listed("llama3.3", ["llama3.3:latest"])


def test_ollama_status_states(monkeypatch):
    class Tags:
        def raise_for_status(self):
            pass

        def json(self):
            return {"models": [{"name": "gemma4:12b"}]}

    monkeypatch.setattr(s.httpx, "get", lambda url, timeout: Tags())
    assert s.ollama_status(base_url="http://x", model="gemma4:12b")["state"] == "ready"
    assert s.ollama_status(base_url="http://x", model="qwen3.5:4b")["state"] == "model_missing"

    def down(url, timeout):
        raise httpx.ConnectError("refused")

    monkeypatch.setattr(s.httpx, "get", down)
    monkeypatch.setattr(s, "ollama_installed", lambda: True)
    assert s.ollama_status(base_url="http://x", model="m")["state"] == "not_running"
    monkeypatch.setattr(s, "ollama_installed", lambda: False)
    assert s.ollama_status(base_url="http://x", model="m")["state"] == "not_installed"
