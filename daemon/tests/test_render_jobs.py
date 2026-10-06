"""/v2/renders jobs: lifecycle, cancel, delete, persistence and recovery,
yielding to live reads, and the renders folder never being the user's."""

import json
import shutil
import subprocess
import threading
import time
from pathlib import Path

import pytest

from myna import encode
from myna import render_jobs as jobs_mod
from myna.render_jobs import RenderJobs
from myna.state import StateMachine

from .render_helpers import FRAMES_PER_CHAR, RATE, FakeEngine, make_wav, render_client, wav_frames


@pytest.fixture(autouse=True)
def _fresh_probe():
    encode.reset_probe()
    yield
    encode.reset_probe()


def wait_for(pred, timeout=5.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = pred()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError("condition never became true")


def job_client(tmp_path, config_overrides=None, engine=None):
    """render_client with a fast job store: no retry delays, quick polling."""
    client, app, engine = render_client(tmp_path, config_overrides, engine=engine)
    app.state.render_jobs = RenderJobs(app, tmp_path / "renders", retries=(), yield_poll_s=0.01)
    return client, app, engine


def done(client, job_id, status="done"):
    return wait_for(lambda: (j := client.get(f"/v2/renders/{job_id}").json())["status"] == status and j)


class SteppedEngine(FakeEngine):
    """Each synthesize call waits for the test to release one step."""

    def __init__(self):
        super().__init__()
        self.steps = threading.Semaphore(0)

    def __call__(self, text, **kw):
        assert self.steps.acquire(timeout=10), "test never released a step"
        return super().__call__(text, **kw)


# ----- lifecycle -----


def test_text_job_renders_to_done(tmp_path):
    client, app, engine = job_client(tmp_path)
    text = "First paragraph, short.\n\nSecond paragraph is here."
    r = client.post("/v2/renders", json={"title": "Two paras", "text": text, "format": "wav", "source": "studio"})
    assert r.status_code == 201, r.text
    job = r.json()
    assert job["status"] in ("queued", "rendering")
    assert job["id"].startswith("r_") and len(job["id"]) == 10
    assert job["title"] == "Two paras"
    assert job["source"] == "studio"
    assert job["engine"] == "kokoro" and job["voice"] == "af_heart"
    assert job["chunks_total"] == 2
    assert job["words"] == 7
    assert job["preview"].startswith("First paragraph")
    assert job["chapters"] is None

    job = done(client, job["id"])
    assert job["progress"] == 1.0
    assert job["chunks_done"] == 2
    expected_frames = sum(len(c["text"]) for c in engine.calls) * FRAMES_PER_CHAR
    assert job["audio_s"] == pytest.approx(expected_frames / RATE, abs=0.01)
    assert job["started_at"] >= job["created_at"] and job["finished_at"] >= job["started_at"]
    path = Path(job["file_path"])
    assert path == tmp_path / "renders" / f"{job['id']}.wav"
    assert job["bytes"] == path.stat().st_size

    audio = client.get(f"/v2/renders/{job['id']}/audio")
    assert audio.status_code == 200
    assert audio.headers["content-type"] == "audio/wav"
    assert "Two%20paras.wav" in audio.headers["content-disposition"]
    assert wav_frames(audio.content) == (expected_frames, RATE)

    # Persisted, and the queued text is gone once rendered.
    index = json.loads((tmp_path / "renders" / "index.json").read_text())
    assert index["renders"][0]["id"] == job["id"]
    assert index["renders"][0]["status"] == "done"
    assert not (tmp_path / "renders" / "sources" / f"{job['id']}.json").exists()
    assert not list((tmp_path / "renders").glob("*.partial.wav"))


def test_job_is_not_a_read(tmp_path):
    client, app, engine = job_client(tmp_path)
    before = dict(app.state.cfg.get("engine_voices") or {})
    job = client.post("/v2/renders", json={"text": "Hello.", "voice": "am_adam", "format": "wav"}).json()
    done(client, job["id"])
    assert app.state.machine.state == "idle"
    assert app.state.player.calls == []
    assert (app.state.cfg.get("engine_voices") or {}) == before
    assert engine.calls[0]["voice"] == "am_adam"


def test_sections_job_has_chapters_and_pauses(tmp_path):
    client, app, engine = job_client(tmp_path)
    body = {
        "title": "Book",
        "sections": [{"title": "One", "text": "Alpha."}, {"title": "", "text": "  "}, {"title": "Two", "text": "Beta gamma."}],
        "format": "wav",
        "section_pause_ms": 500,
    }
    job = done(client, client.post("/v2/renders", json=body).json()["id"])
    first = len("Alpha.") * FRAMES_PER_CHAR
    second = len("Beta gamma.") * FRAMES_PER_CHAR
    pause = RATE // 2
    assert job["chapters"] == [
        {"title": "One", "start_s": 0.0},
        {"title": "Two", "start_s": round((first + pause) / RATE, 3)},
    ]
    frames, _ = wav_frames(client.get(f"/v2/renders/{job['id']}/audio").content)
    assert frames == first + pause + second


@pytest.mark.skipif(not (encode.find_tool("ffmpeg") and encode.find_tool("ffprobe") and shutil.which("afconvert")),
                    reason="needs afconvert, ffmpeg and ffprobe")
def test_m4a_job_carries_chapter_markers(tmp_path):
    client, app, engine = job_client(tmp_path)
    body = {"title": "Book", "format": "m4a",
            "sections": [{"title": "Chapter 1", "text": "A" * 150}, {"title": "Chapter 2", "text": "B" * 150}]}
    job = done(client, client.post("/v2/renders", json=body).json()["id"])
    out = subprocess.run(
        [encode.find_tool("ffprobe"), "-v", "error", "-show_chapters", "-of", "json", job["file_path"]],
        capture_output=True, text=True, check=True,
    )
    chapters = json.loads(out.stdout)["chapters"]
    assert [c["tags"]["title"] for c in chapters] == ["Chapter 1", "Chapter 2"]
    assert float(chapters[1]["start_time"]) == pytest.approx(job["chapters"][1]["start_s"], abs=0.05)


def test_progress_and_eta(tmp_path):
    engine = SteppedEngine()
    client, app, _ = job_client(tmp_path, engine=engine)
    text = "\n\n".join(["Para one here.", "Para two, a bit longer.", "Three."])
    job_id = client.post("/v2/renders", json={"text": text, "format": "wav"}).json()["id"]
    engine.steps.release()
    j = wait_for(lambda: (x := client.get(f"/v2/renders/{job_id}").json())["chunks_done"] == 1 and x)
    assert j["status"] == "rendering"
    assert j["eta_s"] is None
    assert j["progress"] == pytest.approx(len("Para one here.") / sum(map(len, text.split("\n\n"))), abs=0.001)
    engine.steps.release()
    j = wait_for(lambda: (x := client.get(f"/v2/renders/{job_id}").json())["chunks_done"] == 2 and x)
    assert j["eta_s"] is not None and j["eta_s"] >= 0
    engine.steps.release()
    done(client, job_id)


def test_list_newest_first(tmp_path):
    client, app, _ = job_client(tmp_path)
    a = client.post("/v2/renders", json={"text": "One.", "format": "wav"}).json()["id"]
    b = client.post("/v2/renders", json={"text": "Two.", "format": "wav"}).json()["id"]
    done(client, b)
    ids = [j["id"] for j in client.get("/v2/renders").json()["renders"]]
    assert ids == [b, a]


def test_title_defaults_and_url_jobs(tmp_path):
    client, app, _ = job_client(tmp_path)
    j = client.post("/v2/renders", json={"text": "# A heading\n\nBody text.", "format": "wav"}).json()
    assert j["title"] == "A heading"
    app.state.extract = lambda url: {"text": "Article body.", "title": "Article Title"}
    j = client.post("/v2/renders", json={"url": "https://example.com/a", "format": "wav"}).json()
    assert j["title"] == "Article Title"
    app.state.extract = lambda url: None
    r = client.post("/v2/renders", json={"url": "https://example.com/a"})
    assert r.status_code == 400 and r.json()["reason"] == "extract_failed"
    r = client.post("/v2/renders", json={"url": "file:///etc/passwd"})
    assert r.status_code == 400 and r.json()["reason"] == "invalid_url"


def test_openai_voice_names_work_for_jobs(tmp_path):
    client, app, engine = job_client(tmp_path, {"engine": "pocket", "model": "mlx-community/pocket-tts"})
    j = client.post("/v2/renders", json={"text": "Hi.", "voice": "alloy", "format": "wav", "speed": 1.5}).json()
    assert j["voice"] == "alba"
    assert j["engine"] == "pocket"
    assert j["speed"] == 1.0  # Pocket has no native speed; the job says so
    done(client, j["id"])
    assert engine.calls[0]["voice"] == "alba"


# ----- validation -----


def test_create_validation(tmp_path, monkeypatch):
    client, app, engine = job_client(tmp_path)

    def err(body):
        r = client.post("/v2/renders", json=body)
        return r.status_code, r.json().get("reason")

    assert err({}) == (400, "one_input_required")
    assert err({"text": "a", "url": "https://x.y"}) == (400, "one_input_required")
    assert err({"text": "   "}) == (400, "empty")
    assert err({"sections": [{"title": "x", "text": " "}]}) == (400, "empty")
    assert err({"text": "Hi.", "format": "pcm"}) == (400, "invalid_format")
    assert err({"text": "Hi.", "speed": 5}) == (400, "invalid_speed")
    monkeypatch.setattr("myna.render_routes.JOB_MAX_CHARS", 10)
    assert err({"text": "x" * 11}) == (413, "input_too_long")
    monkeypatch.setattr(encode.shutil, "which", lambda name, path=None: None)
    encode.reset_probe()
    assert err({"text": "Hi.", "format": "mp3"}) == (400, "format_unavailable")
    assert engine.calls == []


def test_unknown_ids(tmp_path):
    client, app, _ = job_client(tmp_path)
    for path in ("/v2/renders/r_00000000", "/v2/renders/../../etc", "/v2/renders/r_00000000/audio"):
        r = client.get(path)
        assert r.status_code == 404
    assert client.post("/v2/renders/r_00000000/cancel").status_code == 404
    r = client.delete("/v2/renders/r_00000000")
    assert r.status_code == 404
    assert r.json() == {"ok": False, "reason": "not_found", "detail": "No render with that id."}


# ----- cancel and delete -----


def test_audio_before_done_is_not_ready_and_cancel_rendering(tmp_path):
    engine = SteppedEngine()
    client, app, _ = job_client(tmp_path, engine=engine)
    text = "\n\n".join(f"Paragraph {i}." for i in range(5))
    job_id = client.post("/v2/renders", json={"text": text, "format": "wav"}).json()["id"]
    engine.steps.release()
    wait_for(lambda: client.get(f"/v2/renders/{job_id}").json()["chunks_done"] == 1)
    r = client.get(f"/v2/renders/{job_id}/audio")
    assert r.status_code == 409
    assert r.json()["reason"] == "not_ready"

    r = client.post(f"/v2/renders/{job_id}/cancel")
    assert r.status_code == 200
    assert r.json()["status"] == "cancelled"
    engine.steps.release(10)  # let any in-flight chunk finish
    time.sleep(0.1)
    j = client.get(f"/v2/renders/{job_id}").json()
    assert j["status"] == "cancelled"
    assert j["file_path"] is None
    assert len(engine.calls) <= 2  # stopped between chunks
    wait_for(lambda: not list((tmp_path / "renders").glob("*.partial.wav")))
    # Cancelling again is harmless.
    assert client.post(f"/v2/renders/{job_id}/cancel").json()["status"] == "cancelled"


def test_cancel_queued_job_never_renders(tmp_path):
    engine = SteppedEngine()
    client, app, _ = job_client(tmp_path, engine=engine)
    first = client.post("/v2/renders", json={"text": "First.", "format": "wav"}).json()["id"]
    second = client.post("/v2/renders", json={"text": "Second.", "format": "wav"}).json()["id"]
    assert client.get(f"/v2/renders/{second}").json()["status"] == "queued"
    assert client.post(f"/v2/renders/{second}/cancel").json()["status"] == "cancelled"
    engine.steps.release(5)
    done(client, first)
    time.sleep(0.05)
    assert [c["text"] for c in engine.calls] == ["First."]
    assert client.get(f"/v2/renders/{second}").json()["status"] == "cancelled"


def test_delete_removes_job_and_file(tmp_path):
    client, app, _ = job_client(tmp_path)
    j = done(client, client.post("/v2/renders", json={"text": "Bye.", "format": "wav"}).json()["id"])
    assert Path(j["file_path"]).exists()
    assert client.delete(f"/v2/renders/{j['id']}").json() == {"ok": True}
    assert not Path(j["file_path"]).exists()
    assert client.get(f"/v2/renders/{j['id']}").status_code == 404
    index = json.loads((tmp_path / "renders" / "index.json").read_text())
    assert index["renders"] == []


def test_delete_while_rendering(tmp_path):
    engine = SteppedEngine()
    client, app, _ = job_client(tmp_path, engine=engine)
    job_id = client.post("/v2/renders", json={"text": "A.\n\nB.\n\nC.", "format": "wav"}).json()["id"]
    engine.steps.release()
    wait_for(lambda: client.get(f"/v2/renders/{job_id}").json()["chunks_done"] == 1)
    assert client.delete(f"/v2/renders/{job_id}").json() == {"ok": True}
    engine.steps.release(10)
    wait_for(lambda: not list((tmp_path / "renders").glob("*.partial.wav")))
    time.sleep(0.05)
    assert client.get("/v2/renders").json()["renders"] == []
    assert not list((tmp_path / "renders").glob(f"{job_id}.*"))


# ----- live reads win -----


def test_render_waits_while_a_read_is_speaking(tmp_path):
    client, app, engine = job_client(tmp_path)
    app.state.machine.force("speaking", request_id="live")
    job_id = client.post("/v2/renders", json={"text": "Later.", "format": "wav"}).json()["id"]
    time.sleep(0.2)
    assert engine.calls == []
    assert client.get(f"/v2/renders/{job_id}").json()["status"] == "rendering"
    app.state.machine.force("idle")
    done(client, job_id)
    assert len(engine.calls) == 1


def test_render_waits_during_engine_switch_and_fresh_thinking_but_not_stale(tmp_path):
    client, app, engine = job_client(tmp_path)
    now = [1000.0]
    app.state.machine = StateMachine(clock=lambda: now[0])
    app.state.machine.force("thinking", request_id="live")
    job_id = client.post("/v2/renders", json={"text": "Wait.", "format": "wav"}).json()["id"]
    time.sleep(0.15)
    assert engine.calls == []
    # A "thinking" older than 45 s is a stuck state, not a read, but an
    # engine switch in progress still holds the render back.
    app.state.engine_switch = {"engine": "soprano", "started_at": 0}
    now[0] += 60
    time.sleep(0.15)
    assert engine.calls == []  # still waiting: an engine switch is loading
    app.state.engine_switch = None
    done(client, job_id)


def test_engine_change_fails_the_job(tmp_path):
    engine = SteppedEngine()
    client, app, _ = job_client(tmp_path, engine=engine)
    first = client.post("/v2/renders", json={"text": "A.\n\nB.", "format": "wav"}).json()["id"]
    queued = client.post("/v2/renders", json={"text": "C.", "format": "wav"}).json()["id"]
    app.state.cfg["engine"] = "soprano"  # the user switched engines
    engine.steps.release(5)
    j = done(client, first, status="failed")
    assert j["error"]["reason"] == "engine_changed"
    j = done(client, queued, status="failed")
    assert j["error"]["reason"] == "engine_changed"


def test_engine_error_fails_the_job(tmp_path):
    client, app, _ = job_client(tmp_path, engine=FakeEngine(fail_times=99))
    j = done(client, client.post("/v2/renders", json={"text": "Boom.", "format": "wav"}).json()["id"], "failed")
    assert j["error"] == {"reason": "engine_error", "detail": "engine exploded"}
    assert j["finished_at"] is not None


def test_retries_ride_out_a_hiccup(tmp_path):
    client, app, _ = render_client(tmp_path, engine=FakeEngine(fail_times=2))
    app.state.render_jobs = RenderJobs(app, tmp_path / "renders", retries=(0.0, 0.0, 0.0), yield_poll_s=0.01)
    j = done(client, client.post("/v2/renders", json={"text": "Fine.", "format": "wav"}).json()["id"])
    assert j["status"] == "done"


# ----- persistence -----


def _index(dir_: Path, *records):
    dir_.mkdir(parents=True, exist_ok=True)
    (dir_ / "index.json").write_text(json.dumps({"renders": list(records)}))


def _record(job_id, status, created_at, **extra):
    rec = {
        "id": job_id, "title": job_id, "status": status, "source": "studio", "created_at": created_at,
        "started_at": None, "finished_at": None, "engine": "kokoro", "voice": "af_heart", "speed": 1.0,
        "format": "wav", "chars": 6, "words": 1, "chunks_total": 1, "chunks_done": 0, "progress": 0.0,
        "audio_s": 0.0, "eta_s": None, "file_path": None, "bytes": None, "chapters": None,
        "error": None, "preview": "Resume",
    }
    rec.update(extra)
    return rec


def test_restart_recovers_interrupted_and_resumes_queued(tmp_path):
    rdir = tmp_path / "renders"
    _index(
        rdir,
        _record("r_00000001", "rendering", 1.0),
        _record("r_00000002", "queued", 2.0),
        _record("r_00000003", "queued", 3.0),  # its text is gone
        _record("r_00000004", "done", 0.5, file_path=str(rdir / "r_00000004.wav")),
    )
    (rdir / "r_00000001.partial.wav").write_bytes(make_wav(10))
    (rdir / "sources").mkdir()
    (rdir / "sources" / "r_00000002.json").write_text(json.dumps(
        {"sections": [{"title": "", "text": "Resume."}], "section_pause_ms": 0, "chunk_chars": 1500}))
    client, app, engine = job_client(tmp_path)
    jobs = {j["id"]: j for j in client.get("/v2/renders").json()["renders"]}
    assert jobs["r_00000001"]["status"] == "failed"
    assert jobs["r_00000001"]["error"]["reason"] == "interrupted"
    assert not (rdir / "r_00000001.partial.wav").exists()
    assert jobs["r_00000003"]["status"] == "failed"
    assert jobs["r_00000004"]["status"] == "done"
    j = done(client, "r_00000002")
    assert j["file_path"].endswith("r_00000002.wav")
    assert [c["text"] for c in engine.calls] == ["Resume."]


def test_corrupt_index_starts_empty(tmp_path):
    rdir = tmp_path / "renders"
    rdir.mkdir()
    (rdir / "index.json").write_text("{nope")
    client, app, _ = job_client(tmp_path)
    assert client.get("/v2/renders").json() == {"renders": []}


def test_lifespan_resumes_queue_at_service_boot(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient

    # The app's own lifespan must not spawn an engine or warm voices here.
    monkeypatch.setenv("MYNA_ENGINE_AUTOSTART", "0")
    monkeypatch.delenv("MYNA_WARM_VOICES", raising=False)

    client, app, engine = job_client(tmp_path)
    rdir = tmp_path / "renders"
    _index(rdir, _record("r_0000000a", "queued", 1.0))
    (rdir / "sources").mkdir()
    (rdir / "sources" / "r_0000000a.json").write_text(json.dumps(
        {"sections": [{"title": "", "text": "Boot."}], "section_pause_ms": 0, "chunk_chars": 1500}))
    app.state.service_port = 8766
    with TestClient(app, base_url="http://127.0.0.1"):
        wait_for(lambda: engine.calls)  # worker started by the lifespan, no request needed
    assert app.state.render_jobs._thread is not None


def test_building_the_app_touches_no_renders_folder(tmp_path, monkeypatch):
    real = jobs_mod.DEFAULT_DIR.expanduser()
    before = real.exists()
    client, app, _ = render_client(tmp_path)
    assert app.state.render_jobs is None
    client.get("/v2/health")
    assert app.state.render_jobs is None
    assert real.exists() == before


def test_renders_dir_rules(tmp_path):
    base = jobs_mod.DEFAULT_DIR.expanduser()
    assert jobs_mod.renders_dir({"renders_dir": str(tmp_path)}, port=1, primary=True, persist_config=True) == tmp_path
    tmp = jobs_mod.renders_dir({}, port=8766, primary=True, persist_config=False)
    assert tmp != base and "myna-renders-" in tmp.name
    tmp.rmdir()
    assert jobs_mod.renders_dir({}, port=8766, primary=True, persist_config=True) == base
    assert jobs_mod.renders_dir({}, port=8794, primary=False, persist_config=True) == base.with_name("renders-8794")
