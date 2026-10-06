"""Pronunciations: the matcher, the store, /v2/pronunciations, and the list
applying on every path that speaks (after cleanup, once)."""

import json

import pytest

from myna import pronunciations as pron
from myna.pronunciation_lexicon import STARTER
from myna.pronunciations import Matcher, PronunciationError, PronunciationStore, normalize, starter_id
from myna.render_jobs import RenderJobs

from .render_helpers import render_client
from .test_render_jobs import done
from .v2_helpers import make_client


# ----- the matcher


def m(*pairs):
    return Matcher(pairs)


def test_whole_words_only():
    sql = m(("SQL", "sequel"))
    assert sql("SQL and SQLite and MySQL and NoSQL") == "sequel and SQLite and MySQL and NoSQL"
    assert m(("sed", "sedd"))("sed, used, sedate") == "sedd, used, sedate"


def test_case_insensitive():
    assert m(("JSON", "jay son"))("json, JSON, Json") == "jay son, jay son, jay son"


def test_longest_match_first():
    both = m(("Postgres", "post gress"), ("PostgreSQL", "post gress Q L"))
    assert both("PostgreSQL beats Postgres") == "post gress Q L beats post gress"


@pytest.mark.parametrize(
    "text, spoken",
    [
        ("kubectl, then", "cube control, then"),
        ("(kubectl)", "(cube control)"),
        ("“kubectl”", "“cube control”"),
        ("kubectl's output", "cube control's output"),
        ("end with kubectl.", "end with cube control."),
        ("kubectl-plugin", "cube control-plugin"),
        ("see config/kubectl.yaml", "see config/cube control.yaml"),
    ],
)
def test_punctuation_next_to_words(text, spoken):
    assert m(("kubectl", "cube control"))(text) == spoken


def test_not_inside_words_or_identifiers():
    k = m(("kubectl", "cube control"))
    assert k("kubectl_wrapper and mykubectl and kubectl2") == "kubectl_wrapper and mykubectl and kubectl2"


def test_phrases_match_across_any_whitespace():
    hf = m(("Hugging Face", "hugging face hub"))
    assert hf("from Hugging  Face and hugging\nface") == "from hugging face hub and hugging face hub"


def test_symbols_and_digits():
    table = m(("C++", "see plus plus"), (".NET", "dot net"), ("2FA", "two F A"), ("a11y", "eh eleven wye"))
    assert table("C++ and .NET with 2FA for a11y") == "see plus plus and dot net with two F A for eh eleven wye"
    assert table("C+++ and 2FAs") == "C+++ and 2FAs"


def test_one_pass_never_reapplies():
    chain = m(("foo", "bar"), ("bar", "baz"))
    assert chain("foo bar") == "bar baz"
    mynah = m(("Myna", "Mynah"))
    once = mynah("Myna reads.")
    assert once == "Mynah reads." and mynah(once) == once


def test_first_pair_wins_for_the_same_word():
    assert m(("json", "mine"), ("JSON", "starter"))("JSON") == "mine"


def test_empty_matcher_is_identity():
    assert m()("anything at all") == "anything at all"
    assert len(m()) == 0


# ----- the starter list


def test_starter_list_is_well_formed():
    keys = [normalize(e["word"]) for e in STARTER]
    assert len(keys) == len(set(keys)), "duplicate starter words"
    ids = [starter_id(e["word"]) for e in STARTER]
    assert len(ids) == len(set(ids))
    for entry in STARTER:
        assert entry["say"].strip() and entry["heard"].strip()
        assert entry["say"] != entry["word"]
    # A respelling never contains another starter word, so the order the
    # list applies in can't matter.
    matcher = Matcher((e["word"], e["say"]) for e in STARTER)
    for entry in STARTER:
        assert matcher(entry["say"]) == entry["say"], entry


def test_starter_leaves_ordinary_english_alone():
    matcher = Matcher((e["word"], e["say"]) for e in STARTER)
    text = "Latex gloves, a curly pass, the sedan, enumerate the todos, redistribute the mynas, deny it."
    assert matcher(text) == text


# ----- the store


def test_store_add_edit_delete_and_persist(tmp_path):
    path = tmp_path / "pronunciations.json"
    store = PronunciationStore(path, starter=())
    entry = store.add("Anthropic", "an throw pick")
    assert entry["id"].startswith("p_") and entry["enabled"] is True
    assert json.loads(path.read_text())["entries"][0]["word"] == "Anthropic"

    # Same word (any case) replaces the say instead of adding a second.
    again = store.add("anthropic", "an thropic")
    assert again["id"] == entry["id"] and again["say"] == "an thropic"
    assert len(store.snapshot()["entries"]) == 1

    store.update(entry["id"], enabled=False)
    assert store.stage()("Anthropic") == "Anthropic"
    store.update(entry["id"], enabled=True, say="an throppic")
    assert store.stage()("Anthropic") == "an throppic"

    reloaded = PronunciationStore(path, starter=())
    assert reloaded.snapshot()["entries"] == store.snapshot()["entries"]

    assert store.delete(entry["id"]) is True
    assert store.delete(entry["id"]) is False
    assert PronunciationStore(path, starter=()).snapshot()["entries"] == []


