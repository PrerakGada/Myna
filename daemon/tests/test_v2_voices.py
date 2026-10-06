"""Tests for GET /v2/voices and the user's own voices (clips, blends, library).

Spec: API_CONTRACT.md § 2 and the fixture at
docs/native-app/fixtures/voices-response.json.

mlx-audio's server has no /v1/voices, so the list comes from the engine
catalog (myna.engines) plus the user's voice store — never the engine.
"""

import io
import json
import wave

import myna.app as app_mod

from .v2_helpers import FIXTURES_DIR, make_client


def _wav(seconds: float, rate: int = 24_000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * int(seconds * rate))
    return buf.getvalue()


def _capture_synth(app):
    calls = []

    def fake(text, **kw):
        calls.append(kw)
        return b"RIFFfake"

    app.state.synthesize = fake
    return calls


# ----- listing -----


def test_v2_voices_shape_matches_fixture():
    fixture = json.loads((FIXTURES_DIR / "voices-response.json").read_text())
    client, fp, app = make_client()
    r = client.get("/v2/voices")
    assert r.status_code == 200
    body = r.json()
    fixture_ids = {v["id"] for v in fixture["voices"]}
    body_ids = {v["id"] for v in body["voices"]}
    assert fixture_ids.issubset(body_ids)
    for v in body["voices"]:
        assert set(v.keys()) >= {"id", "label", "lang", "default"}
    defaults = [v for v in body["voices"] if v["default"]]
    assert len(defaults) == 1
    assert defaults[0]["id"] == "af_heart"


def test_v2_voices_never_asks_the_engine(monkeypatch):
    client, fp, app = make_client()

    def boom(url, timeout=None, **kw):
        raise AssertionError(f"voices should not query the engine: {url}")

    monkeypatch.setattr(app_mod.httpx, "get", boom)
    assert client.get("/v2/voices").status_code == 200


def test_v2_voices_lists_every_kokoro_voice_the_engine_can_speak():
    client, fp, app = make_client()
    voices = client.get("/v2/voices").json()["voices"]
    ids = [v["id"] for v in voices]
    assert len(ids) == 41
    assert {"bf_emma", "bm_george", "ef_dora", "ff_siwis", "hf_alpha", "im_nicola", "pm_alex"} <= set(ids)
    # Japanese and Mandarin need G2P packages the engine venv lacks.
    assert not [i for i in ids if i[0] in "jz"]
    emma = next(v for v in voices if v["id"] == "bf_emma")
    assert emma == {
        "id": "bf_emma", "label": "Emma", "lang": "en", "default": False, "kind": "builtin",
        "group": "British English", "gender": "female", "grade": "B-",
    }
    dora = next(v for v in voices if v["id"] == "ef_dora")
    assert (dora["lang"], dora["group"]) == ("es", "Spanish")
    assert "grade" not in dora  # the model card gives none


def test_v2_voices_says_what_the_engine_can_do():
    client, fp, app = make_client()
    assert client.get("/v2/voices").json()["active_engine"] == {
        "id": "kokoro", "name": "Kokoro", "can_clone": False, "can_blend": True,
    }
    client, fp, app = make_client(config_overrides={"engine": "soprano"})
    about = client.get("/v2/voices").json()["active_engine"]
    assert about["can_clone"] is False and about["can_blend"] is False
    assert "single-speaker" in about["note"]
    client, fp, app = make_client(config_overrides={"engine": "chatterbox"})
    assert client.get("/v2/voices").json()["active_engine"]["can_clone"] is True


def test_v2_voices_engine_down_returns_empty():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0
    r = client.get("/v2/voices")
    assert r.status_code == 200
    body = r.json()
    assert body["voices"] == []
    assert body.get("engine") == "down"


def test_v2_voices_includes_default_voice_marker():
    client, fp, app = make_client(config_overrides={"voice": "am_michael"})
    r = client.get("/v2/voices").json()
    defaults = [v for v in r["voices"] if v["default"]]
    assert [d["id"] for d in defaults] == ["am_michael"]


# ----- Kokoro language follows the voice -----


