"""Voice preview cache + curated sample sentences.

GET /v2/voices/preview/{voice_id} returns a ≤3s WAV synthesized with the
named voice, used by the Swift Settings → Voice tab to let users hear a
voice before committing.

Cache layout:
    ~/Library/Caches/myna/voice_previews/
        manifest.json     -> {"engine_version": "<id>"}
        {voice_id}.wav    -> the cached audio

Invalidation: if the daemon-internal engine version differs from the
manifest's, the directory is wiped on first preview request.

Sentence rotation: each voice_id maps deterministically to one of the
curated sentences via len(voice_id) % len(SAMPLES). Same voice always
gets the same sentence (so re-renders are bit-identical against the
cache) and the pool ships a mix of statement, list, and question for
prosody contrast.
"""

from __future__ import annotations

import json
import pathlib
import shutil
from typing import Optional


SAMPLES: list[str] = [
    "The fog crept in on little cat feet, and the city went quiet.",
    "Two plus two is four. Four plus four is eight. Easy.",
    "Did you mean to leave the door open, or was that on purpose?",
    "I went to the market and bought apples, oranges, bread, and milk.",
    "She paused at the threshold, listening for footsteps that never came.",
    "If today is Tuesday, then yesterday was Monday — yes?",
    "Coffee, contemplation, and a long walk: that's how the day begins.",
]


DEFAULT_CACHE_DIR = (
    pathlib.Path.home() / "Library" / "Caches" / "myna" / "voice_previews"
)

# Voices to pre-synthesize at daemon boot (top-5 by likely usage).
WARM_VOICES = ["af_heart", "af_bella", "af_sky", "am_michael", "am_adam"]


def sample_for_voice(voice_id: str) -> str:
    """Deterministic sentence pick per voice."""
    return SAMPLES[len(voice_id) % len(SAMPLES)]


class VoicePreviewCache:
    """Cache for synthesized voice-preview WAVs.

    Pure storage; the synth callable is injected so this module never
    imports engine.synthesize directly (keeps the test surface small).
    """

    def __init__(
        self,
        cache_dir: Optional[pathlib.Path] = None,
        *,
        engine_version: str = "0",
    ):
        self.cache_dir = cache_dir or DEFAULT_CACHE_DIR
        self.engine_version = engine_version
        self.manifest_path = self.cache_dir / "manifest.json"
        self._ensure_consistent_cache()

    # -------- manifest / invalidation --------

    def _ensure_consistent_cache(self) -> None:
        """Wipe the cache if the stored engine_version differs from ours."""
        if not self.cache_dir.exists():
            return
        try:
            stored = json.loads(self.manifest_path.read_text()).get(
                "engine_version"
            )
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            stored = None
        if stored != self.engine_version:
            # Wipe and start clean.
            try:
                shutil.rmtree(self.cache_dir)
            except OSError:
                pass

    def _write_manifest(self) -> None:
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            self.manifest_path.write_text(
                json.dumps({"engine_version": self.engine_version})
            )
        except OSError:
            pass

    # -------- read / write --------

    def path_for(self, voice_id: str) -> pathlib.Path:
        return self.cache_dir / f"{voice_id}.wav"

    def get(self, voice_id: str) -> Optional[bytes]:
        p = self.path_for(voice_id)
        try:
            return p.read_bytes()
        except (FileNotFoundError, OSError):
            return None

    def put(self, voice_id: str, wav: bytes) -> None:
        try:
            self.cache_dir.mkdir(parents=True, exist_ok=True)
            self.path_for(voice_id).write_bytes(wav)
            self._write_manifest()
        except OSError:
            pass