def test_store_validation():
    store = PronunciationStore(None, starter=())
    for word, say, reason in [
        ("", "x", "invalid_word"),
        ("   ", "x", "invalid_word"),
        ("!!!", "x", "invalid_word"),
        ("x" * 81, "x", "invalid_word"),
        ("word", "", "invalid_say"),
        ("word", "y" * 201, "invalid_say"),
    ]:
        with pytest.raises(PronunciationError) as err:
            store.add(word, say)
        assert err.value.reason == reason
    a = store.add("alpha", "al fa")
    store.add("beta", "bay ta")
    with pytest.raises(PronunciationError) as err:
        store.update(a["id"], word="BETA")
    assert err.value.reason == "duplicate_word"
    with pytest.raises(KeyError):
        store.update("p_00000000", say="x")


def test_store_starter_switches(tmp_path):
    path = tmp_path / "pronunciations.json"
    store = PronunciationStore(path)
    assert store.stage()("kubectl and JSON") == "cube control and jay son"

    store.set_starter_entry("kubectl", False)
    assert store.stage()("kubectl and JSON") == "kubectl and jay son"
    snap = store.snapshot()
    assert next(s for s in snap["starter"] if s["id"] == "kubectl")["enabled"] is False

    store.set_starter_enabled(False)
    assert store.stage()("kubectl and JSON") == "kubectl and JSON"
    with pytest.raises(KeyError):
        store.set_starter_entry("no-such-word", True)

    reloaded = PronunciationStore(path)
    assert reloaded.snapshot()["starter_enabled"] is False
    reloaded.set_starter_enabled(True)
    assert reloaded.stage()("kubectl and JSON") == "kubectl and jay son"


def test_user_entry_overrides_starter():
    store = PronunciationStore(None)
    store.add("JSON", "jason")
    assert store.stage()("JSON") == "jason"
    starter = {s["id"]: s for s in store.snapshot()["starter"]}
    assert starter["json"]["overridden"] is True
    assert starter["kubectl"]["overridden"] is False


def test_damaged_file_is_a_soft_failure(tmp_path):
    path = tmp_path / "pronunciations.json"
    path.write_text("{not json")
    store = PronunciationStore(path, starter=())
    assert store.snapshot()["entries"] == []
    path.write_text(json.dumps({"version": 1, "entries": [{"id": "bad", "word": "ok", "say": "fine"}, {"word": ""}]}))
    entries = PronunciationStore(path, starter=()).snapshot()["entries"]
    assert [e["word"] for e in entries] == ["ok"] and entries[0]["id"].startswith("p_")


def test_in_memory_store_writes_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(pron, "default_path", lambda: tmp_path / "pronunciations.json")
    store = PronunciationStore(None)
    store.add("word", "werd")
    assert not (tmp_path / "pronunciations.json").exists()


def test_only_the_service_uses_the_users_file(tmp_path, monkeypatch):
    from myna.app import create_app
    from myna.config import DEFAULTS

    monkeypatch.setattr(pron, "default_path", lambda: tmp_path / "pronunciations.json")
    cfg = dict(DEFAULTS)
    # A test or dev instance: in memory.
    app = create_app(cfg)
    app.state.pronunciation_store().add("word", "werd")
    assert not (tmp_path / "pronunciations.json").exists()
    # The service (`python -m myna` sets service_port): the user's file.
    app = create_app(cfg, persist_config=True)
    app.state.service_port = cfg["daemon_port"]
    app.state.pronunciation_store().add("word", "werd")
    assert (tmp_path / "pronunciations.json").exists()


# ----- /v2/pronunciations


def client_with_starter():
    client, player, app = make_client()
    app.state.pronunciations = PronunciationStore(None)
    return client, player, app


