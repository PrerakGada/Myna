#!/usr/bin/env python3
"""Claude Code Stop hook: announce the last assistant reply to the Myna daemon.

Silent and best-effort: never blocks the session, never plays audio, and
no-ops if the daemon is unreachable.
"""
import json
import os
import sys
import urllib.request

PORT = os.environ.get("MYNA_PORT", "8766")


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
    body = json.dumps(
        {
            "session_id": data.get("session_id") or "",
            "label": label,
            "text": text[:8000],
        }
    ).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}/announce",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(req, timeout=1.5)
    except Exception:
        pass


if __name__ == "__main__":
    main()
