import importlib.util
import io
import json
import os
import pathlib
import subprocess
import sys
from unittest import mock

_HOOK = pathlib.Path(__file__).resolve().parents[2] / "hooks" / "myna-cc-announce.py"
_spec = importlib.util.spec_from_file_location("cc_hook", _HOOK)


def _load():
    mod = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(mod)
    return mod


def test_text_from_string_content():
    h = _load()
    assert h._text_from_content("plain string") == "plain string"


def test_text_from_block_list_keeps_text_only():
    h = _load()
    content = [
        {"type": "tool_use", "name": "Bash", "input": {}},
        {"type": "text", "text": "Here is the answer."},
    ]
    assert h._text_from_content(content) == "Here is the answer."


def test_last_assistant_text_from_jsonl(tmp_path):
    h = _load()
    t = tmp_path / "t.jsonl"
    t.write_text(
        '{"type":"user","message":{"role":"user","content":"hi"}}\n'
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"first reply"}]}}\n'
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"final reply"}]}}\n'
    )
    assert h._last_assistant_text(str(t)) == "final reply"


def test_last_assistant_text_missing_file_returns_none():
    h = _load()
    assert h._last_assistant_text("/no/such/file.jsonl") is None


# ---------- main() routing: v1 + v2 announce ----------

def _run_main_with_capture(h, monkeypatch, transcript_path, *, cwd="/Users/x/Developer/myna"):
    """Drive cc_hook.main() with a mocked stdin + capture urlopen requests."""
    monkeypatch.setattr(
        "sys.stdin",
        io.StringIO(
            json.dumps(
                {
                    "transcript_path": str(transcript_path),
                    "cwd": cwd,
                    "session_id": "sess-42",
                }
            )
        ),
    )
    calls = []

    class _FakeResp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b"{}"

    def fake_urlopen(req, timeout=None):
        body = req.data.decode() if req.data else ""
        calls.append({"url": req.full_url, "body": json.loads(body) if body else None})
        return _FakeResp()

    with mock.patch.object(h.urllib.request, "urlopen", side_effect=fake_urlopen):
        h.main()
    return calls


def test_main_posts_both_v1_and_v2_announce(tmp_path, monkeypatch):
    h = _load()
    t = tmp_path / "t.jsonl"
    t.write_text(
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"Hello from the agent."}]}}\n'
    )
    calls = _run_main_with_capture(h, monkeypatch, t)
    urls = [c["url"] for c in calls]
    assert any(u.endswith("/announce") and not u.endswith("/v2/registry/announce") for u in urls)
    assert any(u.endswith("/v2/registry/announce") for u in urls)


def test_main_v2_announce_body_shape(tmp_path, monkeypatch):
    h = _load()
    t = tmp_path / "t.jsonl"
    t.write_text(
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"Multi line.\\nSecond line."}]}}\n'
    )
    calls = _run_main_with_capture(h, monkeypatch, t)
    v2 = next(c for c in calls if c["url"].endswith("/v2/registry/announce"))
    body = v2["body"]
    assert body["source"] == "claude-code"
    assert body["project_id"] == "myna"
    # Title is the first non-empty line, truncated to 80 chars.
    assert body["title"] == "Multi line."
    # ...but `text` carries the FULL reply so Play reads the whole output,
    # not just the first line. (Regression guard for the "first sentence
    # only" bug.)
    assert body["text"] == "Multi line.\nSecond line."
    assert body["ttl_s"] == 600
    assert body["id"].startswith("u_")


def test_main_swallows_connection_error(tmp_path, monkeypatch, capsys):
    h = _load()
    t = tmp_path / "t.jsonl"
    t.write_text(
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"hi"}]}}\n'
    )
    monkeypatch.setattr(
        "sys.stdin",
        io.StringIO(
            json.dumps({"transcript_path": str(t), "cwd": "/p", "session_id": "s"})
        ),
    )

    def boom(*a, **kw):
        raise ConnectionRefusedError("daemon down")

    with mock.patch.object(h.urllib.request, "urlopen", side_effect=boom):
        # Must not raise. Stderr gets a warning per call.
        h.main()
    err = capsys.readouterr().err
    assert "daemon unreachable" in err