def test_kokoro_sends_each_voices_own_language():
    client, fp, app = make_client()
    calls = _capture_synth(app)
    for voice in ("af_heart", "bf_emma", "ef_dora", "hm_psi"):
        client.post("/v2/synthesize", json={"text": "Hello there.", "voice": voice, "speed": 1.0})
    assert [c["lang_code"] for c in calls] == ["a", "b", "e", "h"]


# ----- blends -----


def test_blend_is_sent_as_kokoros_weighted_voice_list():
    client, fp, app = make_client()
    r = client.post("/v2/voices/blends", json={
        "name": "Warm George", "mix": [{"voice": "bm_george", "weight": 3}, {"voice": "af_heart", "weight": 1}],
    })
    assert r.status_code == 201
    blend = r.json()
    assert blend["id"].startswith("blend-")
    assert (blend["label"], blend["kind"], blend["group"]) == ("Warm George", "blend", "Your blends")
    assert blend["detail"] == "Blend of George ×3 + Heart ×1"

    ids = [v["id"] for v in client.get("/v2/voices").json()["voices"]]
    assert ids[-1] == blend["id"]

    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": blend["id"], "speed": 1.0})
    assert calls[0]["voice"] == "bm_george,bm_george,bm_george,af_heart"
    assert calls[0]["lang_code"] == "b"  # the first voice's language


def test_equal_blend_reduces_weights():
    client, fp, app = make_client()
    blend = client.post("/v2/voices/blends", json={
        "mix": [{"voice": "af_bella", "weight": 2}, {"voice": "af_nicole", "weight": 2}],
    }).json()
    assert blend["label"] == "Bella × Nicole"
    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hi.", "voice": blend["id"], "speed": 1.0})
    assert calls[0]["voice"] == "af_bella,af_nicole"


def test_bad_blends_are_refused():
    client, fp, app = make_client()
    for mix in (
        [{"voice": "af_heart"}],
        [{"voice": "af_heart"}, {"voice": "alba"}],
        [{"voice": "af_heart"}, {"voice": "af_heart"}],
        [{"voice": "af_heart", "weight": 9}, {"voice": "af_bella"}],
        [{"voice": "af_heart"}, {"voice": "af_bella"}, {"voice": "af_sky"}, {"voice": "af_nova"}],
    ):
        r = client.post("/v2/voices/blends", json={"mix": mix})
        assert r.status_code == 400, mix
        assert r.json()["detail"]["reason"] == "bad_blend"


def test_blends_are_not_offered_to_other_engines():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    app.state.voice_store.add_blend("Mix", [{"voice": "af_heart", "weight": 1}, {"voice": "af_bella", "weight": 1}])
    kinds = {v.get("kind") for v in client.get("/v2/voices").json()["voices"]}
    assert "blend" not in kinds


# ----- clips -----


def test_clip_voice_on_pocket_is_sent_as_its_file():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    r = client.post("/v2/voices/clips?name=Grandad", content=_wav(8), headers={"content-type": "audio/wav"})
    assert r.status_code == 201, r.text
    clip = r.json()
    assert (clip["label"], clip["kind"], clip["group"]) == ("Grandad", "clip", "Your voices")
    assert clip["detail"] == "From a 8 s clip"

    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": clip["id"], "speed": 1.0})
    path = app.state.voice_store.clip_path(clip["id"])
    assert calls[0]["voice"] == str(path)
    assert path.read_bytes() == _wav(8)
    assert "ref_audio" not in calls[0].get("extra", {})


def test_clip_voice_on_chatterbox_is_sent_as_ref_audio():
    client, fp, app = make_client(config_overrides={"engine": "chatterbox"})
    clip = client.post("/v2/voices/clips", content=_wav(10)).json()
    assert clip["label"] == "My voice"
    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": clip["id"], "speed": 1.0})
    assert calls[0]["voice"] == "chatterbox"
    assert calls[0]["extra"]["ref_audio"] == str(app.state.voice_store.clip_path(clip["id"]))
    # The engine's own sampling settings still go with it.
    assert calls[0]["extra"]["repetition_penalty"] == 1.2


