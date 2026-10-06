"""The renderer: text in, one finished WAV out. Shared by /v1/audio/speech
and the /v2/renders job worker.

A render is not a read. It never touches the state machine, the karaoke
ribbon, the pill, History or the remembered voice. Every synthesize call
passes `engine_kwargs(voice, remember=False)`, which also applies the active
engine's own sampling settings, so an engine renders exactly as it reads.

Only the active engine renders. Switching engines loads and unloads models in
the one engine process a live read also uses, so a render never switches;
naming another engine is `engine_not_active`.

OpenAI voice names (alloy, nova, …) are mapped onto the active engine's own
voices when asked, never from a fixed per-engine table: engines gain voices,
and the mapping has to follow.
"""

from __future__ import annotations

import io
import re
import time
import wave
from dataclasses import dataclass, field
from typing import Callable, Iterable, Optional

import httpx

from . import chunking
from . import engines as engine_catalog
from .engine_store import repo_dir

# `model` values an OpenAI client sends. All of them mean "the active engine".
OPENAI_MODEL_ALIASES = ("myna", "tts-1", "tts-1-hd", "gpt-4o-mini-tts")

# OpenAI's built-in voices, in their documented order, with the voice each
# name is known for. Used only to pick a like-for-like engine voice when the
# engine has no voice of the same name. None = no strong gender.
OPENAI_VOICES: dict[str, Optional[str]] = {
    "alloy": None,
    "ash": "male",
    "ballad": "male",
    "coral": "female",
    "echo": "male",
    "fable": "male",
    "onyx": "male",
    "nova": "female",
    "sage": "female",
    "shimmer": "female",
    "verse": "male",
}

# Renders synthesize in chunks of at most this many characters (sentence
# boundaries, never mid-sentence unless one sentence is longer). A live read
# waits behind at most one render chunk in the engine: at the read path's
# 1500 characters that was ~12 s on Chatterbox; at 400 it's ~3 s there and
# under a second on the other engines.
RENDER_CHUNK_CHARS = 400

SPEED_ACCEPT = (0.25, 4.0)  # what OpenAI accepts
SPEED_CLAMP = (0.5, 2.0)    # what Myna's engines can usefully do

# Kokoro id prefixes: first letter is the language, second the gender.
_KOKORO_LANG = {
    "a": "en", "b": "en", "e": "es", "f": "fr", "h": "hi",
    "i": "it", "j": "ja", "p": "pt-br", "z": "zh",
}


class RenderError(Exception):
    """A render failed for a reason the caller should see.

    `reason` is the machine code (engine_down, engine_error, …), `status` the
    HTTP status the synchronous endpoints answer with.
    """

    def __init__(self, reason: str, detail: str = "", status: int = 502):
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail
        self.status = status


# ----- engine and voices -----


def resolve_engine(cfg: dict, model: Optional[str]):
    """The active engine spec, if `model` names it (or an alias, or nothing)."""
    spec = engine_catalog.active_spec(cfg)
    if not model or model in OPENAI_MODEL_ALIASES or model in (spec.id, spec.repo):
        return spec
    other = engine_catalog.get(model)
    name = other.name if other else model
    raise RenderError(
        "engine_not_active",
        f"{name} isn't the active voice engine ({spec.name} is). Myna only renders "
        "with the active engine; switch engines in Myna first.",
        status=409 if other else 400,
    )


def _voice_gender(voice_id: str, label: str) -> Optional[str]:
    low = (label or "").lower()
    if "(female)" in low:
        return "female"
    if "(male)" in low:
        return "male"
    if re.match(r"^[abefhijpz][fm]_", voice_id):
        return "female" if voice_id[1] == "f" else "male"
    return None


def _kokoro_label(voice_id: str) -> str:
    name = voice_id.split("_", 1)[-1].replace("_", " ").title()
    gender = _voice_gender(voice_id, "")
    return f"{name} ({gender})" if gender else name


def _snapshot_voice_ids(spec, hub) -> list[str]:
    """Voice files shipped inside the engine's model folder (Kokoro keeps
    `voices/<id>.safetensors`). Only ids the engine itself accepts count."""
    root = repo_dir(spec.repo, hub) / "snapshots"
    ids: set[str] = set()
    try:
        for snap in root.iterdir():
            vdir = snap / "voices"
            if not vdir.is_dir():
                continue
            for f in vdir.iterdir():
                if f.suffix in (".safetensors", ".pt") and spec.has_voice(f.stem):
                    ids.add(f.stem)
    except OSError:
        return []
    return sorted(ids)


