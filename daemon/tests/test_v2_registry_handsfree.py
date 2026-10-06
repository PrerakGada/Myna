"""Claude Code hands-free additions to /v2/registry/*.

Attention entries (the Notification hook), the per-session rules that keep
them from going stale, and the partly-heard requeue the app's auto-read uses
when the user comes back mid-read. See myna/v2_registry.py.
"""

import json

from myna.v2_registry import V2Registry

from .v2_helpers import make_client


def _registry(tmp_path, clock=None):
    return V2Registry(path=tmp_path / "r.json", clock=clock or (lambda: 1_000_000))


def _alert(r, id, session="s1", ntype="permission_prompt"):
    return r.announce(
        id=id, source="claude-code", project_id="myna", title="Claude needs your permission to use Bash",
        text="Claude needs your permission to use Bash", ttl_s=600,
        kind="attention", session_id=session, notification_type=ntype,
        host_bundle_id="com.googlecode.iterm2",
    )


# ---------- pure registry ----------

def test_announce_defaults_to_reply_with_new_fields(tmp_path):
    r = _registry(tmp_path)
    e = r.announce(id="u_1", source="claude-code", project_id="p", title="t", ttl_s=600)
    assert e["kind"] == "reply"
    assert e["session_id"] is None
    assert e["notification_type"] is None
    assert e["host_bundle_id"] is None
    assert e["partly_heard"] is False


def test_unknown_kind_is_stored_as_reply(tmp_path):
    r = _registry(tmp_path)
    e = r.announce(id="u_1", source="cc", project_id="p", title="t", ttl_s=600, kind="banana")
    assert e["kind"] == "reply"


def test_notification_type_only_kept_for_attention(tmp_path):
    r = _registry(tmp_path)
    e = r.announce(
        id="u_1", source="cc", project_id="p", title="t", ttl_s=600,
        kind="reply", notification_type="permission_prompt",
    )
    assert e["notification_type"] is None
    a = _alert(r, "a_1")
    assert a["kind"] == "attention"
    assert a["notification_type"] == "permission_prompt"
    assert a["host_bundle_id"] == "com.googlecode.iterm2"


def test_newer_alert_replaces_older_alert_for_same_session(tmp_path):
    r = _registry(tmp_path)
    _alert(r, "a_1", ntype="permission_prompt")
    _alert(r, "a_2", ntype="idle_prompt")
    pending = r.snapshot()["pending"]
    assert [e["id"] for e in pending] == ["a_2"]
    assert r.get("a_1") is None  # dropped, not just dismissed


def test_alerts_from_different_sessions_coexist(tmp_path):
    r = _registry(tmp_path)
    _alert(r, "a_1", session="s1")
    _alert(r, "a_2", session="s2")
    assert {e["id"] for e in r.snapshot()["pending"]} == {"a_1", "a_2"}


def test_reply_dismisses_pending_alert_of_its_session_only(tmp_path):
    r = _registry(tmp_path)
    _alert(r, "a_1", session="s1")
    _alert(r, "a_2", session="s2")
    r.announce(
        id="u_1", source="claude-code", project_id="myna", title="Done.", ttl_s=600,
        kind="reply", session_id="s1",
    )
    pending_ids = {e["id"] for e in r.snapshot()["pending"]}
    assert pending_ids == {"a_2", "u_1"}
    # Dismissed, not deleted: the record stays.
    assert r.get("a_1")["dismissed_at_ms"] is not None


def test_reply_without_session_leaves_alerts_alone(tmp_path):
    r = _registry(tmp_path)
    _alert(r, "a_1", session="s1")
    r.announce(id="u_1", source="cc", project_id="myna", title="Done.", ttl_s=600)
    assert {e["id"] for e in r.snapshot()["pending"]} == {"a_1", "u_1"}


def test_legacy_persisted_entries_still_load_and_list(tmp_path):
    path = tmp_path / "r.json"
    path.write_text(json.dumps([{
        "id": "u_old", "source": "claude-code", "project_id": "p", "title": "old",
        "text": None, "announced_at_ms": 1_000_000, "ttl_s": 600,
        "played_at_ms": None, "dismissed_at_ms": None,
    }]))
    client, _fp, app = make_client(registry_path=path)
    app.state.v2_registry._clock = lambda: 1_000_500
    item = client.get("/v2/registry/list").json()["pending"][0]
    assert item["id"] == "u_old"
    assert item["kind"] == "reply"
    assert item["partly_heard"] is False


