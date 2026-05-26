import importlib.util
import io
import json
import pathlib
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
