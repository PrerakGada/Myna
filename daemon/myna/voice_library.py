"""The voice library — ready-made clips for the engines that copy a voice.

113 labelled clips from Kyutai's tts-voices collection (accents from the
VCTK corpus, a voice actor, audiobook narrators), all licensed for
commercial use. The list itself is generated into `voice_library_data.py`
by tools/voice-library/build.py; this module fetches the audio.

A clip is downloaded once, pinned to the revision the list was built from,
into ~/Library/Caches/myna/voice_library/. Hearing the sample and adding
the voice share that download; adding copies it into the user's voices
(`myna.voice_store`), so clearing the cache never breaks a voice in use.
"""

from __future__ import annotations

import pathlib
import threading
from typing import Callable, Optional

import httpx

from .voice_library_data import ENTRIES, REPO, REVISION

DEFAULT_CACHE_DIR = pathlib.Path.home() / "Library" / "Caches" / "myna" / "voice_library"
_BY_ID = {e["id"]: e for e in ENTRIES}


def get(library_id: str) -> Optional[dict]:
    return _BY_ID.get(library_id)


def url_for(entry: dict) -> str:
    return f"https://huggingface.co/{REPO}/resolve/{REVISION}/{entry['path']}"


def _http_get(url: str) -> bytes:
    resp = httpx.get(url, timeout=30.0, follow_redirects=True)
    resp.raise_for_status()
    return resp.content


class VoiceLibrary:
    def __init__(
        self,
        cache_dir: Optional[pathlib.Path] = None,
        fetch: Optional[Callable[[str], bytes]] = None,
    ):
        self.cache_dir = pathlib.Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
        self._fetch = fetch or _http_get
        self._lock = threading.Lock()

    def entries(self) -> tuple[dict, ...]:
        return ENTRIES

    def audio(self, library_id: str) -> bytes:
        """The clip's WAV bytes, downloading it on first use.

        KeyError for an unknown id; httpx errors propagate so the endpoint
        can say "couldn't download" rather than pretend.
        """
        entry = _BY_ID[library_id]
        path = self.cache_dir / f"{library_id}.wav"
        with self._lock:
            if path.is_file():
                return path.read_bytes()
        data = self._fetch(url_for(entry))
        with self._lock:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            tmp = path.with_suffix(".wav.tmp")
            tmp.write_bytes(data)
            tmp.replace(path)
        return data