def test_requeue_partly_heard_creates_rest_and_dismisses_original(tmp_path):
    r = _registry(tmp_path)
    r.announce(
        id="u_1", source="claude-code", project_id="myna", title="First line.",
        text="First line.\n\nSecond part.", ttl_s=600, kind="reply",
        session_id="s1", host_bundle_id="com.apple.Terminal",
    )
    entry, reason = r.requeue_partly_heard("u_1", "  Second part.  ")
    assert reason == "ok"
    assert entry["id"] == "u_1-rest"
    assert entry["title"] == "Partly heard · First line."
    assert entry["text"] == "Second part."
    assert entry["partly_heard"] is True
    assert entry["session_id"] == "s1"
    assert entry["host_bundle_id"] == "com.apple.Terminal"
    pending = r.snapshot()["pending"]
    assert [e["id"] for e in pending] == ["u_1-rest"]


def test_requeue_partly_heard_does_not_stack_the_prefix(tmp_path):
    r = _registry(tmp_path)
    r.announce(id="u_1", source="cc", project_id="p", title="Partly heard · Old.", ttl_s=600)
    entry, _ = r.requeue_partly_heard("u_1", "rest")
    assert entry["title"] == "Partly heard · Old."


def test_requeue_partly_heard_refusals(tmp_path):
    r = _registry(tmp_path)
    assert r.requeue_partly_heard("nope", "rest") == (None, "not_found")
    r.announce(id="u_1", source="cc", project_id="p", title="t", ttl_s=600)
    assert r.requeue_partly_heard("u_1", "   ") == (None, "empty")
    r.mark_dismissed("u_1")
    # The user already pressed Play (or dismissed) meanwhile: no rest card.
    assert r.requeue_partly_heard("u_1", "rest") == (None, "not_pending")
    assert r.snapshot()["pending"] == []


def test_requeue_partly_heard_persists(tmp_path):
    path = tmp_path / "r.json"
    r = V2Registry(path=path)
    r.announce(id="u_1", source="cc", project_id="p", title="t", text="a b", ttl_s=600)
    r.requeue_partly_heard("u_1", "b")
    r2 = V2Registry(path=path)
    assert [e["id"] for e in r2.snapshot()["pending"]] == ["u_1-rest"]


# ---------- HTTP routes ----------

def test_announce_route_accepts_attention_fields(tmp_path):
    client, _fp, _app = make_client(registry_path=tmp_path / "r.json")
    r = client.post("/v2/registry/announce", json={
        "id": "a_1", "source": "claude-code", "project_id": "myna",
        "title": "Claude needs your permission to use Bash",
        "text": "Claude needs your permission to use Bash",
        "kind": "attention", "session_id": "s1",
        "notification_type": "permission_prompt",
        "host_bundle_id": "com.googlecode.iterm2", "ttl_s": 600,
    })
    assert r.status_code == 200
    item = client.get("/v2/registry/list").json()["pending"][0]
    assert item["kind"] == "attention"
    assert item["notification_type"] == "permission_prompt"
    assert item["session_id"] == "s1"
    assert item["host_bundle_id"] == "com.googlecode.iterm2"


def test_partly_heard_route(tmp_path):
    client, _fp, _app = make_client(registry_path=tmp_path / "r.json")
    client.post("/v2/registry/announce", json={
        "id": "u_1", "source": "claude-code", "project_id": "myna",
        "title": "Intro.", "text": "Intro.\n\nThe rest.", "ttl_s": 600,
    })
    r = client.post("/v2/registry/partly_heard/u_1", json={"text": "The rest."})
    assert r.status_code == 200
    assert r.json() == {"ok": True, "id": "u_1-rest"}
    pending = client.get("/v2/registry/list").json()["pending"]
    assert [(e["id"], e["partly_heard"], e["text"]) for e in pending] == [
        ("u_1-rest", True, "The rest.")
    ]


def test_partly_heard_route_404_and_not_pending(tmp_path):
    client, _fp, _app = make_client(registry_path=tmp_path / "r.json")
    assert client.post("/v2/registry/partly_heard/nope", json={"text": "x"}).status_code == 404
    client.post("/v2/registry/announce", json={
        "id": "u_1", "source": "claude-code", "project_id": "p", "title": "t", "ttl_s": 600,
    })
    client.post("/v2/registry/dismiss/u_1")
    r = client.post("/v2/registry/partly_heard/u_1", json={"text": "x"})
    assert r.status_code == 200
    assert r.json() == {"ok": False, "reason": "not_pending"}


def test_partly_heard_route_requires_text(tmp_path):
    client, _fp, _app = make_client(registry_path=tmp_path / "r.json")
    client.post("/v2/registry/announce", json={
        "id": "u_1", "source": "claude-code", "project_id": "p", "title": "t", "ttl_s": 600,
    })
    assert client.post("/v2/registry/partly_heard/u_1", json={}).status_code == 422
