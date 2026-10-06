"""API access: the loopback/LAN middleware, the key, API settings (and when
they persist), the rebind hook, and the request log."""

import json
import sys
import time

import pytest
from fastapi.testclient import TestClient

from myna import api_access, encode
from myna.api_access import ApiAccess, bind_host, is_loopback_client

from .render_helpers import render_client


@pytest.fixture(autouse=True)
def _fresh_probe():
    encode.reset_probe()
    yield
    encode.reset_probe()


def wait_for(pred, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if pred():
            return True
        time.sleep(0.01)
    raise AssertionError("condition never became true")


def lan_client(app, key=None):
    """A caller on another machine: peer 192.168.1.50, Host = this Mac's LAN IP."""
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    return TestClient(app, base_url="http://192.168.1.20:8766", client=("192.168.1.50", 50123), headers=headers)


def enable_lan(client, app):
    r = client.post("/v2/api/settings", json={"lan_enabled": True})
    assert r.status_code == 200
    return r.json()["api_key"]


# ----- who counts as local -----


@pytest.mark.parametrize("host, local", [
    ("127.0.0.1", True), ("127.8.9.10", True), ("::1", True), ("::ffff:127.0.0.1", True),
    (None, True), ("testclient", True),
    ("192.168.1.50", False), ("10.0.0.2", False), ("100.93.1.2", False), ("fe80::1", False),
    ("evil.example.com", False), ("", False),
])
def test_is_loopback_client(host, local):
    assert is_loopback_client(host) is local


def test_bind_host_follows_config():
    assert bind_host({}) == "127.0.0.1"
    assert bind_host({"api_lan": False}) == "127.0.0.1"
    assert bind_host({"api_lan": True}) == "0.0.0.0"


# ----- the middleware -----


def test_loopback_needs_no_key_and_keeps_the_host_check(tmp_path):
    client, app, _ = render_client(tmp_path)
    assert client.get("/v1/models").status_code == 200
    assert client.get("/v2/status").status_code == 200
    evil = TestClient(app, base_url="http://evil.example.com")
    r = evil.get("/v1/models")
    assert r.status_code == 400
    assert r.text == "Invalid host header"


def test_lan_off_refuses_everything_from_other_devices(tmp_path):
    client, app, _ = render_client(tmp_path)
    key = client.get("/v2/api/settings").json()["api_key"]
    lan = lan_client(app, key)
    r = lan.get("/v1/models")
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "forbidden"
    r = lan.get("/v2/status")
    assert r.status_code == 403
    assert r.json()["reason"] == "forbidden"


def test_lan_on_requires_the_key_for_v1(tmp_path):
    client, app, engine = render_client(tmp_path)
    key = enable_lan(client, app)
    r = lan_client(app).get("/v1/models")
    assert r.status_code == 401
    assert r.headers["WWW-Authenticate"] == "Bearer"
    assert r.json()["error"]["code"] == "unauthorized"
    assert r.json()["error"]["type"] == "invalid_request_error"
    assert lan_client(app, "myna-wrong").get("/v1/models").status_code == 401
    assert lan_client(app, key[:-1]).get("/v1/models").status_code == 401
    assert lan_client(app, key).get("/v1/models").status_code == 200
    # Scheme is case-insensitive, as HTTP says.
    r = TestClient(app, base_url="http://nebula.local:8766", client=("192.168.1.50", 1),
                   headers={"Authorization": f"bearer {key}"}).get("/v1/audio/voices")
    assert r.status_code == 200
    r = lan_client(app, key).post("/v1/audio/speech", json={"input": "Hi.", "response_format": "wav"})
    assert r.status_code == 200
    assert r.content.startswith(b"RIFF")


@pytest.mark.parametrize("method, path", [
    ("GET", "/v2/status"), ("POST", "/v2/synthesize"), ("GET", "/v2/api/settings"),
    ("POST", "/v2/api/settings"), ("GET", "/v2/renders"), ("POST", "/v2/renders"),
    ("POST", "/speak"), ("POST", "/stop"), ("GET", "/status"), ("POST", "/v2/engines/soprano/activate"),
    ("GET", "/docs"), ("GET", "/openapi.json"),
])
def test_lan_can_never_reach_anything_but_v1(tmp_path, method, path):
    client, app, engine = render_client(tmp_path)
    key = enable_lan(client, app)
    r = lan_client(app, key).request(method, path, json={})
    assert r.status_code == 403
    assert r.json() == {"ok": False, "reason": "forbidden", "detail": "Only /v1/* is reachable from other devices."}
    assert engine.calls == []
    assert app.state.player.calls == []


def test_turning_lan_off_blocks_at_once_even_before_the_rebind(tmp_path):
    client, app, _ = render_client(tmp_path)
    key = enable_lan(client, app)
    app.state.api_access.bound_lan = True  # as if the rebind had happened
    assert lan_client(app, key).get("/v1/models").status_code == 200
    body = client.post("/v2/api/settings", json={"lan_enabled": False}).json()
    assert body["restart_pending"] is True  # still bound wide…
    assert lan_client(app, key).get("/v1/models").status_code == 403  # …but refused


def test_regenerated_key_retires_the_old_one(tmp_path):
    client, app, _ = render_client(tmp_path)
    old = enable_lan(client, app)
    new = client.post("/v2/api/settings", json={"regenerate_key": True}).json()["api_key"]
    assert new != old
    assert lan_client(app, old).get("/v1/models").status_code == 401
    assert lan_client(app, new).get("/v1/models").status_code == 200


# ----- settings -----


def test_settings_shape(tmp_path, monkeypatch):
    monkeypatch.setattr(api_access, "_lan_hosts", lambda: ["192.168.1.20", "Nebula.local"])
    client, app, _ = render_client(tmp_path)
    s = client.get("/v2/api/settings").json()
    assert s["base_url"] == "http://127.0.0.1:80/v1"  # the port this request came in on
    assert s["lan_enabled"] is False
    assert s["lan_urls"] == ["http://192.168.1.20:80/v1", "http://Nebula.local:80/v1"]
    assert s["api_key"].startswith("myna-") and len(s["api_key"]) == 37
    assert s["requires_key_on_lan"] is True
    assert s["restart_pending"] is False
    # Stable across reads.
    assert client.get("/v2/api/settings").json()["api_key"] == s["api_key"]
    # Only loopback callers ever see the key.
    assert app.state.api_access.settings(8766, loopback=False)["api_key"] is None


def test_config_key_is_reused(tmp_path):
    client, app, _ = render_client(tmp_path, {"api_key": "myna-fromconfig", "api_lan": True})
    s = client.get("/v2/api/settings").json()
    assert s["api_key"] == "myna-fromconfig"
    assert s["lan_enabled"] is True
    assert s["restart_pending"] is False
    assert lan_client(app, "myna-fromconfig").get("/v1/models").status_code == 200


def test_settings_persist_only_from_the_primary_daemon():
    saved = []
    cfg = {"daemon_port": 8766}
    access = ApiAccess(cfg, save_config=saved.append, persist_config=True)
    access.set_lan(True, 8794)  # a second daemon on another port
    assert saved == []
    assert access.lan_enabled is True  # in memory only
    access.set_lan(False, 8766)
    assert saved == [{"api_lan": False, "api_key": access._key}]
    saved.clear()
    no_persist = ApiAccess({"daemon_port": 8766}, save_config=saved.append, persist_config=False)
    no_persist.set_lan(True, 8766)
    no_persist.regenerate_key(8766)
    assert saved == []


def test_lan_change_asks_the_service_to_rebind(tmp_path):
    client, app, _ = render_client(tmp_path)
    calls = []
    app.state.api_access.request_restart = lambda: calls.append(time.monotonic())
    s = client.post("/v2/api/settings", json={"lan_enabled": True}).json()
    assert s["lan_enabled"] is True and s["restart_pending"] is True
    wait_for(lambda: calls)
    assert app.state.api_access.restart_requested is True
    # Same value again: nothing to do.
    client.post("/v2/api/settings", json={"lan_enabled": True})
    time.sleep(0.4)
    assert len(calls) == 1


def test_lan_change_without_a_service_just_waits(tmp_path):
    client, app, _ = render_client(tmp_path)
    s = client.post("/v2/api/settings", json={"lan_enabled": True}).json()
    assert s["restart_pending"] is True
    assert app.state.api_access.restart_requested is False


# ----- the request log -----


def test_log_records_v1_without_the_text(tmp_path):
    client, app, _ = render_client(tmp_path)
    secret_text = "The quick brown fox is a secret."
    client.post("/v1/audio/speech", json={"input": secret_text, "voice": "am_adam", "response_format": "wav"},
                headers={"User-Agent": "OpenAI/Python 3.20.0"})
    client.get("/v2/status")
    entries = client.get("/v2/api/log").json()["requests"]
    assert len(entries) == 1
    e = entries[0]
    assert e["method"] == "POST" and e["path"] == "/v1/audio/speech"
    assert e["status"] == 200
    assert e["client"] == "testclient"
    assert e["user_agent"] == "OpenAI/Python 3.20.0"
    assert e["chars"] == len(secret_text)
    assert e["format"] == "wav"
    assert e["voice"] == "am_adam"
    assert e["audio_s"] > 0
    assert isinstance(e["ms"], int) and e["at"] > 0
    assert secret_text not in json.dumps(entries)
    assert "secret" not in json.dumps(entries)


def test_log_skips_render_polls_keeps_actions_and_rejections(tmp_path):
    client, app, _ = render_client(tmp_path)
    key = enable_lan(client, app)
    job = client.post("/v2/renders", json={"text": "Hi.", "format": "wav"}).json()
    client.get("/v2/renders")
    client.get(f"/v2/renders/{job['id']}")
    lan_client(app, "wrong").get("/v1/models")
    lan_client(app, key).get("/v2/status")
    paths = [(e["method"], e["path"], e["status"]) for e in client.get("/v2/api/log").json()["requests"]]
    assert paths == [("GET", "/v1/models", 401), ("POST", "/v2/renders", 201)]
    rejected = client.get("/v2/api/log?limit=1").json()["requests"][0]
    assert rejected["client"] == "192.168.1.50"


def test_log_is_a_ring_of_200_newest_first(tmp_path):
    client, app, _ = render_client(tmp_path)
    for _ in range(205):
        client.get("/v1/models")
    assert len(app.state.api_access.log) == 200
    assert len(client.get("/v2/api/log?limit=500").json()["requests"]) == 200
    entries = client.get("/v2/api/log?limit=3").json()["requests"]
    assert len(entries) == 3
    assert entries[0]["at"] >= entries[1]["at"] >= entries[2]["at"]


# ----- restart mechanism -----


def test_reexec_replaces_the_process_with_the_same_command(monkeypatch):
    seen = []
    monkeypatch.setattr(api_access.os, "execv", lambda exe, argv: seen.append((exe, argv)))
    monkeypatch.setattr(api_access.os, "_exit", lambda code: seen.append(("exit", code)))
    monkeypatch.setattr(sys, "orig_argv", ["/opt/myna/bin/Myna Voice", "-m", "myna"], raising=False)
    api_access.reexec()
    assert seen[0] == (sys.executable, ["/opt/myna/bin/Myna Voice", "-m", "myna"])


def test_reexec_falls_back_to_exit_for_launchd(monkeypatch):
    def boom(exe, argv):
        raise OSError("nope")
    exits = []
    monkeypatch.setattr(api_access.os, "execv", boom)
    monkeypatch.setattr(api_access.os, "_exit", exits.append)
    api_access.reexec()
    assert exits == [75]


def test_main_binds_from_config_and_reexecs_on_request(monkeypatch):
    from myna import __main__ as entry

    # Keep main() from arming engine autostart for later tests in this process.
    monkeypatch.setenv("MYNA_ENGINE_AUTOSTART", "0")
    from myna.config import DEFAULTS
    cfg = dict(DEFAULTS, api_lan=True, daemon_port=8799, karaoke={"enabled": False})
    monkeypatch.setattr(entry, "load_config", lambda: cfg)
    created = {}

    class FakeServer:
        def __init__(self, config):
            created["host"] = config.host
            created["port"] = config.port
            created["app"] = config.app
            self.should_exit = False
            self.started = True

        def run(self):
            access = created["app"].state.api_access
            created["bound_lan"] = access.bound_lan
            access.request_restart()  # what a LAN change does
            created["should_exit"] = self.should_exit
            access.restart_requested = True

    reexecs = []
    monkeypatch.setattr(entry.uvicorn, "Server", FakeServer)
    monkeypatch.setattr(entry.api_access, "reexec", lambda: reexecs.append(1))
    entry.main()
    assert created["host"] == "0.0.0.0" and created["port"] == 8799
    assert created["bound_lan"] is True
    assert created["should_exit"] is True
    assert created["app"].state.service_port == 8799
    assert reexecs == [1]
