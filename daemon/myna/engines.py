"""Voice-engine catalog — every model Myna can speak with, and how to drive it.

All four engines run inside the same mlx-audio server the daemon already
supervises, so switching engine is a different `model` on the same
`/v1/audio/speech` call, not a different runtime. What differs per engine,
and lives here:

  * which Hugging Face files it needs (some fetch extra repos on first load —
    Chatterbox's S3 speech tokenizer, Pocket's voice embeddings — so the
    download step pulls them up front instead of stalling the first read),
  * which voices it has, and which one to fall back to when the app asks for
    a voice from another engine (the app sends its saved voice on every read).
    Pocket and Chatterbox can also speak in any voice from a short clip, and
    Kokoro can blend its voices; those user-made voices live in
    `myna.voice_store`, not here,
  * its sampling settings. The mlx-audio server fills in its OWN defaults
    (temperature 0.7, top_k 40, repetition 1.0) for any field the request
    leaves out, which silently degrades models tuned for something else, so
    each engine sends its model's own defaults explicitly,
  * whether it honours `speed` (only Kokoro does; the others ignore it, and
    the app's live speed control — a playback time-stretch — still works),
  * the numbers measured for it in the Phase 0 bake-off
    (tools/engine-bakeoff, M5 Max, mlx-audio 0.5.7, 28 Sep 2026).
"""

from __future__ import annotations

import dataclasses
import re
from typing import Callable, Optional

DEFAULT_ENGINE_ID = "kokoro"

# Kokoro voice ids are `<lang><gender>_<name>` (af_heart, bm_lewis, ef_dora…).
# Any id of that shape is a Kokoro voice, including ones not in the list the
# picker shows. Japanese (j) and Mandarin (z) are left out: they need G2P
# packages (fugashi, pypinyin) the engine venv doesn't carry, and without them
# the engine answers 200 with no audio.
_KOKORO_VOICE_RE = re.compile(r"^[abefhip][fm]_[a-z0-9]+$")

# The first letter of a Kokoro voice is the language its pipeline must use.
# Sending the config's one `lang_code` for every voice read British voices
# with American pronunciation and Spanish voices through English G2P.
_KOKORO_LANGS = {
    "a": ("en", "American English"),
    "b": ("en", "British English"),
    "e": ("es", "Spanish"),
    "f": ("fr", "French"),
    "h": ("hi", "Hindi"),
    "i": ("it", "Italian"),
    "p": ("pt", "Brazilian Portuguese"),
}

# Every Kokoro-82M voice the engine can speak today, with hexgrad's overall
# grade from VOICES.md (an estimate of training-data quality and quantity;
# None where the model card gives none). Order within a language: best first.
_KOKORO_TABLE: tuple[tuple[str, Optional[str]], ...] = (
    ("af_heart", "A"), ("af_bella", "A-"), ("af_nicole", "B-"), ("af_aoede", "C+"),
    ("af_kore", "C+"), ("af_sarah", "C+"), ("af_alloy", "C"), ("af_nova", "C"),
    ("af_sky", "C-"), ("af_jessica", "D"), ("af_river", "D"),
    ("am_fenrir", "C+"), ("am_michael", "C+"), ("am_puck", "C+"), ("am_echo", "D"),
    ("am_eric", "D"), ("am_liam", "D"), ("am_onyx", "D"), ("am_santa", "D-"), ("am_adam", "F+"),
    ("bf_emma", "B-"), ("bf_isabella", "C"), ("bf_alice", "D"), ("bf_lily", "D"),
    ("bm_fable", "C"), ("bm_george", "C"), ("bm_lewis", "D+"), ("bm_daniel", "D"),
    ("ef_dora", None), ("em_alex", None), ("em_santa", None),
    ("ff_siwis", "B-"),
    ("hf_alpha", "C"), ("hf_beta", "C"), ("hm_omega", "C"), ("hm_psi", "C"),
    ("if_sara", "C"), ("im_nicola", "C"),
    ("pf_dora", None), ("pm_alex", None), ("pm_santa", None),
)


def kokoro_lang_code(voice_id: str) -> Optional[str]:
    """The Kokoro pipeline language for a voice or blend ("a", "b", "e"…).

    A blend ("af_heart,bm_george") speaks with its first voice's language.
    """
    first = voice_id.split(",", 1)[0].strip()
    if _KOKORO_VOICE_RE.match(first):
        return first[0]
    return None


def _kokoro_voice(voice_id: str, grade: Optional[str]) -> "Voice":
    lang, group = _KOKORO_LANGS[voice_id[0]]
    return Voice(
        id=voice_id,
        label=voice_id.split("_", 1)[1].capitalize(),
        lang=lang,
        group=group,
        gender="female" if voice_id[1] == "f" else "male",
        grade=grade,
    )


