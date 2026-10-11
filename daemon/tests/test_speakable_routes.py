"""Text prep on every way in: /v2/speakable, reads (/v2/synthesize, the
summary path, v1 /speak and the registry), and renders (/v1/audio/speech,
/v2/renders). The rules themselves are tested in test_speakable.py; these
check that each path runs them, with the right preset, before chunking."""

import json
import urllib.parse

import pytest

from myna import encode
from myna.render_jobs import RenderJobs
from myna.speakable import CODE_BLOCK_MARKER

from .render_helpers import FakeEngine, render_client
from .test_render_jobs import done
from .v2_helpers import make_client, parse_multipart

CC_REPLY = (
    "## Done\n\n"
    "Fixed `/Users/x/proj/daemon/myna/app.py:454`.\n\n"
    "```python\nprint('hi')\n```\n\n"
    "- **Tests** pass"
)
CC_SPOKEN = "Done.\n\nFixed app.py line 454.\n\nTests pass"


@pytest.fixture(autouse=True)
def _fresh_probe():
    encode.reset_probe()
    yield
    encode.reset_probe()


class RecordingSynth:
    def __init__(self):
        self.texts: list[str] = []

    def __call__(self, text, **kw):
        self.texts.append(text)
        return b"RIFFfake"


def synth_client(**kw):
    synth = RecordingSynth()
    client, player, app = make_client(synthesize=synth, **kw)
    return client, player, app, synth


def spoken(synth) -> str:
    return " ".join(synth.texts)


# ----- POST /v2/speakable


def test_speakable_claude_code():
    client, _, _ = make_client()
    r = client.post("/v2/speakable", json={"text": CC_REPLY, "source": "claude_code"})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "text": CC_SPOKEN, "changed": True, "preset": "claude_code"}


def test_speakable_defaults_to_the_base_pass():
    client, _, _ = make_client()
    body = client.post("/v2/speakable", json={"text": CC_REPLY}).json()
    assert body["preset"] == "base"
    assert CODE_BLOCK_MARKER in body["text"]
    assert "/Users/x/proj/daemon/myna/app.py:454" in body["text"]


def test_speakable_literal_and_unchanged():
    client, _, _ = make_client()
    body = client.post("/v2/speakable", json={"text": CC_REPLY, "source": "claude_code", "prep": "literal"}).json()
    assert body == {"ok": True, "text": CC_REPLY, "changed": False, "preset": "literal"}
    plain = client.post("/v2/speakable", json={"text": "C++ costs $4.99, e.g. 3 * 4."}).json()
    assert plain["changed"] is False
    assert plain["text"] == "C++ costs $4.99, e.g. 3 * 4."


def test_speakable_source_kind_selects_the_article_preset():
    client, _, _ = make_client()
    text = "Mynas mimic.\nAdvertisement\nThey learn fast."
    body = client.post("/v2/speakable", json={"text": text, "source": "studio", "source_kind": "pdf"}).json()
    assert body["preset"] == "article"
    assert body["text"] == "Mynas mimic.\nThey learn fast."


def test_speakable_errors():
    client, _, _ = make_client()
    assert client.post("/v2/speakable", json={"text": "   "}).status_code == 400
    assert client.post("/v2/speakable", json={"text": "x", "prep": "sideways"}).status_code == 422
    assert client.post("/v2/speakable", json={}).status_code == 422


def test_speakable_is_deterministic_for_history():
    client, _, _ = make_client()
    a = client.post("/v2/speakable", json={"text": CC_REPLY, "source": "claude_code"}).json()
    b = client.post("/v2/speakable", json={"text": CC_REPLY, "source": "claude_code"}).json()
    assert a == b


# ----- /v2/synthesize


