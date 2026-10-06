"""Pronunciations: words the voice should say differently, as respellings.

An entry maps a word or phrase to a respelling in plain letters ("kubectl"
→ "cube control"). Respellings work on every engine; none of them take
phonemes the same way, so there is no IPA here. Two lists feed one
matcher:

* the user's own entries, and
* the starter list (myna.pronunciation_lexicon), which the user can switch
  off as a whole or entry by entry. A user entry for the same word wins.

Matching is case-insensitive and whole-word: an entry for "SQL" never
touches "SQLite" (unless "SQLite" has its own entry), and punctuation next
to a word ("kubectl,", "(JSON)", "Myna's") doesn't stop it. Longer entries
win where they overlap ("PostgreSQL" before "Postgres"). Replacement is
one regex pass, so a respelling is never matched again in the same call.

This is the substitution stage of myna.speakable: it runs after cleanup,
on every read, summary and render, and on POST /v2/speakable so History's
"As heard" shows the respellings. It also runs under `prep: literal`:
literal is about which text is read (markdown and all), a pronunciation
about how a word sounds, and someone reading a Claude Code reply as
written still wants "kubectl" said properly.

Storage: `~/.config/myna/pronunciations.json`, owned by the daemon, like
the voice wardrobe. Only the daemon the app talks to (`python -m myna`)
uses that file; a dev or test instance keeps its entries in memory, so it
can never rewrite the user's list.
"""

from __future__ import annotations

import json
import os
import re
import secrets
import tempfile
import threading
from pathlib import Path
from typing import Iterable, Optional

from .pronunciation_lexicon import STARTER

VERSION = 1
MAX_WORD = 80
MAX_SAY = 200
_ID_RE = re.compile(r"^p_[0-9a-f]{8}$")
_WS_RE = re.compile(r"\s+")


def default_path() -> Path:
    return Path(os.path.expanduser("~/.config/myna/pronunciations.json"))


def normalize(word: str) -> str:
    """The key a word matches under: case-folded, inner whitespace single."""
    return _WS_RE.sub(" ", (word or "").strip()).casefold()


def starter_id(word: str) -> str:
    """A starter entry's stable id: its word, lower-case, non-alphanumerics
    as dashes ("IPv4" → "ipv4", "cURL" → "curl")."""
    return re.sub(r"[^a-z0-9]+", "-", word.casefold()).strip("-")


class PronunciationError(ValueError):
    def __init__(self, reason: str, detail: str):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


def _clean_word(word: Optional[str]) -> str:
    word = _WS_RE.sub(" ", (word or "").strip())
    if not word:
        raise PronunciationError("invalid_word", "Enter the word or phrase to change.")
    if len(word) > MAX_WORD:
        raise PronunciationError("invalid_word", f"Keep the word under {MAX_WORD} characters.")
    if not any(ch.isalnum() for ch in word):
        raise PronunciationError("invalid_word", "The word needs at least one letter or digit.")
    return word


def _clean_say(say: Optional[str]) -> str:
    say = _WS_RE.sub(" ", (say or "").strip())
    if not say:
        raise PronunciationError("invalid_say", "Enter how the word should be said.")
    if len(say) > MAX_SAY:
        raise PronunciationError("invalid_say", f"Keep the respelling under {MAX_SAY} characters.")
    return say


# ----- matching


class Matcher:
    """One compiled pass over text. `pairs` are (word, say) in priority
    order: for the same word, the first wins."""

    def __init__(self, pairs: Iterable[tuple[str, str]]):
        self._table: dict[str, str] = {}
        for word, say in pairs:
            key = normalize(word)
            if key and key not in self._table:
                self._table[key] = say
        if not self._table:
            self._re = None
            return
        # Longest first, so the regex tries "PostgreSQL" before "Postgres".
        alternatives = [
            r"\s+".join(re.escape(part) for part in key.split(" "))
            for key in sorted(self._table, key=lambda k: (-len(k), k))
        ]
        # A word boundary, counting + and # as part of a word so "C++"
        # never matches inside "C+++".
        self._re = re.compile(r"(?<![\w+#])(?:" + "|".join(alternatives) + r")(?![\w+#])", re.IGNORECASE)

    def __call__(self, text: str) -> str:
        if self._re is None or not text:
            return text
        return self._re.sub(lambda m: self._table[normalize(m.group(0))], text)

    def __len__(self) -> int:
        return len(self._table)


# ----- the store