@dataclasses.dataclass(frozen=True)
class Download:
    """One Hugging Face repo (or a slice of one) an engine needs on disk."""

    repo: str
    revision: Optional[str] = None
    allow_patterns: Optional[tuple[str, ...]] = None


@dataclasses.dataclass(frozen=True)
class Stats:
    """Bake-off numbers. `None` means not measured, never zero."""

    first_word_s: float
    stream_first_s: Optional[float]
    speed_x: float
    peak_memory_mb: float
    word_error_pct: float
    measured_on: str = "M5 Max · mlx-audio 0.5.7 · 28 Sep 2026"


@dataclasses.dataclass(frozen=True)
class Voice:
    id: str
    label: str
    lang: str = "en"
    # How the picker files it: "American English", "British English"…
    group: Optional[str] = None
    gender: Optional[str] = None
    # Kokoro's own quality grade (A … F), where the model card gives one.
    grade: Optional[str] = None
    detail: Optional[str] = None


@dataclasses.dataclass(frozen=True)
class EngineSpec:
    id: str
    name: str
    maker: str
    tagline: str
    description: str
    repo: str
    params: str
    languages: tuple[str, ...]
    license: str
    download_mb: int
    sample_rate: int
    stats: Stats
    voices: tuple[Voice, ...]
    default_voice: str
    request_params: dict = dataclasses.field(default_factory=dict)
    extra_downloads: tuple[Download, ...] = ()
    native_speed: bool = False
    # Speaks in any voice from a 5–30 s clip (Pocket, Chatterbox).
    cloning: bool = False
    # Built-in voices can be mixed into new ones (Kokoro).
    blending: bool = False
    # Said on the Voices screen for an engine with nothing to choose from.
    voices_note: Optional[str] = None
    credit: Optional[str] = None
    badge: Optional[str] = None

    @property
    def downloads(self) -> tuple[Download, ...]:
        return (Download(self.repo), *self.extra_downloads)

    def has_voice(self, voice_id: Optional[str]) -> bool:
        """A built-in voice of this engine (user-made voices: `voice_store`)."""
        if not voice_id:
            return False
        if self.id == "kokoro":
            return bool(_KOKORO_VOICE_RE.match(voice_id))
        return any(v.id == voice_id for v in self.voices)


_POCKET_VOICE_REV = "d4fdd22ae8c8e1cb3634e150ebeff1dab2d16df3"
_POCKET_VOICES = ("alba", "marius", "javert", "jean", "fantine", "cosette", "eponine", "azelma")

