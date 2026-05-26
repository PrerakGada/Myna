#!/usr/bin/env python3
"""Claude Code Stop hook: announce the last assistant reply to the Myna daemon.

Silent and best-effort: never blocks the session, never plays audio, and
no-ops if the daemon is unreachable.

v0.2: in addition to the legacy /announce (text payload, kept for v1
back-compat), we POST a metadata-only announcement to /v2/registry/announce
so the Swift menu-bar app can render a toast + CC submenu. Audio is
synthesized on-demand when the user clicks Play on the toast (Track A
calls /v2/registry/play/{id} which is handled by the daemon).
"""
import json
import os
import sys
import urllib.request
import uuid

PORT = os.environ.get("MYNA_PORT", "8766")
DEFAULT_TTL_S = int(os.environ.get("MYNA_CC_TTL_S", "600"))


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
    if not tpath or not os.path.exists(tpath):
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
                msg = obj.get("message") or {}
                if obj.get("type") == "assistant" or msg.get("role") == "assistant":
                    txt = _text_from_content(msg.get("content"))
                    if txt:
                        last = txt
    except Exception:
        return None
    return last


def _post_json(path: str, body: dict, *, timeout: float = 1.5) -> None:
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


def _short_id() -> str:
    return "u_" + uuid.uuid4().hex[:8]


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    text = _last_assistant_text(data.get("transcript_path"))
    if not text:
        return
    cwd = (data.get("cwd") or "").rstrip("/")
    label = os.path.basename(cwd) or "claude"
    session_id = data.get("session_id") or ""

    # v1: legacy text-payload announce (kept for back-compat — the v1
    # /announce + /play flow still works in the Hammerspoon path).
    _post_json(
        "/announce",
        {
            "session_id": session_id,
            "label": label,
            "text": text[:8000],
        },
    )

    # v2: metadata-only announce for the Swift menu-bar toast + CC submenu.
    # Daemon stores the entry with its own ttl + audio_path bookkeeping;
    # audio is synthesized lazily on /v2/registry/play/{id}.
    _post_json(
        "/v2/registry/announce",
        {
            "id": _short_id(),
            "source": "claude-code",
            "project_id": label,
            "title": text.strip().splitlines()[0][:80] if text.strip() else label,
            "ttl_s": DEFAULT_TTL_S,
        },
    )


if __name__ == "__main__":
    main()
