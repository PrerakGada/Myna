"""POST /v1/audio/speech, GET /v1/models, GET /v1/audio/voices.

A render is not a read: none of these may touch the state machine, the
player, karaoke or the remembered voice.
"""

import httpx
import pytest

from myna import encode
from .render_helpers import FRAMES_PER_CHAR, RATE, FakeEngine, render_client, wav_frames


@pytest.fixture(autouse=True)
def _fresh_probe():
    encode.reset_probe()
    yield
    encode.reset_probe()


def test_speech_wav_returns_audio_and_headers(tmp_path):
    client, app, engine = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": "Hello there.", "response_format": "wav"})
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "audio/wav"
    frames, rate = wav_frames(r.content)
    assert rate == RATE
    assert frames == len("Hello there.") * FRAMES_PER_CHAR
    assert r.headers["X-Myna-Engine"] == "kokoro"
    assert r.headers["X-Myna-Voice"] == "af_heart"
    assert r.headers["X-Myna-Sample-Rate"] == "24000"
    assert r.headers["X-Myna-Chunks"] == "1"
    assert float(r.headers["X-Myna-Duration-S"]) == pytest.approx(frames / RATE, abs=0.01)
    assert int(r.headers["X-Myna-Render-Ms"]) >= 0


def test_speech_is_not_a_read(tmp_path):
    client, app, engine = render_client(tmp_path)
    before = dict(app.state.cfg.get("engine_voices") or {})
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "voice": "am_adam", "response_format": "wav"})
    assert r.status_code == 200
    assert app.state.machine.state == "idle"
    assert app.state.player.calls == []
    # remember=False: the remembered voice is untouched.
    assert (app.state.cfg.get("engine_voices") or {}) == before
    assert engine.calls[0]["voice"] == "am_adam"


def test_speech_multi_paragraph_joins_chunks(tmp_path):
    client, app, engine = render_client(tmp_path)
    text = "First paragraph here.\n\nSecond paragraph.\n\nThird one."
    r = client.post("/v1/audio/speech", json={"input": text, "response_format": "wav"})
    assert r.status_code == 200
    assert r.headers["X-Myna-Chunks"] == "3"
    assert [c["text"] for c in engine.calls] == ["First paragraph here.", "Second paragraph.", "Third one."]
    frames, _ = wav_frames(r.content)
    assert frames == sum(len(c["text"]) for c in engine.calls) * FRAMES_PER_CHAR


def test_speech_pcm_is_raw_frames(tmp_path):
    client, _, _ = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": "Hey.", "response_format": "pcm"})
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("audio/L16")
    assert r.headers["X-Myna-Sample-Rate"] == "24000"
    assert len(r.content) == len("Hey.") * FRAMES_PER_CHAR * 2
    assert not r.content.startswith(b"RIFF")


def test_speech_default_format_is_mp3_and_unavailable_says_so(tmp_path, monkeypatch):
    monkeypatch.setattr(encode.shutil, "which", lambda name, path=None: None)
    client, _, _ = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": "Hi."})
    assert r.status_code == 400
    err = r.json()["error"]
    assert err["code"] == "format_unavailable"
    assert err["param"] == "response_format"
    assert "ffmpeg or lame" in err["message"]


def test_speech_openai_voice_names_map_to_kokoro_voices(tmp_path, monkeypatch):
    # Kokoro's model folder lists af_alloy, am_onyx…; the mapping comes from it.
    hub = tmp_path / "hub"
    vdir = hub / "models--prince-canuma--Kokoro-82M" / "snapshots" / "abc" / "voices"
    vdir.mkdir(parents=True)
    for vid in ("af_alloy", "af_nova", "am_echo", "am_onyx", "bm_fable", "af_sky", "ef_dora"):
        (vdir / f"{vid}.safetensors").write_bytes(b"")
    client, app, engine = render_client(tmp_path)
    app.state.engine_store._hub = hub
    for name, expected in (("alloy", "af_alloy"), ("onyx", "am_onyx"), ("fable", "bm_fable"), ("nova", "af_nova")):
        r = client.post("/v1/audio/speech", json={"input": "Hi.", "voice": name, "response_format": "wav"})
        assert r.status_code == 200
        assert r.headers["X-Myna-Voice"] == expected
    # Unknown voice → the engine's resolved default.
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "voice": "nobody", "response_format": "wav"})
    assert r.headers["X-Myna-Voice"] == "af_heart"


def test_speech_openai_voice_on_single_voice_engine(tmp_path):
    client, _, engine = render_client(tmp_path, {"engine": "chatterbox", "model": "mlx-community/chatterbox-turbo-8bit"})
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "voice": "shimmer", "response_format": "wav"})
    assert r.status_code == 200
    assert r.headers["X-Myna-Voice"] == "chatterbox"
    assert r.headers["X-Myna-Engine"] == "chatterbox"
    # The engine's own sampling settings ride along.
    assert engine.calls[0]["extra"]["top_k"] == 1000
    assert engine.calls[0]["model"] == "mlx-community/chatterbox-turbo-8bit"