def engine_voices(app) -> list[dict]:
    """Every voice the active engine can speak: `{id, label, lang, default}`.

    Starts from what `/v2/voices` reports (the Voices page's list, whatever
    the engine catalog grows to), falling back to the catalog when the engine
    is down, then adds voices found in the model's own folder.
    """
    cfg = app.state.cfg
    spec = engine_catalog.active_spec(cfg)
    listed: list[dict] = []
    endpoint = _route_endpoint(app, "/v2/voices")
    if endpoint is not None:
        try:
            resp = endpoint()
            listed = [
                {"id": v.id, "label": v.label, "lang": v.lang, "default": bool(v.default)}
                for v in (resp.voices or [])
            ]
        except Exception:
            listed = []
    remembered = (cfg.get("engine_voices") or {}).get(spec.id) or cfg.get("voice")
    default_id = engine_catalog.resolve_voice(spec, None, remembered)
    if not listed:
        listed = [
            {"id": v.id, "label": v.label, "lang": v.lang, "default": v.id == default_id}
            for v in spec.voices
        ]
    seen = {v["id"] for v in listed}
    store = getattr(app.state, "engine_store", None)
    hub = store.hub if store is not None else None
    for vid in _snapshot_voice_ids(spec, hub):
        if vid not in seen:
            listed.append({
                "id": vid,
                "label": _kokoro_label(vid),
                "lang": _KOKORO_LANG.get(vid[:1], "en"),
                "default": vid == default_id,
            })
            seen.add(vid)
    if not any(v["default"] for v in listed):
        for v in listed:
            if v["id"] == default_id:
                v["default"] = True
    return listed


def _route_endpoint(app, path: str):
    for route in app.routes:
        if getattr(route, "path", None) == path and "GET" in (getattr(route, "methods", None) or ()):
            return route.endpoint
    return None


def openai_voice_map(voices: list[dict], default_id: str) -> dict[str, str]:
    """OpenAI voice name → one of these engine voices.

    1. Same name: `alloy` → `af_alloy` (Kokoro ships most of OpenAI's names).
    2. Otherwise a voice of the same gender, when the engine's voices say
       theirs, spreading names over voices so two OpenAI voices stay two
       different voices where the engine has enough. English voices first.
    3. Otherwise spread over all voices in order, `alloy` (OpenAI's first)
       taking the engine default. A one-voice engine maps everything to it.
    """
    if not voices:
        return {name: default_id for name in OPENAI_VOICES}

    def bare(v: dict) -> str:
        return v["id"].split("_", 1)[-1].lower() if "_" in v["id"] else v["id"].lower()

    english = [v for v in voices if str(v.get("lang", "en")).startswith("en")] or voices
    mapping: dict[str, str] = {}
    for name in OPENAI_VOICES:
        for v in english:
            if bare(v) == name or (v.get("label") or "").split(" ")[0].lower() == name:
                mapping[name] = v["id"]
                break

    taken = set(mapping.values())
    pools = {
        g: [v["id"] for v in english if _voice_gender(v["id"], v.get("label", "")) == g]
        for g in ("female", "male")
    }
    free_pools = {g: [vid for vid in ids if vid not in taken] or ids for g, ids in pools.items()}
    cursor = {"female": 0, "male": 0}
    in_order = [v["id"] for v in english]
    others = [vid for vid in in_order if vid != default_id] or in_order
    spread = 0
    for name, gender in OPENAI_VOICES.items():
        if name in mapping:
            continue
        if name == "alloy":
            mapping[name] = default_id
            continue
        pool = free_pools.get(gender or "", [])
        if pool:
            mapping[name] = pool[cursor[gender] % len(pool)]
            cursor[gender] += 1
        else:
            mapping[name] = others[spread % len(others)]
            spread += 1
    return mapping


def default_voice_id(cfg: dict) -> str:
    spec = engine_catalog.active_spec(cfg)
    remembered = (cfg.get("engine_voices") or {}).get(spec.id) or cfg.get("voice")
    return engine_catalog.resolve_voice(spec, None, remembered)


def resolve_render_voice(app, requested: Optional[str]) -> str:
    """The engine voice a render request's `voice` means.

    An engine voice id passes through; an OpenAI name is mapped; anything
    else resolves (via engine_kwargs) to the engine's remembered voice or
    default. Never remembers anything.
    """
    cfg = app.state.cfg
    spec = engine_catalog.active_spec(cfg)
    voice = requested
    if requested and not spec.has_voice(requested) and requested.lower() in OPENAI_VOICES:
        voice = openai_voice_map(engine_voices(app), default_voice_id(cfg))[requested.lower()]
    return app.state.engine_kwargs(voice, remember=False)["voice"]


def clamp_speed(speed: Optional[float], spec) -> float:
    """Speed actually applied. Only engines with native speed honour it, so
    the others report 1.0 rather than a speed the audio doesn't have."""
    if speed is None or not spec.native_speed:
        return 1.0
    return max(SPEED_CLAMP[0], min(SPEED_CLAMP[1], float(speed)))