# ---------- Claude Code hands-free: event routing + payload mapping ----------
#
# Sample payloads follow https://code.claude.com/docs/en/hooks (Sep 2026).

STOP_PAYLOAD = {
    "session_id": "sess-42",
    "transcript_path": "/no/such/transcript.jsonl",
    "cwd": "/Users/x/Developer/myna",
    "permission_mode": "default",
    "hook_event_name": "Stop",
    "stop_hook_active": True,
    "last_assistant_message": "Done. The build is green.\n\nTwo tests were flaky.",
}

PERMISSION_PAYLOAD = {
    "session_id": "sess-42",
    "transcript_path": "/no/such/transcript.jsonl",
    "cwd": "/Users/x/Developer/Gala-ERP",
    "permission_mode": "default",
    "hook_event_name": "Notification",
    "notification_type": "permission_prompt",
    "message": "Claude needs your permission to use Bash",
}

IDLE_PAYLOAD = {
    "session_id": "sess-7",
    "transcript_path": "/no/such/transcript.jsonl",
    "cwd": "/Users/x/Developer/myna/",
    "hook_event_name": "Notification",
    "notification_type": "idle_prompt",
    "message": "Claude is waiting for your input",
}


def _drive(h, monkeypatch, payload_text):
    monkeypatch.setattr("sys.stdin", io.StringIO(payload_text))
    calls = []

    def fake_urlopen(req, timeout=None):
        body = req.data.decode() if req.data else ""
        calls.append({"url": req.full_url, "body": json.loads(body) if body else None,
                      "timeout": timeout})
        return None

    with mock.patch.object(h.urllib.request, "urlopen", side_effect=fake_urlopen):
        h.main()
    return calls


def test_stop_prefers_last_assistant_message_over_transcript(tmp_path, monkeypatch):
    h = _load()
    t = tmp_path / "t.jsonl"
    t.write_text(
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"stale reply from the lagging transcript"}]}}\n'
    )
    payload = dict(STOP_PAYLOAD, transcript_path=str(t))
    monkeypatch.setenv("__CFBundleIdentifier", "com.googlecode.iterm2")
    calls = _drive(h, monkeypatch, json.dumps(payload))
    v2 = next(c for c in calls if c["url"].endswith("/v2/registry/announce"))
    body = v2["body"]
    assert body["text"] == STOP_PAYLOAD["last_assistant_message"]
    assert body["title"] == "Done. The build is green."
    assert body["kind"] == "reply"
    assert body["session_id"] == "sess-42"
    assert body["host_bundle_id"] == "com.googlecode.iterm2"
    assert body["project_id"] == "myna"
    assert body["id"].startswith("u_")
    # Every POST is time-boxed.
    assert all(c["timeout"] is not None and c["timeout"] <= 2 for c in calls)


def test_stop_without_event_name_still_announces(tmp_path, monkeypatch):
    """An older Claude Code sends no hook_event_name; it only ran us on Stop."""
    h = _load()
    t = tmp_path / "t.jsonl"
    t.write_text(
        '{"type":"assistant","message":{"role":"assistant","content":'
        '[{"type":"text","text":"old style"}]}}\n'
    )
    calls = _drive(h, monkeypatch, json.dumps({"transcript_path": str(t), "cwd": "/p"}))
    assert any(c["url"].endswith("/v2/registry/announce") for c in calls)