def test_synthesize_cleans_per_source_before_chunking():
    client, _, _, synth = synth_client(config_overrides={"chunk_chars": 30})
    r = client.post("/v2/synthesize", json={"text": CC_REPLY, "source": "claude_code"})
    assert r.status_code == 200
    assert r.headers["X-Myna-Speakable"] == "claude_code"
    assert spoken(synth) == "Done. Fixed app.py line 454. Tests pass"
    # Chunks end on the sentence breaks cleanup added, not mid-heading.
    assert synth.texts[0] == "Done."
    parts = [p for p in parse_multipart(r.content) if p["headers"].get("Content-Type") == "audio/wav"]
    previews = [urllib.parse.unquote(p["headers"]["X-Chunk-Text"]) for p in parts]
    assert "`" not in "".join(previews) and "#" not in "".join(previews)


def test_synthesize_without_source_gets_the_base_pass():
    client, _, _, synth = synth_client()
    r = client.post("/v2/synthesize", json={"text": "Read **this** [1] https://github.com/a/b."})
    assert r.status_code == 200
    assert r.headers["X-Myna-Speakable"] == "base"
    assert spoken(synth) == "Read this [1] github.com."


def test_synthesize_literal_reads_as_written():
    client, _, _, synth = synth_client()
    r = client.post("/v2/synthesize", json={"text": "Read **this**.", "source": "claude_code", "prep": "literal"})
    assert r.status_code == 200
    assert r.headers["X-Myna-Speakable"] == "literal"
    assert spoken(synth) == "Read **this**."


def test_synthesize_rejects_unknown_prep():
    client, _, _, _ = synth_client()
    assert client.post("/v2/synthesize", json={"text": "hi", "prep": "loud"}).status_code == 422


def test_synthesize_text_that_cleans_to_nothing_is_empty():
    client, _, _, synth = synth_client()
    r = client.post("/v2/synthesize", json={"text": "---\n\n***"})
    assert r.status_code == 400
    assert r.json()["detail"]["reason"] == "empty"
    assert synth.texts == []


def test_synthesize_url_reads_get_the_article_preset():
    client, _, _, synth = synth_client(extract=lambda url: "Mynas mimic.\nAdvertisement\nThey learn fast.[1][2]")
    r = client.post("/v2/synthesize", json={"url": "https://example.com/a", "source": "article"})
    assert r.status_code == 200
    assert r.headers["X-Myna-Speakable"] == "article"
    assert spoken(synth) == "Mynas mimic. They learn fast."


def test_summary_output_is_cleaned():
    client, _, _, synth = synth_client(summarize=lambda text, **kw: "**Short:** it works. See `app.py`.")
    r = client.post("/v2/synthesize-summary", json={"text": "long text", "source": "claude_code"})
    assert r.status_code == 200
    assert spoken(synth) == "Short: it works. See app.py."


# ----- v1 /speak and the registries


def _played_preview(player) -> str:
    name, args, kwargs = player.calls[-1]
    assert name == "play"
    return kwargs["meta"]["preview"]


def test_v1_speak_cleans_and_honours_literal():
    client, player, _ = make_client()
    assert client.post("/speak", json={"text": "## Hello **world**"}).json()["ok"] is True
    assert _played_preview(player) == "Hello world"
    client.post("/speak", json={"text": "## Hello **world**", "prep": "literal"})
    assert _played_preview(player) == "## Hello **world**"


def test_v1_announce_items_play_as_claude_code():
    client, player, _ = make_client()
    item = client.post("/announce", json={"session_id": "s", "label": "myna", "text": CC_REPLY}).json()
    client.post(f"/play/{item['id']}")
    assert _played_preview(player) == CC_SPOKEN[:60]


def test_v2_registry_play_uses_the_claude_code_preset(tmp_path):
    client, player, _ = make_client(registry_path=tmp_path / "registry.json")
    client.post(
        "/v2/registry/announce",
        json={"id": "u1", "project_id": "myna", "title": "Done", "text": CC_REPLY},
    )
    assert client.post("/v2/registry/play/u1").json()["ok"] is True
    assert _played_preview(player) == CC_SPOKEN[:60]


# ----- /v1/audio/speech