def test_built_in_chatterbox_voice_sends_no_clip():
    client, fp, app = make_client(config_overrides={"engine": "chatterbox"})
    client.post("/v2/voices/clips", content=_wav(10))
    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": "chatterbox", "speed": 1.0})
    assert "ref_audio" not in calls[0]["extra"]


def test_clips_are_not_offered_to_kokoro_and_fall_back_there():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    clip = client.post("/v2/voices/clips", content=_wav(10)).json()
    app.state.cfg["engine"] = "kokoro"
    ids = [v["id"] for v in client.get("/v2/voices").json()["voices"]]
    assert clip["id"] not in ids
    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": clip["id"], "speed": 1.0})
    assert calls[0]["voice"] == "af_heart"


def test_clip_length_limits():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    short = client.post("/v2/voices/clips", content=_wav(3))
    assert short.status_code == 400 and short.json()["detail"]["reason"] == "too_short"
    long = client.post("/v2/voices/clips", content=_wav(45, rate=8_000))
    assert long.status_code == 400 and long.json()["detail"]["reason"] == "too_long"
    junk = client.post("/v2/voices/clips", content=b"not a wav at all")
    assert junk.status_code == 400 and junk.json()["detail"]["reason"] == "bad_audio"


def test_rename_and_delete_a_voice():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    clip = client.post("/v2/voices/clips", content=_wav(8)).json()
    r = client.patch(f"/v2/voices/custom/{clip['id']}", json={"name": "  Narrator   two "})
    assert r.json()["label"] == "Narrator two"
    assert client.delete(f"/v2/voices/custom/{clip['id']}").json() == {"ok": True}
    assert not app.state.voice_store.clip_path(clip["id"]).exists()
    assert client.delete(f"/v2/voices/custom/{clip['id']}").status_code == 404
    # A read that still asks for the deleted voice falls back, never fails.
    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": clip["id"], "speed": 1.0})
    assert calls[0]["voice"] == "alba"


def test_user_voice_is_remembered_per_engine():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    clip = client.post("/v2/voices/clips", content=_wav(8)).json()
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": clip["id"], "speed": 1.0})
    assert app.state.cfg["engine_voices"]["pocket"] == clip["id"]
    defaults = [v["id"] for v in client.get("/v2/voices").json()["voices"] if v["default"]]
    assert defaults == [clip["id"]]


# ----- library -----


def test_library_lists_labelled_commercially_usable_clips():
    client, fp, app = make_client()
    body = client.get("/v2/voices/library").json()
    voices = body["voices"]
    assert len(voices) >= 100
    assert {v["license"] for v in voices} <= {"CC BY 4.0", "CC0"}
    p262 = next(v for v in voices if v["id"] == "vctk-p262")
    assert (p262["name"], p262["group"], p262["gender"], p262["age"]) == ("Edinburgh", "Scottish", "female", 23)
    assert "added_as" not in p262


def test_library_add_downloads_once_and_marks_it_added():
    client, fp, app = make_client(config_overrides={"engine": "chatterbox"})
    fetched = []

    def fetch(url):
        fetched.append(url)
        return _wav(10)

    app.state.voice_library._fetch = fetch
    sample = client.get("/v2/voices/library/vctk-p262/sample")
    assert sample.status_code == 200 and sample.headers["content-type"] == "audio/wav"
    added = client.post("/v2/voices/library/vctk-p262").json()
    again = client.post("/v2/voices/library/vctk-p262").json()
    assert added["id"] == again["id"]
    assert (added["label"], added["kind"], added["gender"]) == ("Edinburgh", "clip", "female")
    assert "VCTK" in added["credit"]
    assert len(fetched) == 1 and "/resolve/" in fetched[0]
    entry = next(v for v in client.get("/v2/voices/library").json()["voices"] if v["id"] == "vctk-p262")
    assert entry["added_as"] == added["id"]


def test_library_download_failure_is_a_502_not_a_voice():
    client, fp, app = make_client(config_overrides={"engine": "pocket"})
    r = client.post("/v2/voices/library/vctk-p262")
    assert r.status_code == 502 and r.json()["detail"]["reason"] == "download_failed"
    assert app.state.voice_store.list() == []
    assert client.post("/v2/voices/library/nope").status_code == 404