def test_endpoints_crud():
    client, _, _ = client_with_starter()
    body = client.get("/v2/pronunciations").json()
    assert body["starter_enabled"] is True and body["entries"] == []
    assert {"id": "kubectl", "word": "kubectl", "say": "cube control"}.items() <= next(
        s for s in body["starter"] if s["id"] == "kubectl"
    ).items()

    body = client.post("/v2/pronunciations", json={"word": "Anthropic", "say": "an throw pick"}).json()
    entry = body["entries"][0]
    assert entry["word"] == "Anthropic" and entry["enabled"] is True

    body = client.patch(f"/v2/pronunciations/{entry['id']}", json={"enabled": False}).json()
    assert body["entries"][0]["enabled"] is False
    body = client.patch(f"/v2/pronunciations/{entry['id']}", json={"say": "an thropic", "enabled": True}).json()
    assert body["entries"][0]["say"] == "an thropic"

    assert client.delete(f"/v2/pronunciations/{entry['id']}").json()["entries"] == []
    assert client.delete(f"/v2/pronunciations/{entry['id']}").status_code == 404


def test_endpoint_errors():
    client, _, _ = client_with_starter()
    r = client.post("/v2/pronunciations", json={"word": "  ", "say": "x"})
    assert r.status_code == 400 and r.json()["reason"] == "invalid_word"
    assert client.post("/v2/pronunciations", json={"word": "x"}).status_code == 422
    assert client.patch("/v2/pronunciations/p_00000000", json={"say": "x"}).status_code == 404
    a = client.post("/v2/pronunciations", json={"word": "alpha", "say": "al fa"}).json()["entries"][0]
    client.post("/v2/pronunciations", json={"word": "beta", "say": "bay ta"})
    r = client.patch(f"/v2/pronunciations/{a['id']}", json={"word": "Beta"})
    assert r.status_code == 409 and r.json()["reason"] == "duplicate_word"
    assert client.patch("/v2/pronunciations/starter/nope", json={"enabled": False}).status_code == 404


def test_starter_switch_endpoints_change_what_is_heard():
    client, _, _ = client_with_starter()
    heard = lambda: client.post("/v2/speakable", json={"text": "Run kubectl on JSON."}).json()["text"]  # noqa: E731
    assert heard() == "Run cube control on jay son."
    body = client.patch("/v2/pronunciations/starter/kubectl", json={"enabled": False}).json()
    assert next(s for s in body["starter"] if s["id"] == "kubectl")["enabled"] is False
    assert heard() == "Run kubectl on jay son."
    assert client.patch("/v2/pronunciations/starter", json={"enabled": False}).json()["starter_enabled"] is False
    assert heard() == "Run kubectl on JSON."


# ----- applies everywhere, after cleanup, once


CC = "Fixed `kubectl` output in **JSON**. See [the docs](https://example.com/async)."


def test_speakable_applies_after_cleanup_and_under_literal():
    client, _, _ = client_with_starter()
    body = client.post("/v2/speakable", json={"text": CC, "source": "claude_code"}).json()
    assert body["text"] == "Fixed cube control output in jay son. See the docs."
    assert body["changed"] is True
    literal = client.post("/v2/speakable", json={"text": CC, "prep": "literal"}).json()
    assert literal["text"] == "Fixed `cube control` output in **jay son**. See [the docs](https://example.com/eh sink)."
    # Running it again changes nothing: respellings aren't matched twice.
    again = client.post("/v2/speakable", json={"text": body["text"], "source": "claude_code"}).json()
    assert again["text"] == body["text"]


class RecordingSynth:
    def __init__(self):
        self.texts = []

    def __call__(self, text, **kw):
        self.texts.append(text)
        return b"RIFFfake"


def test_reads_and_summaries_use_the_list():
    synth = RecordingSynth()
    client, player, app = make_client(synthesize=synth, summarize=lambda text, **kw: "Uses async and YAML.")
    app.state.pronunciations = PronunciationStore(None)
    assert client.post("/v2/synthesize", json={"text": "Myna reads kubectl."}).status_code == 200
    assert synth.texts == ["Mynah reads cube control."]
    synth.texts.clear()
    client.post("/v2/synthesize-summary", json={"text": "long"})
    assert synth.texts == ["Uses eh sink and yammel."]
    client.post("/speak", json={"text": "stdout and stderr"})
    assert player.calls[-1][2]["meta"]["preview"] == "standard out and standard error"


def test_renders_use_the_list(tmp_path):
    client, app, engine = render_client(tmp_path)
    app.state.pronunciations = PronunciationStore(None)
    r = client.post("/v1/audio/speech", json={"input": "Install pytest.", "response_format": "wav"})
    assert r.status_code == 200
    assert [c["text"] for c in engine.calls] == ["Install pie test."]

    engine.calls.clear()
    app.state.render_jobs = RenderJobs(app, tmp_path / "renders", retries=(), yield_poll_s=0.01)
    r = client.post("/v2/renders", json={"text": "Read the README.", "format": "wav"})
    done(client, r.json()["id"])
    assert [c["text"] for c in engine.calls] == ["Read the read me."]
