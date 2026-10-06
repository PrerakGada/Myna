"""dist/setup.sh's Claude Code hook registration, run for real on a scratch HOME.

The block that edits ~/.claude/settings.json is Python inside a heredoc. These
tests lift it out of setup.sh verbatim and run it with HOME pointed at a temp
dir, so they exercise exactly what ships and never touch the real settings.
"""

import json
import os
import pathlib
import subprocess
import sys

import pytest

_SETUP = pathlib.Path(__file__).resolve().parents[2] / "dist" / "setup.sh"
_BUNDLED = pathlib.Path(__file__).resolve().parents[2] / "apps" / "macos" / "Resources" / "setup" / "setup.sh"

CMD = '"/h/.venvs/mlx-audio/bin/python" "/h/.config/myna/hooks/myna-cc-announce.py"'


def _merge_script() -> str:
    lines = _SETUP.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if 'HOOK_CMD="$HOOK_CMD"' in line and "<<'PY'" in line)
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "PY")
    return "\n".join(lines[start + 1:end]) + "\n"


def _run(home: pathlib.Path, cmd: str = CMD):
    env = dict(os.environ, HOME=str(home), HOOK="/h/hook.py", HOOK_CMD=cmd)
    return subprocess.run(
        [sys.executable, "-"], input=_merge_script(), text=True,
        capture_output=True, env=env, timeout=20,
    )


def _settings(home):
    return json.loads((home / ".claude" / "settings.json").read_text())


def _myna_commands(settings, event):
    found = []
    for group in settings["hooks"].get(event, []):
        entries = group.get("hooks") if isinstance(group, dict) else None
        for h in entries if isinstance(entries, list) else []:
            if isinstance(h, dict) and "myna-cc-announce.py" in str(h.get("command")):
                found.append(h["command"])
    return found


@pytest.fixture
def home(tmp_path):
    (tmp_path / ".claude").mkdir()
    return tmp_path


def test_bundled_setup_copy_matches_dist():
    """apps/macos/Resources/setup/setup.sh is tracked; it must not drift."""
    assert _BUNDLED.read_text() == _SETUP.read_text()


def test_fresh_settings_get_stop_and_notification(home):
    proc = _run(home)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    s = _settings(home)
    assert _myna_commands(s, "Stop") == [CMD]
    assert _myna_commands(s, "Notification") == [CMD]


def test_rerun_never_duplicates(home):
    for _ in range(3):
        assert _run(home).returncode == 0
    s = _settings(home)
    assert _myna_commands(s, "Stop") == [CMD]
    assert _myna_commands(s, "Notification") == [CMD]


def test_upgrade_from_stop_only_keeps_user_hooks_and_fixes_stale_command(home):
    (home / ".claude" / "settings.json").write_text(json.dumps({
        "model": "opus",
        "hooks": {
            "Stop": [
                {"hooks": [{"type": "command", "command": "python3 /old/path/myna-cc-announce.py"}]},
                {"hooks": [{"type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff"}]},
            ],
            "Notification": [
                {"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "terminal-notifier"}]},
            ],
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}],
        },
    }))
    assert _run(home).returncode == 0
    s = _settings(home)
    assert s["model"] == "opus"
    assert _myna_commands(s, "Stop") == [CMD]  # rewritten in place, not added
    assert len(s["hooks"]["Stop"]) == 2
    assert s["hooks"]["Stop"][1]["hooks"][0]["command"].startswith("afplay")
    assert _myna_commands(s, "Notification") == [CMD]
    assert s["hooks"]["Notification"][0]["hooks"][0]["command"] == "terminal-notifier"
    assert s["hooks"]["PreToolUse"][0]["hooks"][0]["command"] == "guard.sh"


def test_invalid_json_is_left_untouched(home):
    path = home / ".claude" / "settings.json"
    path.write_text("{ not json")
    proc = _run(home)
    assert proc.returncode == 1
    assert path.read_text() == "{ not json"


def test_unexpected_hooks_shape_is_left_untouched(home):
    path = home / ".claude" / "settings.json"
    for raw in ('{"hooks": ["weird"]}', '{"hooks": {"Notification": {"x": 1}}}'):
        path.write_text(raw)
        proc = _run(home)
        assert proc.returncode == 1, raw
        assert path.read_text() == raw


def test_odd_group_entries_are_skipped_not_crashed_on(home):
    (home / ".claude" / "settings.json").write_text(json.dumps({
        "hooks": {"Stop": ["junk", {"hooks": "nope"}, {"hooks": [42, {"command": None}]}]},
    }))
    proc = _run(home)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    s = _settings(home)
    assert _myna_commands(s, "Stop") == [CMD]
    assert _myna_commands(s, "Notification") == [CMD]