def test_permission_prompt_maps_to_attention_request(monkeypatch):
    h = _load()
    monkeypatch.setenv("__CFBundleIdentifier", "com.apple.Terminal")
    calls = _drive(h, monkeypatch, json.dumps(PERMISSION_PAYLOAD))
    # Only the v2 registry: attention never goes to the legacy /announce.
    assert [c["url"] for c in calls] == ["http://127.0.0.1:8766/v2/registry/announce"]
    body = calls[0]["body"]
    assert body["kind"] == "attention"
    assert body["notification_type"] == "permission_prompt"
    assert body["project_id"] == "Gala-ERP"
    assert body["title"] == "Claude needs your permission to use Bash"
    assert body["text"] == "Claude needs your permission to use Bash"
    assert body["session_id"] == "sess-42"
    assert body["host_bundle_id"] == "com.apple.Terminal"
    assert body["id"].startswith("a_")
    assert body["ttl_s"] == 600


def test_idle_prompt_maps_to_attention_request(monkeypatch):
    h = _load()
    calls = _drive(h, monkeypatch, json.dumps(IDLE_PAYLOAD))
    body = calls[0]["body"]
    assert body["notification_type"] == "idle_prompt"
    assert body["project_id"] == "myna"  # trailing slash on cwd stripped
    assert body["session_id"] == "sess-7"


def test_notifications_that_are_not_needs_you_are_ignored(monkeypatch):
    h = _load()
    for ntype in ("auth_success", "agent_completed", "elicitation_complete",
                  "quota_auto_resume_fired", "something_new"):
        payload = dict(PERMISSION_PAYLOAD, notification_type=ntype, message="whatever")
        assert _drive(h, monkeypatch, json.dumps(payload)) == []


def test_notification_without_type_is_classified_from_message(monkeypatch):
    """Claude Code before notification_type existed only sent a message."""
    h = _load()
    legacy = {k: v for k, v in PERMISSION_PAYLOAD.items() if k != "notification_type"}
    body = _drive(h, monkeypatch, json.dumps(legacy))[0]["body"]
    assert body["notification_type"] == "permission_prompt"
    legacy_idle = {k: v for k, v in IDLE_PAYLOAD.items() if k != "notification_type"}
    body = _drive(h, monkeypatch, json.dumps(legacy_idle))[0]["body"]
    assert body["notification_type"] == "idle_prompt"
    unknown = dict(legacy, message="Something happened")
    assert _drive(h, monkeypatch, json.dumps(unknown)) == []


def test_other_hook_events_are_ignored(monkeypatch):
    h = _load()
    payload = dict(PERMISSION_PAYLOAD, hook_event_name="PreToolUse")
    assert _drive(h, monkeypatch, json.dumps(payload)) == []


def test_malformed_input_posts_nothing_and_does_not_raise(monkeypatch):
    h = _load()
    for raw in ("", "not json", "[1, 2, 3]", "null", '"a string"',
                json.dumps({"hook_event_name": "Notification", "message": 42,
                            "notification_type": ["permission_prompt"], "cwd": 7}),
                json.dumps({"hook_event_name": "Stop", "transcript_path": 12})):
        assert _drive(h, monkeypatch, raw) == []


def test_host_bundle_id_falls_back_to_term_program():
    h = _load()
    assert h._host_bundle_id({"__CFBundleIdentifier": "com.mitchellh.ghostty"}) == "com.mitchellh.ghostty"
    assert h._host_bundle_id({"TERM_PROGRAM": "iTerm.app"}) == "com.googlecode.iterm2"
    assert h._host_bundle_id({"TERM_PROGRAM": "tmux"}) is None
    assert h._host_bundle_id({}) is None


def test_script_always_exits_zero_even_with_daemon_down():
    """Run the real script as Claude Code does, against a port nothing
    listens on: it must exit 0 quickly whatever it is fed."""
    env = dict(os.environ, MYNA_PORT="9")  # discard port; connection refused
    for raw in (json.dumps(PERMISSION_PAYLOAD), json.dumps(STOP_PAYLOAD), "garbage", ""):
        proc = subprocess.run(
            [sys.executable, str(_HOOK)], input=raw, text=True,
            capture_output=True, env=env, timeout=10,
        )
        assert proc.returncode == 0, proc.stderr