def test_speech_model_aliases_and_engine_not_active(tmp_path):
    client, _, _ = render_client(tmp_path)
    for model in ("tts-1", "tts-1-hd", "gpt-4o-mini-tts", "myna", "kokoro"):
        r = client.post("/v1/audio/speech", json={"input": "Hi.", "model": model, "response_format": "wav"})
        assert r.status_code == 200, model
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "model": "soprano", "response_format": "wav"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "engine_not_active"
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "model": "no-such-model", "response_format": "wav"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "engine_not_active"


def test_speech_input_errors_use_openai_shape(tmp_path):
    client, _, engine = render_client(tmp_path)
    r = client.post("/v1/audio/speech", json={"input": "   ", "response_format": "wav"})
    assert r.status_code == 400
    assert r.json() == {"error": {"message": "input is empty.", "type": "invalid_request_error",
                                  "param": "input", "code": "empty_input"}}
    r = client.post("/v1/audio/speech", json={"input": "x" * 40_001, "response_format": "wav"})
    assert r.status_code == 413
    assert r.json()["error"]["code"] == "input_too_long"
    r = client.post("/v1/audio/speech", json={"response_format": "wav"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "empty_input"
    assert r.json()["error"]["param"] == "input"
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "response_format": "wma"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_format"
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "speed": 9, "response_format": "wav"})
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_speed"
    assert engine.calls == []


def test_speech_speed_clamped_on_kokoro_ignored_elsewhere(tmp_path):
    client, _, engine = render_client(tmp_path)
    client.post("/v1/audio/speech", json={"input": "Hi.", "speed": 4.0, "response_format": "wav"})
    client.post("/v1/audio/speech", json={"input": "Hi.", "speed": 0.25, "response_format": "wav"})
    assert [c["speed"] for c in engine.calls] == [2.0, 0.5]
    client2, _, engine2 = render_client(tmp_path, {"engine": "pocket", "model": "mlx-community/pocket-tts"})
    client2.post("/v1/audio/speech", json={"input": "Hi.", "speed": 1.7, "response_format": "wav"})
    assert engine2.calls[0]["speed"] == 1.0


def test_speech_engine_errors(tmp_path):
    down = FakeEngine(fail_times=99, exc=httpx.ConnectError("refused"))
    client, _, _ = render_client(tmp_path, engine=down)
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "response_format": "wav"})
    assert r.status_code == 503
    assert r.json()["error"]["code"] == "engine_down"
    assert r.json()["error"]["type"] == "server_error"

    broken = FakeEngine(fail_times=99)
    client, _, _ = render_client(tmp_path, engine=broken)
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "response_format": "wav"})
    assert r.status_code == 502
    assert r.json()["error"]["code"] == "engine_error"


def test_speech_retries_one_engine_hiccup(tmp_path, monkeypatch):
    monkeypatch.setattr("myna.render.time.sleep", lambda s: None)
    flaky = FakeEngine(fail_times=1)
    client, _, _ = render_client(tmp_path, engine=flaky)
    r = client.post("/v1/audio/speech", json={"input": "Hi.", "response_format": "wav"})
    assert r.status_code == 200
    assert len(flaky.calls) == 2


def test_models_lists_active_engine_and_aliases(tmp_path):
    client, _, _ = render_client(tmp_path)
    body = client.get("/v1/models").json()
    assert body["object"] == "list"
    ids = {m["id"]: m for m in body["data"]}
    assert ids["kokoro"]["active"] is True
    assert ids["kokoro"]["owned_by"] == "myna"
    for alias in ("myna", "tts-1", "tts-1-hd", "gpt-4o-mini-tts"):
        assert ids[alias]["alias_of"] == "kokoro"
    assert all(m["object"] == "model" and isinstance(m["created"], int) for m in body["data"])


def test_voices_lists_engine_voices_with_openai_aliases(tmp_path):
    client, _, _ = render_client(tmp_path, {"engine": "pocket", "model": "mlx-community/pocket-tts"})
    body = client.get("/v1/audio/voices").json()
    assert body["engine"] == "pocket"
    ids = [v["id"] for v in body["voices"]]
    assert "alba" in ids and "marius" in ids
    assert sum(1 for v in body["voices"] if v["default"]) == 1
    aliases = body["openai_aliases"]
    assert set(aliases) == {"alloy", "ash", "ballad", "coral", "echo", "fable",
                            "onyx", "nova", "sage", "shimmer", "verse"}
    assert aliases["alloy"] == "alba"  # OpenAI's default → the engine's default
    assert set(aliases.values()) <= set(ids)
    # Names are spread over the engine's voices, not all piled on one.
    assert len(set(aliases.values())) >= 6


def test_long_paragraphs_render_in_short_chunks(tmp_path):
    """A live read waits behind at most one render chunk, so chunks stay short
    even though reads use 1500-character chunks."""
    client, app, engine = render_client(tmp_path)
    sentence = "This sentence is about sixty characters long, give or take. "
    text = (sentence * 30).strip()  # one ~1800-character paragraph
    r = client.post("/v1/audio/speech", json={"input": text, "response_format": "wav"})
    assert r.status_code == 200
    sizes = [len(c["text"]) for c in engine.calls]
    assert max(sizes) <= 400
    assert len(sizes) == int(r.headers["X-Myna-Chunks"]) >= 5
    assert " ".join(c["text"] for c in engine.calls) == text
