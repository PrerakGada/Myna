import importlib.util
import pathlib

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
