"""V2 registry — Claude Code Stop-hook announcements with persistence.

Distinct from the v1 `myna.registry.Registry`:
  - v1 stores raw text for the legacy /announce → /play flow.
  - v2 stores Stop-hook metadata (project_id, title, ttl) for the toast UI;
    audio is referenced by id and re-synthesized on /play/{id}.

Persistence target: ~/.cache/myna/registry.json (JSON list of dicts).
Survives daemon restart. Concurrent-access-safe within a single process
(FastAPI's worker model) — no cross-process locking; if this changes,
add fcntl.

Schema (see docs/v0.2-plan/01-feature-stories.md S08):

    {
        "id":               str,
        "source":           "claude-code" | other,
        "project_id":       str,
        "title":            str,           # first 80 chars of agent reply
        "announced_at_ms":  int,           # wall-clock unix ms
        "ttl_s":            int,
        "played_at_ms":     int | None,
        "dismissed_at_ms":  int | None,
    }

Note: an earlier draft included an `audio_path` field carried from the
hook. It was removed (post-audit, v0.2 security fix lane): the field was
unauthenticated user input that the dismiss handler passed to
`Path(...).unlink()`, an arbitrary-file-delete primitive. v0.2 has no
caller that writes audio for the CC hook — playback is synthesised
on-demand from `title` via /v2/registry/play/{id}.

`pending` filter: not dismissed, not played, and not yet TTL-expired.
`played` filter: played_at_ms != None, capped at last 5 by played_at_ms desc.

Claude Code hands-free (Sep 2026) adds optional fields, all defaulted so
entries persisted before them still load:

    "kind":              "reply" | "attention",   # default "reply"
    "session_id":        str | None,   # Claude Code session, from the hook
    "notification_type": str | None,   # attention only: permission_prompt, …
    "host_bundle_id":    str | None,   # app the session runs in (iTerm, …)
    "partly_heard":      bool,         # the unheard rest of an auto-read

An "attention" entry is Claude Code's Notification hook saying a session
needs the user (a permission prompt, an idle prompt). Two rules keep those
from going stale, both keyed on session_id:
  * a newer attention entry for a session replaces its older pending one;
  * a reply from a session dismisses its pending attention entries, since a
    session that has replied has already been answered.

`requeue_partly_heard` backs the app's auto-read: when the user comes back
mid-read, the app stops at a passage boundary and hands the unheard rest
back here. It becomes a fresh pending entry (a new id, so the pill and toast
present it again) and the original is dismissed.
"""

from __future__ import annotations

import json
import pathlib
import threading
import time
from typing import Optional


DEFAULT_REGISTRY_PATH = (
    pathlib.Path.home() / ".cache" / "myna" / "registry.json"
)


def _now_ms() -> int:
    return int(time.time() * 1000)


KIND_REPLY = "reply"
KIND_ATTENTION = "attention"
PARTLY_HEARD_PREFIX = "Partly heard · "


def _clip(value: Optional[str], limit: int) -> Optional[str]:
    if not value:
        return None
    return str(value)[:limit]


