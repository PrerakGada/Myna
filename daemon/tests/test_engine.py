import myna.engine as eng


def test_synthesize_posts_correct_body_and_returns_bytes(monkeypatch):
    captured = {}

    class FakeResp:
        content = b"RIFFfakewav"

        def raise_for_status(self):
            pass

    def fake_post(url, json, timeout):
        captured["url"] = url
        captured["json"] = json
        return FakeResp()

    monkeypatch.setattr(eng.httpx, "post", fake_post)
    out = eng.synthesize(
        "hello", voice="af_heart", speed=1.25, base_url="http://x:8765"
    )
    assert out == b"RIFFfakewav"
    assert captured["url"] == "http://x:8765/v1/audio/speech"
    assert captured["json"]["input"] == "hello"
    assert captured["json"]["voice"] == "af_heart"
    assert captured["json"]["speed"] == 1.25
    assert captured["json"]["response_format"] == "wav"
    assert captured["json"]["lang_code"] == "a"


def test_engine_up_true_on_success(monkeypatch):
    class FakeResp:
        def raise_for_status(self):
            pass

    monkeypatch.setattr(eng.httpx, "get", lambda url, timeout: FakeResp())
    assert eng.engine_up("http://x:8765") is True


def test_engine_up_false_on_error(monkeypatch):
    def boom(url, timeout):
        raise RuntimeError("refused")

    monkeypatch.setattr(eng.httpx, "get", boom)
    assert eng.engine_up("http://x:8765") is False
