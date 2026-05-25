from fastapi.testclient import TestClient

from myna.app import create_app


class FakePlayer:
    def __init__(self):
        self.calls = []
        self._state = "idle"

    def play(self, producer, meta):
        # Consume producer so the synthesize pipeline runs.
        self.calls.append(("play", list(producer), meta))
        self._state = "playing"

    def pause(self):
        self.calls.append(("pause",))
        self._state = "paused"

    def resume(self):
        self.calls.append(("resume",))
        self._state = "playing"

    def stop(self):
        self.calls.append(("stop",))
        self._state = "idle"

    def status(self):
        return {"state": self._state, "now_playing": None}


def make_client(**overrides):
    app = create_app()
    fp = FakePlayer()
    app.state.player = fp
    app.state.synthesize = lambda text, **kw: b"RIFFfake"
    app.state.engine_up = lambda base_url, **kw: True
    app.state.summarize = lambda text, **kw: "SUMMARY"
    app.state.extract = lambda url: "EXTRACTED"
    for k, v in overrides.items():
        setattr(app.state, k, v)
    return TestClient(app), fp, app


def test_speak_full_plays(tmp_path, monkeypatch):
    client, fp, app = make_client()
    r = client.post("/speak", json={"text": "Hello there.", "mode": "full"})
    assert r.json()["ok"] is True
    assert fp.calls[0][0] == "play"
    # producer yielded at least one synthesized chunk
    assert len(fp.calls[0][1]) >= 1


def test_speak_empty_rejected():
    client, fp, app = make_client()
    r = client.post("/speak", json={"text": "   ", "mode": "full"})
    assert r.json() == {"ok": False, "reason": "empty"}
    assert fp.calls == []


def test_speak_summary_uses_summarizer():
    seen = {}
    def _fake_summarize(text, **kw):
        seen["called"] = True
        return "SHORT"

    client, fp, app = make_client(summarize=_fake_summarize)
    r = client.post("/speak", json={"text": "long body", "mode": "summary"})
    assert r.json()["ok"] is True
    assert seen.get("called") is True


def test_speak_url_extract_failure():
    client, fp, app = make_client(extract=lambda url: None)
    r = client.post("/speak", json={"url": "http://x", "mode": "full"})
    assert r.json() == {"ok": False, "reason": "extract_failed"}


def test_announce_registry_and_play_flow():
    client, fp, app = make_client()
    r = client.post(
        "/announce",
        json={"session_id": "s1", "label": "ECS", "text": "hello body"},
    )
    rid = r.json()["id"]
    items = client.get("/registry").json()["items"]
    assert items[0]["label"] == "ECS"
    r2 = client.post(f"/play/{rid}?mode=full")
    assert r2.json()["ok"] is True
    # registry now empty
    assert client.get("/registry").json()["items"] == []
    # unknown id
    assert client.post("/play/deadbeef").json() == {"ok": False, "reason": "not_found"}


def test_controls_call_player():
    client, fp, app = make_client()
    client.post("/pause")
    client.post("/resume")
    client.post("/stop")
    kinds = [c[0] for c in fp.calls]
    assert kinds == ["pause", "resume", "stop"]


def test_speed_clamps_and_status_shape():
    client, fp, app = make_client()
    assert client.post("/speed", json={"value": 5.0}).json()["speed"] == 2.0
    assert client.post("/speed", json={"value": 0.1}).json()["speed"] == 0.5
    st = client.get("/status").json()
    assert set(st) == {"state", "now_playing", "speed", "registry_count", "engine"}
    assert st["engine"] == "up"