class V2Registry:
    """In-memory list + JSON file mirror."""

    def __init__(
        self,
        path: Optional[pathlib.Path] = None,
        *,
        clock=_now_ms,
        played_cap: int = 5,
    ):
        self.path = path or DEFAULT_REGISTRY_PATH
        self._clock = clock
        self._played_cap = played_cap
        self._entries: list[dict] = []
        # FastAPI's sync route handlers run in a threadpool; concurrent
        # /v2/registry/{announce,play,dismiss,delete} calls can interleave
        # their read-modify-write of self._entries and racing _save() can
        # leave registry.json half-written. Serialize the entire mutator
        # sequence (including the disk write) under this lock.
        self._lock = threading.Lock()
        self._load()

    # -------- persistence --------

    def _load(self) -> None:
        try:
            raw = self.path.read_text()
        except FileNotFoundError:
            self._entries = []
            return
        except OSError:
            self._entries = []
            return
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            # Corrupt file — start clean; original is overwritten on next save.
            self._entries = []
            return
        if not isinstance(data, list):
            self._entries = []
            return
        # Defensive: keep only entries with the required keys
        cleaned = []
        for e in data:
            if not isinstance(e, dict):
                continue
            if "id" not in e or "announced_at_ms" not in e:
                continue
            cleaned.append(e)
        self._entries = cleaned

    def _save(self) -> None:
        # Caller must hold self._lock. We snapshot self._entries into JSON
        # while no other mutator can change it, then write-then-replace
        # atomically. (.replace() is POSIX atomic; the lock just protects
        # the in-memory list from concurrent mutation while we serialize.)
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            tmp.write_text(json.dumps(self._entries))
            tmp.replace(self.path)
        except OSError:
            # Persistence is best-effort; don't crash the daemon on disk full.
            pass

    # -------- mutation --------

    def announce(
        self,
        *,
        id: str,
        source: str,
        project_id: str,
        title: str,
        ttl_s: int,
        text: Optional[str] = None,
        kind: Optional[str] = None,
        session_id: Optional[str] = None,
        notification_type: Optional[str] = None,
        host_bundle_id: Optional[str] = None,
        partly_heard: bool = False,
    ) -> dict:
        # Unknown kinds from a newer hook are stored as replies rather than
        # rejected: showing a card beats losing the announcement.
        kind = KIND_ATTENTION if kind == KIND_ATTENTION else KIND_REPLY
        session_id = _clip(session_id, 128)
        with self._lock:
            now = self._clock()
            # Replace any existing entry with the same id (latest write wins).
            self._entries = [e for e in self._entries if e.get("id") != id]
            if session_id:
                self._supersede_attention(session_id, now, drop=kind == KIND_ATTENTION)
            entry = {
                "id": id,
                "source": source,
                "project_id": project_id,
                "title": title[:200],
                # Full reply body for /play (capped to keep registry.json
                # bounded). None when the caller didn't supply it — /play
                # then falls back to `title`.
                "text": (text[:8000] if text else None),
                "announced_at_ms": now,
                "ttl_s": int(ttl_s),
                "played_at_ms": None,
                "dismissed_at_ms": None,
                "kind": kind,
                "session_id": session_id,
                "notification_type": (
                    _clip(notification_type, 64) if kind == KIND_ATTENTION else None
                ),
                "host_bundle_id": _clip(host_bundle_id, 255),
                "partly_heard": bool(partly_heard),
            }
            self._entries.append(entry)
            self._save()
            return entry

    def _supersede_attention(self, session_id: str, now: int, *, drop: bool) -> None:
        """Retire this session's pending attention entries. Caller holds the lock.

        `drop` (a newer alert arriving) removes them outright so the list
        holds one alert per session; a reply only dismisses them, which
        keeps the record but takes them off the pending list.
        """
        kept = []
        for e in self._entries:
            is_stale_alert = (
                e.get("kind") == KIND_ATTENTION
                and e.get("session_id") == session_id
                and e.get("dismissed_at_ms") is None
                and e.get("played_at_ms") is None
            )
            if is_stale_alert and drop:
                continue
            if is_stale_alert:
                e["dismissed_at_ms"] = now
            kept.append(e)
        self._entries = kept

    def requeue_partly_heard(self, entry_id: str, remaining_text: str) -> tuple[Optional[dict], str]:
        """Swap a partly auto-read reply for a fresh entry holding the unheard rest.

        Returns (new_entry, "ok"), or (None, reason) where reason is
        "not_found", "not_pending" (already played or dismissed, e.g. the
        user pressed Play on it meanwhile) or "empty" (nothing left to hear).
        """
        rest = (remaining_text or "").strip()
        if not rest:
            return None, "empty"
        with self._lock:
            now = self._clock()
            old = next((e for e in self._entries if e.get("id") == entry_id), None)
            if old is None:
                return None, "not_found"
            if old.get("dismissed_at_ms") is not None or old.get("played_at_ms") is not None:
                return None, "not_pending"
            old["dismissed_at_ms"] = now
            new_id = f"{entry_id}-rest"
            self._entries = [e for e in self._entries if e.get("id") != new_id]
            base_title = str(old.get("title") or "")
            if base_title.startswith(PARTLY_HEARD_PREFIX):
                base_title = base_title[len(PARTLY_HEARD_PREFIX):]
            entry = {
                "id": new_id,
                "source": old.get("source") or "claude-code",
                "project_id": old.get("project_id") or "claude",
                # The title is what every surface (pill, toast, popover card)
                # shows, so the mark rides on it and no view has to change.
                "title": (PARTLY_HEARD_PREFIX + base_title)[:200],
                "text": rest[:8000],
                "announced_at_ms": now,
                "ttl_s": int(old.get("ttl_s") or 600),
                "played_at_ms": None,
                "dismissed_at_ms": None,
                "kind": KIND_REPLY,
                "session_id": old.get("session_id"),
                "notification_type": None,
                "host_bundle_id": old.get("host_bundle_id"),
                "partly_heard": True,
            }
            self._entries.append(entry)
            self._save()
            return dict(entry), "ok"

    def mark_played(self, entry_id: str) -> Optional[dict]:
        with self._lock:
            for e in self._entries:
                if e.get("id") == entry_id:
                    e["played_at_ms"] = self._clock()
                    self._save()
                    return dict(e)
            return None

    def mark_dismissed(self, entry_id: str) -> Optional[dict]:
        with self._lock:
            for e in self._entries:
                if e.get("id") == entry_id:
                    e["dismissed_at_ms"] = self._clock()
                    self._save()
                    return dict(e)
            return None

    def delete(self, entry_id: str) -> bool:
        with self._lock:
            before = len(self._entries)
            self._entries = [e for e in self._entries if e.get("id") != entry_id]
            if len(self._entries) != before:
                self._save()
                return True
            return False

    def get(self, entry_id: str) -> Optional[dict]:
        with self._lock:
            for e in self._entries:
                if e.get("id") == entry_id:
                    return dict(e)
            return None

    # -------- queries --------

    def _is_pending(self, e: dict, now_ms: int) -> bool:
        if e.get("dismissed_at_ms") is not None:
            return False
        if e.get("played_at_ms") is not None:
            return False
        announced = e.get("announced_at_ms") or 0
        ttl_ms = (e.get("ttl_s") or 0) * 1000
        if announced + ttl_ms < now_ms:
            return False
        return True

    def snapshot(self) -> dict:
        # Take the lock for read-side too: a concurrent mutator could be
        # mid-`self._entries = [...]` reassignment and we'd otherwise see
        # a torn view (mutators rebuild the list rather than mutating in
        # place for the dismiss/delete codepaths).
        with self._lock:
            now_ms = self._clock()
            pending = [
                dict(e) for e in self._entries if self._is_pending(e, now_ms)
            ]
            played_src = [
                dict(e)
                for e in self._entries
                if e.get("played_at_ms") is not None
            ]
        # Sort pending oldest-first so UI can render in announce order
        pending.sort(key=lambda e: e["announced_at_ms"])
        played_src.sort(key=lambda e: e["played_at_ms"] or 0, reverse=True)
        played = played_src[: self._played_cap]
        return {"pending": pending, "played": played}
