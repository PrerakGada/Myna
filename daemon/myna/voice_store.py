"""The user's own voices: clips to speak like, and Kokoro blends.

Two kinds, both kept under ~/Library/Application Support/Myna/voices/:

    voices.json     [{id, kind, name, …}, …]
    clip-*.wav      the audio for each clip voice

  * clip   A 6–30 second recording. Pocket TTS and Chatterbox copy the voice
           in it on every read (the engine is sent the file's path). Added by
           importing a file in the app, or from the voice library
           (`myna.voice_library`), which records where it came from.
  * blend  Two or three Kokoro voices mixed. Kokoro averages comma-separated
           voice ids itself, so a 3:1 blend is sent as "a,a,a,b" — no new
           voice file, and nothing to go stale when the model updates.

Ids are `clip-<hex>` / `blend-<hex>`: safe in a URL path, and never shaped
like a built-in voice of any engine, so `resolve_voice` can tell them apart.
"""

from __future__ import annotations

import io
import json
import math
import os
import pathlib
import secrets
import threading
import time
import wave
from typing import Optional

from . import engines as engine_catalog

DEFAULT_DIR = pathlib.Path.home() / "Library" / "Application Support" / "Myna" / "voices"

# Chatterbox refuses a reference of 5 s or less (an assert in mlx-audio);
# past ~30 s Pocket's prompt just gets longer and every read slower.
MIN_CLIP_S = 5.5
MAX_CLIP_S = 30.0
MAX_CLIP_BYTES = 12 * 1024 * 1024
MAX_NAME = 60
MAX_BLEND_WEIGHT = 4

# Which engines can speak each kind.
_KIND_ENGINES = {"clip": ("pocket", "chatterbox"), "blend": ("kokoro",)}


class VoiceStoreError(ValueError):
    """A request the store refuses. `reason` is the API's machine-readable code."""

    def __init__(self, reason: str, detail: str):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail


def clip_duration_s(data: bytes) -> float:
    """Duration of a PCM WAV, or VoiceStoreError if it isn't one."""
    try:
        with wave.open(io.BytesIO(data)) as w:
            frames, rate = w.getnframes(), w.getframerate()
    except (wave.Error, EOFError) as exc:
        raise VoiceStoreError("bad_audio", f"Not a WAV file Myna can read ({exc}).") from exc
    if rate <= 0:
        raise VoiceStoreError("bad_audio", "The WAV file has no sample rate.")
    return frames / rate


def _clean_name(name: Optional[str], fallback: str) -> str:
    name = " ".join((name or "").split())[:MAX_NAME]
    return name or fallback