def test_speech_auto_is_the_default_and_literal_bypasses(tmp_path):
    client, app, engine = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": CC_REPLY, "response_format": "wav"})
    assert r.status_code == 200
    auto = [c["text"] for c in engine.calls]
    assert auto == ["Done.", "Fixed /Users/x/proj/daemon/myna/app.py:454.", CODE_BLOCK_MARKER, "Tests pass"]
    engine.calls.clear()
    r = client.post("/v1/audio/speech", json={"input": CC_REPLY, "response_format": "wav", "myna_prep": "literal"})
    assert r.status_code == 200
    literal = " ".join(c["text"] for c in engine.calls)
    assert "```" in literal and "**Tests**" in literal
    assert len(literal) > len(" ".join(auto))


def test_speech_still_ignores_unknown_fields(tmp_path):
    client, _, engine = render_client(tmp_path)
    r = client.post(
        "/v1/audio/speech",
        json={"input": "Hello.", "response_format": "wav", "some_future_openai_field": {"x": 1}},
    )
    assert r.status_code == 200


def test_speech_bad_prep_is_an_openai_error(tmp_path):
    client, _, _ = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "response_format": "wav", "myna_prep": "loud"})
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "invalid_request" and err["param"] == "myna_prep"


def test_speech_input_that_cleans_to_nothing(tmp_path):
    client, _, engine = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": "---", "response_format": "wav"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "empty_input"
    assert engine.calls == []


# ----- /v2/renders


def job_client(tmp_path):
    client, app, engine = render_client(tmp_path)
    app.state.render_jobs = RenderJobs(app, tmp_path / "renders", retries=(), yield_poll_s=0.01)
    return client, app, engine


def test_render_job_cleans_by_source(tmp_path):
    client, app, engine = job_client(tmp_path)
    r = client.post("/v2/renders", json={"text": CC_REPLY, "source": "claude_code", "format": "wav"})
    assert r.status_code == 201, r.text
    job = done(client, r.json()["id"])
    assert " ".join(c["text"] for c in engine.calls) == "Done. Fixed app.py line 454. Tests pass"
    assert job["preview"] == "Done. Fixed app.py line 454. Tests pass"
    # The title still comes from the text as written, minus the heading mark.
    assert job["title"] == "Done"


def test_render_job_literal(tmp_path):
    client, app, engine = job_client(tmp_path)
    r = client.post("/v2/renders", json={"text": "Read **this**.", "prep": "literal", "format": "wav"})
    done(client, r.json()["id"])
    assert [c["text"] for c in engine.calls] == ["Read **this**."]


def test_render_job_studio_pdf_is_an_article(tmp_path):
    client, app, engine = job_client(tmp_path)
    sections = [
        {"title": "One", "text": "Mynas mimic.\nAdvertisement\nFigure 2: A myna."},
        {"title": "Two", "text": "They learn fast.[1][2]"},
    ]
    r = client.post(
        "/v2/renders",
        json={"sections": sections, "source": "studio", "source_kind": "pdf", "format": "wav"},
    )
    job = done(client, r.json()["id"])
    assert [c["text"] for c in engine.calls] == ["Mynas mimic.", "They learn fast."]
    assert [c["title"] for c in job["chapters"]] == ["One", "Two"]


def test_render_job_that_cleans_to_nothing(tmp_path):
    client, _, _ = job_client(tmp_path)
    r = client.post("/v2/renders", json={"text": "---", "format": "wav"})
    assert r.status_code == 400
    assert r.json()["reason"] == "empty"


def test_render_job_rejects_unknown_prep(tmp_path):
    client, _, _ = job_client(tmp_path)
    assert client.post("/v2/renders", json={"text": "Hi.", "prep": "loud"}).status_code == 422


def test_synthesize_request_fixture_still_parses():
    from .v2_helpers import FIXTURES_DIR
    from myna.v2_types import V2SynthesizeReq

    req = V2SynthesizeReq(**json.loads((FIXTURES_DIR / "synthesize-request.json").read_text()))
    assert req.source == "selection"
    assert req.prep == "auto"
