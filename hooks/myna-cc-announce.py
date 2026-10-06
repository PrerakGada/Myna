#!/usr/bin/env python3
"""Claude Code hook: tell the Myna daemon when a session replies or needs you.

One script for both events Myna listens to, keyed on `hook_event_name`:

  Stop          the last assistant reply → a "reply" registry entry. The app
                shows it in the pill or a card and plays it on click (or,
                with hands-free on, reads it while you're away).
  Notification  Claude Code asking for you (a permission prompt, an idle
                prompt, an MCP question) → an "attention" registry entry.
                The app decides whether to say it aloud.

One script rather than a sibling: setup installs, bundles and registers a
single file, and an installed copy can never be half-updated (a new
Notification hook next to an old Stop hook).

Silent and best-effort: never plays audio, never blocks the session, always
exits 0, and gives up quickly if the daemon is unreachable. Stdlib only — it
runs on every Claude Code turn. The spoken wording is built app-side, so
changing it never needs this installed copy replaced.
"""
import json
import os
import sys
import urllib.request
import uuid

PORT = os.environ.get("MYNA_PORT", "8766")
DEFAULT_TTL_S = int(os.environ.get("MYNA_CC_TTL_S", "600"))
POST_TIMEOUT_S = 1.5

# Notification types that mean "a person is needed". The rest (auth_success,
# agent_completed, elicitation_complete, quota_*, …) are not worth a card.
NEEDS_YOU_TYPES = frozenset({
    "permission_prompt",
    "idle_prompt",
    "elicitation_dialog",
    "elicitation_url_dialog",
    "agent_needs_input",
})

# TERM_PROGRAM → bundle id, for terminals launched without LaunchServices
# (so without __CFBundleIdentifier in their environment).
_TERM_PROGRAM_BUNDLES = {
    "iTerm.app": "com.googlecode.iterm2",
    "Apple_Terminal": "com.apple.Terminal",
    "ghostty": "com.mitchellh.ghostty",
    "WezTerm": "com.github.wez.wezterm",
    "vscode": "com.microsoft.VSCode",
}


def _text_from_content(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text"
        ]
        joined = "\n".join(p for p in parts if p).strip()
        return joined or None
    return None


def _last_assistant_text(tpath):
    if not tpath or not isinstance(tpath, str) or not os.path.exists(tpath):
        return None
    last = None
    try:
        with open(tpath) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue
                msg = obj.get("message") or {}
                if not isinstance(msg, dict):
                    continue
                if obj.get("type") == "assistant" or msg.get("role") == "assistant":
                    txt = _text_from_content(msg.get("content"))
                    if txt:
                        last = txt
    except Exception:
        return None
    return last


def _reply_text(data):
    """The reply to announce. Claude Code 2.1.196+ hands it over directly as
    `last_assistant_message`; the transcript can lag behind it, so it's only
    the fallback for older versions."""
    direct = data.get("last_assistant_message")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()
    return _last_assistant_text(data.get("transcript_path"))


def _post_json(path: str, body: dict, *, timeout: float = POST_TIMEOUT_S) -> None:
    """Best-effort POST. Swallow connection errors so the hook never
    breaks the user's Claude Code session.
    """
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=timeout)
    except Exception as exc:
        # Log to stderr so the hook is debuggable without crashing the CC
        # session. CC captures hook stderr.
        sys.stderr.write(f"myna-cc-announce: daemon unreachable ({exc})\n")


def _short_id(prefix: str = "u_") -> str:
    return prefix + uuid.uuid4().hex[:8]


def _str_field(data, key):
    value = data.get(key)
    return value if isinstance(value, str) else ""


def _project_label(data) -> str:
    cwd = _str_field(data, "cwd").rstrip("/")
    return os.path.basename(cwd) or "claude"


def _host_bundle_id(environ=None):
    """Bundle id of the app this session runs in (iTerm, Terminal, VS Code…).

    macOS puts `__CFBundleIdentifier` in the environment of anything an app
    launches, and Claude Code passes its environment to hooks. The app uses
    it only for the optional "Claude Code's window isn't in front" signal.
    """
    env = os.environ if environ is None else environ
    bundle = env.get("__CFBundleIdentifier")
    if bundle:
        return bundle[:255]
    return _TERM_PROGRAM_BUNDLES.get(env.get("TERM_PROGRAM", ""))


def _needs_you_type(data):
    """The notification type if it means "a person is needed", else None.

    Claude Code before `notification_type` existed sent only a message
    ("Claude needs your permission to use Bash", "Claude is waiting for your
    input"), so fall back to reading that.
    """
    ntype = data.get("notification_type")
    if isinstance(ntype, str) and ntype:
        return ntype if ntype in NEEDS_YOU_TYPES else None
    message = _str_field(data, "message").lower()
    if "permission" in message:
        return "permission_prompt"
    if "waiting for your input" in message:
        return "idle_prompt"
    return None


def reply_request(data, text, *, host_bundle_id=None):
    """The /v2/registry/announce body for a finished reply."""
    body = {
        "id": _short_id("u_"),
        "source": "claude-code",
        "kind": "reply",
        "project_id": _project_label(data),
        # `title` is the first-line preview the toast and pill show; `text`
        # is the whole reply, so Play reads all of it and not just the
        # opening sentence.
        "title": text.strip().splitlines()[0][:80] if text.strip() else _project_label(data),
        "text": text[:8000],
        "ttl_s": DEFAULT_TTL_S,
    }
    session_id = _str_field(data, "session_id")
    if session_id:
        body["session_id"] = session_id
    if host_bundle_id:
        body["host_bundle_id"] = host_bundle_id
    return body


def attention_request(data, *, host_bundle_id=None):
    """The /v2/registry/announce body for a "needs you" notification, or
    None when the notification isn't one Myna should surface."""
    ntype = _needs_you_type(data)
    if ntype is None:
        return None
    message = " ".join(_str_field(data, "message").split())
    if not message:
        message = "Claude Code needs you"
    body = {
        "id": _short_id("a_"),
        "source": "claude-code",
        "kind": "attention",
        "notification_type": ntype,
        "project_id": _project_label(data),
        "title": message[:80],
        "text": message[:500],
        "ttl_s": DEFAULT_TTL_S,
    }
    session_id = _str_field(data, "session_id")
    if session_id:
        body["session_id"] = session_id
    if host_bundle_id:
        body["host_bundle_id"] = host_bundle_id
    return body


def _handle_stop(data):
    text = _reply_text(data)
    if not text:
        return
    label = _project_label(data)
    # v1: legacy text-payload announce (kept for back-compat — the v1
    # /announce + /play flow still works in the Hammerspoon path).
    _post_json(
        "/announce",
        {
            "session_id": _str_field(data, "session_id"),
            "label": label,
            "text": text[:8000],
        },
    )
    # v2: the Swift app's pill, toast and popover card. The daemon stores
    # the entry; audio is synthesized only when it's played.
    _post_json(
        "/v2/registry/announce",
        reply_request(data, text, host_bundle_id=_host_bundle_id()),
    )


def _handle_notification(data):
    body = attention_request(data, host_bundle_id=_host_bundle_id())
    if body is not None:
        _post_json("/v2/registry/announce", body)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if not isinstance(data, dict):
        return
    event = data.get("hook_event_name")
    if event == "Notification":
        _handle_notification(data)
    elif event in (None, "", "Stop"):
        # No event name: an older Claude Code, which only ever ran this
        # script as the Stop hook.
        _handle_stop(data)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # never fail the Claude Code session
        sys.stderr.write(f"myna-cc-announce: {exc}\n")
    sys.exit(0)
