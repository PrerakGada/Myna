"""Integration tests: /v2/status state machine threading through /v2/synthesize.

The state machine transitions are driven by the synth pipeline:
  - request accepted     -> thinking
  - first chunk on wire  -> speaking
  - last chunk on wire   -> idle
  - engine pre-check fails or mid-stream synth raises -> error
"""

from .v2_helpers import make_client


def _read_stream_fully(response) -> bytes:
    # TestClient hands us the entire response body lazily; touching .content
    # drains the generator so the post-stream state transition has fired.
    return response.content


def test_status_state_is_idle_at_boot():
    client, fp, app = make_client()
    body = client.get("/v2/status").json()
    assert body["state"] == "idle"
    assert body["ok"] is True
    assert body["version"]  # non-empty
    assert body["request_id"] is None


def test_status_engine_up_field_mirrors_engine():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: True
    app.state.last_engine_check_at = 0.0
    body = client.get("/v2/status").json()
    assert body["engine_up"] is True

    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0
    body = client.get("/v2/status").json()
    assert body["engine_up"] is False


def test_synthesize_drives_thinking_then_idle():
    client, fp, app = make_client(config_overrides={"chunk_chars": 20})
    r = client.post(
        "/v2/synthesize",
        json={"text": "One two three. Four five six.", "session_id": "rid_a"},
    )
    _read_stream_fully(r)
    # After successful drain we're back at idle (request_id cleared).
    body = client.get("/v2/status").json()
    assert body["state"] == "idle"
    assert body["request_id"] is None


def test_synthesize_engine_down_pre_check_drives_error():
    client, fp, app = make_client()
    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0
    r = client.post("/v2/synthesize", json={"text": "hi"})
    assert r.status_code == 502
    body = client.get("/v2/status").json()
    assert body["state"] == "error"


def test_synthesize_engine_error_first_chunk_drives_error():
    client, fp, app = make_client()

    def boom(text, **kw):
        raise RuntimeError("kokoro 500")

    app.state.synthesize = boom
    r = client.post("/v2/synthesize", json={"text": "hi"})
    assert r.status_code == 502
    body = client.get("/v2/status").json()
    assert body["state"] == "error"


def test_synthesize_mid_stream_failure_drives_error():
    client, fp, app = make_client(config_overrides={"chunk_chars": 20})
    calls = {"n": 0}

    def synth(text, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            return b"RIFFfake"
        raise RuntimeError("engine died")

    app.state.synthesize = synth
    r = client.post(
        "/v2/synthesize", json={"text": "One two three. Four five six."}
    )
    _read_stream_fully(r)
    body = client.get("/v2/status").json()
    assert body["state"] == "error"


def test_synthesize_subsequent_success_clears_error():
    client, fp, app = make_client()
    # Knock into error first.
    app.state.machine.force("error")
    assert client.get("/v2/status").json()["state"] == "error"
    # Now a clean synth call should walk error -> thinking -> speaking -> idle.
    r = client.post("/v2/synthesize", json={"text": "hello", "session_id": "rid_x"})
    _read_stream_fully(r)
    body = client.get("/v2/status").json()
    assert body["state"] == "idle"


def test_since_ms_is_present_and_non_negative():
    client, fp, app = make_client()
    body = client.get("/v2/status").json()
    assert "since_ms" in body
    assert body["since_ms"] >= 0


def test_synthesize_client_disconnect_resets_off_thinking():
    """A client that disconnects mid-stream must not leave the machine wedged
    in thinking/speaking. Without the disconnect-safe reset in the synth
    generator, an interrupted read 503s every later voice preview
    (reason=engine_thinking) and freezes the menu-bar 'thinking' icon until the
    daemon is restarted — the recurring 'audio stopped working' bug."""
    import time

    client, fp, app = make_client(config_overrides={"chunk_chars": 15})
    app.state.synthesize = lambda text, **kw: b"RIFFfake"
    text = "One two three. Four five six. Seven eight nine. Ten eleven twelve."
    # Open the stream, take the first bytes, then disconnect (leave the block).
    with client.stream(
        "POST", "/v2/synthesize", json={"text": text, "session_id": "rid_dc"}
    ) as r:
        for _ in r.iter_bytes():
            break
    # The generator's finally must have transitioned us off the in-flight
    # states. Poll briefly — the reset runs on the server task after close.
    state = None
    for _ in range(100):
        state = client.get("/v2/status").json()["state"]
        if state not in ("thinking", "speaking"):
            break
        time.sleep(0.02)
    assert state == "idle", f"machine wedged in {state!r} after client disconnect"