class VoiceStore:
    def __init__(self, root: Optional[pathlib.Path] = None):
        self.root = pathlib.Path(root) if root else DEFAULT_DIR
        self._lock = threading.Lock()
        self._entries: list[dict] = self._load()

    # ----- persistence -----

    @property
    def _index(self) -> pathlib.Path:
        return self.root / "voices.json"

    def _load(self) -> list[dict]:
        try:
            data = json.loads(self._index.read_text())
        except (OSError, ValueError):
            return []
        if not isinstance(data, list):
            return []
        return [e for e in data if isinstance(e, dict) and e.get("kind") in _KIND_ENGINES and e.get("id")]

    def _save(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        tmp = self._index.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(self._entries, indent=2))
        os.replace(tmp, self._index)

    # ----- reads -----

    def list(self) -> list[dict]:
        with self._lock:
            return [dict(e) for e in self._entries]

    def get(self, voice_id: Optional[str]) -> Optional[dict]:
        if not voice_id or not voice_id.startswith(("clip-", "blend-")):
            return None
        with self._lock:
            for e in self._entries:
                if e["id"] == voice_id:
                    return dict(e)
        return None

    def for_engine(self, engine_id: str) -> list[dict]:
        return [e for e in self.list() if engine_id in _KIND_ENGINES[e["kind"]]]

    def usable(self, engine_id: str, voice_id: Optional[str]) -> bool:
        """True when `voice_id` is one of the user's voices this engine can speak."""
        entry = self.get(voice_id)
        if entry is None or engine_id not in _KIND_ENGINES[entry["kind"]]:
            return False
        return entry["kind"] != "clip" or self.clip_path(entry["id"]).is_file()

    def clip_path(self, voice_id: str) -> pathlib.Path:
        return self.root / f"{voice_id}.wav"

    def from_library(self, library_id: str) -> Optional[dict]:
        for e in self.list():
            if e.get("library_id") == library_id:
                return e
        return None

    @staticmethod
    def kokoro_voice(entry: dict) -> str:
        """The comma-joined id Kokoro averages: weights 3 and 1 → "a,a,a,b"."""
        mix = [(m["voice"], int(m["weight"])) for m in entry["mix"]]
        g = 0
        for _, w in mix:
            g = math.gcd(g, w)
        return ",".join(v for v, w in mix for _ in range(w // (g or 1)))

    # ----- writes -----

    def add_clip(
        self,
        data: bytes,
        name: Optional[str],
        *,
        library_id: Optional[str] = None,
        detail: Optional[str] = None,
        credit: Optional[str] = None,
        gender: Optional[str] = None,
    ) -> dict:
        if len(data) > MAX_CLIP_BYTES:
            raise VoiceStoreError("too_large", "Clips are limited to 12 MB. Trim it to under 30 seconds.")
        duration = clip_duration_s(data)
        if duration < MIN_CLIP_S:
            raise VoiceStoreError(
                "too_short", f"The clip is {duration:.1f} s. Use at least {MIN_CLIP_S:g} seconds of speech."
            )
        if duration > MAX_CLIP_S + 0.5:
            raise VoiceStoreError(
                "too_long", f"The clip is {duration:.0f} s. Use {MAX_CLIP_S:g} seconds or less."
            )
        voice_id = f"clip-{secrets.token_hex(4)}"
        entry = {
            "id": voice_id,
            "kind": "clip",
            "name": _clean_name(name, "My voice"),
            "duration_s": round(duration, 1),
            "created_at": time.time(),
        }
        for key, value in (("library_id", library_id), ("detail", detail), ("credit", credit), ("gender", gender)):
            if value:
                entry[key] = value
        with self._lock:
            self.root.mkdir(parents=True, exist_ok=True)
            tmp = self.clip_path(voice_id).with_suffix(".wav.tmp")
            tmp.write_bytes(data)
            os.replace(tmp, self.clip_path(voice_id))
            self._entries.append(entry)
            self._save()
        return dict(entry)

    def add_blend(self, name: Optional[str], mix: list[dict]) -> dict:
        kokoro = engine_catalog.get("kokoro")
        cleaned: list[dict] = []
        for m in mix:
            voice = str(m.get("voice", ""))
            try:
                weight = int(m.get("weight", 1))
            except (TypeError, ValueError):
                weight = 0
            if not kokoro.has_voice(voice):
                raise VoiceStoreError("bad_blend", f"{voice or 'That'} is not a Kokoro voice.")
            if not 1 <= weight <= MAX_BLEND_WEIGHT:
                raise VoiceStoreError("bad_blend", f"Weights run from 1 to {MAX_BLEND_WEIGHT}.")
            if any(c["voice"] == voice for c in cleaned):
                raise VoiceStoreError("bad_blend", f"{voice} is in the blend twice.")
            cleaned.append({"voice": voice, "weight": weight})
        if not 2 <= len(cleaned) <= 3:
            raise VoiceStoreError("bad_blend", "A blend mixes two or three voices.")
        fallback = " × ".join(c["voice"].split("_", 1)[1].capitalize() for c in cleaned)
        entry = {
            "id": f"blend-{secrets.token_hex(4)}",
            "kind": "blend",
            "name": _clean_name(name, fallback),
            "mix": cleaned,
            "created_at": time.time(),
        }
        with self._lock:
            self._entries.append(entry)
            self._save()
        return dict(entry)

    def rename(self, voice_id: str, name: str) -> dict:
        with self._lock:
            for e in self._entries:
                if e["id"] == voice_id:
                    e["name"] = _clean_name(name, e["name"])
                    self._save()
                    return dict(e)
        raise VoiceStoreError("not_found", "No such voice.")

    def remove(self, voice_id: str) -> bool:
        with self._lock:
            before = len(self._entries)
            self._entries = [e for e in self._entries if e["id"] != voice_id]
            if len(self._entries) == before:
                return False
            self._save()
        try:
            self.clip_path(voice_id).unlink()
        except FileNotFoundError:
            pass
        return True