# ----- text -----


def render_chunk_chars(cfg: dict) -> int:
    return max(1, min(int(cfg.get("chunk_chars") or RENDER_CHUNK_CHARS), RENDER_CHUNK_CHARS))


def plan_chunks(text: str, chunk_chars: int) -> list[str]:
    """Split text for synthesis: paragraphs first, then sentences within
    each, so a chunk never runs one paragraph into the next."""
    out: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        para = " ".join(para.split())
        if para:
            out.extend(chunking.chunk_text(para, chunk_chars))
    return out


def preview_of(text: str, limit: int = 160) -> str:
    flat = " ".join(text.split())
    return flat if len(flat) <= limit else flat[: limit - 1].rstrip() + "…"


# ----- audio -----


@dataclass
class WavParams:
    channels: int
    sampwidth: int
    rate: int


def parse_wav(data: bytes) -> tuple[WavParams, bytes]:
    try:
        with wave.open(io.BytesIO(data), "rb") as w:
            params = WavParams(w.getnchannels(), w.getsampwidth(), w.getframerate())
            frames = w.readframes(w.getnframes())
    except (wave.Error, EOFError) as exc:
        raise RenderError("engine_error", f"the engine returned audio Myna can't read ({exc})") from None
    return params, frames


@dataclass
class PcmSink:
    """Collects chunk audio into one WAV, in memory or straight to a file.
    The first chunk fixes the format; a later chunk that differs is an error
    (one engine, one model: it never should)."""

    path: Optional[str] = None
    params: Optional[WavParams] = None
    frames: int = 0
    _writer: Optional[wave.Wave_write] = field(default=None, repr=False)
    _buf: Optional[io.BytesIO] = field(default=None, repr=False)

    def add(self, params: WavParams, pcm: bytes) -> None:
        if self._writer is None:
            self.params = params
            if self.path is not None:
                self._writer = wave.open(self.path, "wb")
            else:
                self._buf = io.BytesIO()
                self._writer = wave.open(self._buf, "wb")
            self._writer.setnchannels(params.channels)
            self._writer.setsampwidth(params.sampwidth)
            self._writer.setframerate(params.rate)
        elif params != self.params:
            raise RenderError("engine_error", "the engine changed audio format mid-render")
        self._writer.writeframes(pcm)
        self.frames += len(pcm) // (params.channels * params.sampwidth)

    def add_silence(self, ms: int) -> None:
        if self.params is None or ms <= 0:
            return
        n = int(self.params.rate * ms / 1000)
        self.add(self.params, b"\x00" * (n * self.params.channels * self.params.sampwidth))

    @property
    def seconds(self) -> float:
        return self.frames / float(self.params.rate) if self.params else 0.0

    def close(self) -> Optional[bytes]:
        """Finish the WAV header. Returns the bytes for an in-memory sink."""
        if self._writer is None:
            return None
        self._writer.close()
        self._writer = None
        return self._buf.getvalue() if self._buf is not None else None


def synthesize_chunk(
    app,
    text: str,
    *,
    voice: str,
    speed: float,
    retries: tuple[float, ...] = (),
    sleep: Callable[[float], None] = time.sleep,
) -> bytes:
    """One chunk through the engine, retrying on failure after each delay in
    `retries`. Engine errors become RenderError(engine_down | engine_error)."""
    cfg = app.state.cfg
    attempt = 0
    while True:
        try:
            return app.state.synthesize(
                text,
                speed=speed,
                base_url=cfg["engine_url"],
                **app.state.engine_kwargs(voice, remember=False),
            )
        except Exception as exc:
            if attempt < len(retries):
                sleep(retries[attempt])
                attempt += 1
                continue
            if isinstance(exc, (httpx.ConnectError, httpx.ConnectTimeout)):
                raise RenderError("engine_down", "The voice engine isn't running.", status=503) from None
            raise RenderError("engine_error", str(exc)[:500], status=502) from None


def render_to_wav(
    app,
    chunks: Iterable[str],
    *,
    voice: str,
    speed: float,
    retries: tuple[float, ...] = (),
) -> tuple[bytes, WavParams, int, float]:
    """Synthesize every chunk and join them into one in-memory WAV.
    Returns (wav bytes, format, chunk count, seconds of audio)."""
    sink = PcmSink()
    count = 0
    for chunk in chunks:
        wav = synthesize_chunk(app, chunk, voice=voice, speed=speed, retries=retries)
        params, pcm = parse_wav(wav)
        sink.add(params, pcm)
        count += 1
    data = sink.close()
    if data is None:
        raise RenderError("empty_input", "There's no text to speak.", status=400)
    return data, sink.params, count, sink.seconds