CATALOG: tuple[EngineSpec, ...] = (
    EngineSpec(
        id="kokoro",
        name="Kokoro",
        maker="hexgrad",
        tagline="The default. Fast, accurate, 41 voices in six languages.",
        description=(
            "The voice Myna has always used. Starts speaking in a tenth of a second "
            "and reads numbers, dates and names cleanly."
        ),
        repo="prince-canuma/Kokoro-82M",
        params="82M",
        languages=("English", "Spanish", "French", "Hindi", "Italian", "Portuguese"),
        license="Apache 2.0",
        download_mb=372,
        sample_rate=24_000,
        stats=Stats(first_word_s=0.10, stream_first_s=None, speed_x=46.1, peak_memory_mb=3117, word_error_pct=4),
        voices=tuple(_kokoro_voice(v, g) for v, g in _KOKORO_TABLE),
        default_voice="af_heart",
        native_speed=True,
        blending=True,
        badge="Default",
    ),
    EngineSpec(
        id="soprano",
        name="Soprano",
        maker="ekwek",
        tagline="As fast as Kokoro on a quarter of the memory.",
        description=(
            "A small English model tuned for clear narration. The lightest engine "
            "here, which matters on a Mac that is already busy."
        ),
        repo="mlx-community/Soprano-1.1-80M-bf16",
        params="80M",
        languages=("English",),
        license="Apache 2.0",
        download_mb=284,
        sample_rate=32_000,
        stats=Stats(first_word_s=0.10, stream_first_s=None, speed_x=37.7, peak_memory_mb=700, word_error_pct=5),
        voices=(Voice("soprano", "Soprano", group="Built-in"),),
        default_voice="soprano",
        voices_note=(
            "Soprano speaks in one voice. It is a single-speaker model, so there is "
            "nothing to switch between and it cannot copy a voice from a clip. Pick "
            "Kokoro for 41 voices, or Pocket TTS or Chatterbox to use any voice from a clip."
        ),
        # Soprano's own defaults. The server's 0.7 temperature makes it wander.
        request_params={"temperature": 0.3, "top_p": 0.95, "top_k": 0, "repetition_penalty": 1.0, "max_tokens": 512},
        badge="Lightest",
    ),
    EngineSpec(
        id="pocket",
        name="Pocket TTS",
        maker="Kyutai",
        tagline="Eight voices, and the quickest to start when streamed.",
        description=(
            "Kyutai's pocket-sized model. It can begin sounding in 20 milliseconds when "
            "streamed and comes with eight distinct voices."
        ),
        repo="mlx-community/pocket-tts",
        params="100M",
        languages=("English",),
        license="CC BY 4.0",
        credit="Pocket TTS by Kyutai, licensed CC BY 4.0.",
        download_mb=245,
        sample_rate=24_000,
        stats=Stats(first_word_s=0.18, stream_first_s=0.02, speed_x=21.9, peak_memory_mb=960, word_error_pct=6),
        voices=tuple(Voice(v, v.capitalize(), group="Built-in") for v in _POCKET_VOICES),
        default_voice="alba",
        cloning=True,
        request_params={"temperature": 0.7},
        # Voice embeddings are fetched on first use from a separate repo, pinned
        # to the revision mlx-audio asks for. Pull them with the model.
        extra_downloads=(
            Download(
                "kyutai/pocket-tts-without-voice-cloning",
                revision=_POCKET_VOICE_REV,
                allow_patterns=tuple(f"embeddings/{v}.safetensors" for v in _POCKET_VOICES),
            ),
        ),
        badge="Most voices",
    ),
    EngineSpec(
        id="chatterbox",
        name="Chatterbox Turbo",
        maker="Resemble AI",
        tagline="The most accurate, with the most expression.",
        description=(
            "A larger model with livelier delivery. It made the fewest mistakes in the "
            "bake-off, at the cost of a slower start and more memory."
        ),
        repo="mlx-community/chatterbox-turbo-8bit",
        params="350M",
        languages=("English",),
        license="MIT",
        download_mb=1200,
        sample_rate=24_000,
        stats=Stats(first_word_s=0.46, stream_first_s=0.12, speed_x=7.8, peak_memory_mb=3323, word_error_pct=3),
        voices=(Voice("chatterbox", "Built-in voice", group="Built-in"),),
        default_voice="chatterbox",
        cloning=True,
        request_params={
            "temperature": 0.8, "top_p": 0.95, "top_k": 1000,
            "repetition_penalty": 1.2, "max_tokens": 800,
        },
        # mlx-audio downloads the S3 speech tokenizer on first load (2+ minutes
        # of silence on a first read otherwise).
        extra_downloads=(
            Download("mlx-community/S3TokenizerV2", allow_patterns=("model.safetensors",)),
        ),
        badge="Most accurate",
    ),
)

_BY_ID = {spec.id: spec for spec in CATALOG}


def get(engine_id: str) -> Optional[EngineSpec]:
    return _BY_ID.get(engine_id)


def active_spec(cfg: dict) -> EngineSpec:
    """The engine a config selects.

    Older configs have no `engine` key, only `model`. Those map to the catalog
    entry with that repo; an unknown repo (someone pointed Myna at their own
    Kokoro build) stays Kokoro-shaped with the custom repo, so it keeps working
    exactly as before.
    """
    engine_id = cfg.get("engine")
    if engine_id and engine_id in _BY_ID:
        return _BY_ID[engine_id]
    model = cfg.get("model")
    for spec in CATALOG:
        if spec.repo == model:
            return spec
    kokoro = _BY_ID[DEFAULT_ENGINE_ID]
    if model:
        return dataclasses.replace(kokoro, repo=model)
    return kokoro


def resolve_voice(
    spec: EngineSpec,
    requested: Optional[str],
    remembered: Optional[str],
    usable: Optional[Callable[[str], bool]] = None,
) -> str:
    """The voice to actually send the engine.

    The app sends its saved voice with every read, and that voice may belong
    to a different engine (switch Kokoro → Pocket and the app still says
    af_heart). Anything the engine doesn't have falls back to the voice last
    used on this engine, then to its default. `usable` widens "has" to the
    user's own voices (clips, blends) this engine can speak.
    """

    def ok(voice_id: Optional[str]) -> bool:
        if spec.has_voice(voice_id):
            return True
        return bool(voice_id) and usable is not None and usable(voice_id)  # type: ignore[arg-type]

    if ok(requested):
        return requested  # type: ignore[return-value]
    if ok(remembered):
        return remembered  # type: ignore[return-value]
    return spec.default_voice