class PronunciationStore:
    """The user's entries and starter-list switches, in memory, written
    through to `path` (atomically) when there is one."""

    def __init__(self, path: Optional[Path] = None, *, starter: Iterable[dict] = STARTER):
        self._path = Path(path) if path is not None else None
        self._lock = threading.Lock()
        self._starter = [dict(e, id=starter_id(e["word"])) for e in starter]
        self._entries: list[dict] = []
        self._starter_enabled = True
        self._starter_off: set[str] = set()
        self._matcher: Optional[Matcher] = None
        self._load()

    # ----- persistence

    def _load(self) -> None:
        if self._path is None or not self._path.exists():
            return
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return  # a damaged file is a soft failure: start from the starter list
        if not isinstance(data, dict) or data.get("version") != VERSION:
            return
        self._starter_enabled = bool(data.get("starter_enabled", True))
        self._starter_off = {str(s) for s in data.get("starter_off") or [] if isinstance(s, str)}
        for raw in data.get("entries") or []:
            try:
                entry = {
                    "id": raw["id"] if _ID_RE.match(str(raw.get("id", ""))) else self._new_id(),
                    "word": _clean_word(raw.get("word")),
                    "say": _clean_say(raw.get("say")),
                    "enabled": bool(raw.get("enabled", True)),
                }
            except (PronunciationError, KeyError, TypeError, AttributeError):
                continue
            self._entries.append(entry)

    def _save(self) -> None:
        self._matcher = None
        if self._path is None:
            return
        payload = {
            "version": VERSION,
            "starter_enabled": self._starter_enabled,
            "starter_off": sorted(self._starter_off),
            "entries": self._entries,
        }
        self._path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(self._path.parent), prefix=".pronunciations-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, indent=1, ensure_ascii=False)
                f.write("\n")
            os.replace(tmp, self._path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def _new_id(self) -> str:
        taken = {e["id"] for e in self._entries}
        while True:
            candidate = f"p_{secrets.token_hex(4)}"
            if candidate not in taken:
                return candidate

    # ----- reading

    def snapshot(self) -> dict:
        with self._lock:
            mine = {normalize(e["word"]) for e in self._entries if e["enabled"]}
            return {
                "starter_enabled": self._starter_enabled,
                "entries": [dict(e) for e in self._entries],
                "starter": [
                    {
                        "id": s["id"],
                        "word": s["word"],
                        "say": s["say"],
                        "heard": s.get("heard"),
                        "enabled": s["id"] not in self._starter_off,
                        "overridden": normalize(s["word"]) in mine,
                    }
                    for s in self._starter
                ],
            }

    def active_pairs(self) -> list[tuple[str, str]]:
        """What applies, in priority order: the user's enabled entries,
        then the enabled starter entries."""
        with self._lock:
            pairs = [(e["word"], e["say"]) for e in self._entries if e["enabled"]]
            if self._starter_enabled:
                pairs += [(s["word"], s["say"]) for s in self._starter if s["id"] not in self._starter_off]
            return pairs

    def stage(self) -> Matcher:
        """The substitution stage for myna.speakable, rebuilt after a change."""
        matcher = self._matcher
        if matcher is None:
            matcher = Matcher(self.active_pairs())
            self._matcher = matcher
        return matcher

    # ----- changes

    def add(self, word: str, say: str, enabled: bool = True) -> dict:
        """Add an entry, or replace the say of the user's entry for the same word."""
        word, say = _clean_word(word), _clean_say(say)
        with self._lock:
            key = normalize(word)
            for entry in self._entries:
                if normalize(entry["word"]) == key:
                    entry.update(word=word, say=say, enabled=enabled)
                    self._save()
                    return dict(entry)
            entry = {"id": self._new_id(), "word": word, "say": say, "enabled": enabled}
            self._entries.append(entry)
            self._save()
            return dict(entry)

    def update(self, entry_id: str, *, word=None, say=None, enabled=None) -> dict:
        with self._lock:
            entry = next((e for e in self._entries if e["id"] == entry_id), None)
            if entry is None:
                raise KeyError(entry_id)
            new_word = _clean_word(word) if word is not None else entry["word"]
            new_say = _clean_say(say) if say is not None else entry["say"]
            key = normalize(new_word)
            if any(e is not entry and normalize(e["word"]) == key for e in self._entries):
                raise PronunciationError("duplicate_word", f"There's already an entry for “{new_word}”.")
            entry.update(word=new_word, say=new_say)
            if enabled is not None:
                entry["enabled"] = bool(enabled)
            self._save()
            return dict(entry)

    def delete(self, entry_id: str) -> bool:
        with self._lock:
            before = len(self._entries)
            self._entries = [e for e in self._entries if e["id"] != entry_id]
            if len(self._entries) == before:
                return False
            self._save()
            return True

    def set_starter_enabled(self, enabled: bool) -> None:
        with self._lock:
            self._starter_enabled = bool(enabled)
            self._save()

    def set_starter_entry(self, starter_entry_id: str, enabled: bool) -> None:
        with self._lock:
            if not any(s["id"] == starter_entry_id for s in self._starter):
                raise KeyError(starter_entry_id)
            if enabled:
                self._starter_off.discard(starter_entry_id)
            else:
                self._starter_off.add(starter_entry_id)
            self._save()
