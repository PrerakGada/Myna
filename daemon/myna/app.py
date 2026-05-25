import json
import os
import pathlib
import time
import urllib.parse
import uuid

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel

from . import __version__, chunking, engine
from . import extract as extract_mod
from . import summarize as summarize_mod
from .config import load_config
from .player import Player
from .registry import Registry
from .v2_types import (
    V2ConfigInfo,
    V2DaemonInfo,
    V2EngineInfo,
    V2ExtractReq,
    V2ExtractResp,
    V2Health,
    V2RegistryInfo,
    V2RegistryItem,
    V2Status,
    V2SummarizeReq,
    V2SummarizeResp,
    V2SynthesizeReq,
    V2V1PlayerInfo,
    V2Voice,
    V2Voices,
)

# Cache TTLs
_ENGINE_CHECK_TTL_S = 1.0       # /v2/health and /v2/status reuse a check this fresh
_VOICES_CACHE_TTL_S = 300.0     # 5 minutes

# Fallback list when Kokoro doesn't expose voices via /v1/voices
_KOKORO_FALLBACK_VOICE_IDS = ["af_heart", "af_bella", "am_michael", "am_adam"]


class SpeakReq(BaseModel):
    text: str | None = None
    url: str | None = None
    mode: str = "full"
    voice: str | None = None
    speed: float | None = None
    source: str | None = None


class AnnounceReq(BaseModel):
    session_id: str
    label: str
    text: str


class SpeedReq(BaseModel):
    value: float


def _voice_label(voice_id: str) -> str:
    """Human-friendly label for a Kokoro voice id.

    Format: "Name (gender)". Naming convention follows Kokoro's `<lang><gender>_<name>`.
    """
    # Strip the lang/gender prefix (e.g., "af_heart" -> "heart").
    name = voice_id.split("_", 1)[-1] if "_" in voice_id else voice_id
    gender = "unknown"
    if voice_id.startswith("af") or voice_id.startswith("bf"):
        gender = "female"
    elif voice_id.startswith("am") or voice_id.startswith("bm"):
        gender = "male"
    return f"{name.capitalize()} ({gender})"


def _voice_lang(voice_id: str) -> str:
    """Best-effort language code from Kokoro voice id ("af_heart" -> "en")."""
    # Kokoro voice ids start with a/b for English (American/British) — both "en".
    if voice_id[:1] in {"a", "b"}:
        return "en"
    return "unknown"


def create_app(config: dict | None = None) -> FastAPI:
    app = FastAPI(title="Myna")
    cfg = config or load_config()
    app.state.cfg = cfg
    app.state.speed = cfg["speed"]
    app.state.player = Player()
    app.state.registry = Registry()
    app.state.synthesize = engine.synthesize
    app.state.engine_up = engine.engine_up
    app.state.summarize = summarize_mod.summarize
    app.state.extract = extract_mod.extract_article

    # v2 bookkeeping
    app.state.started_at = time.time()
    app.state.last_engine_check_at: float = 0.0
    app.state.last_engine_status: bool = False
    app.state.voices_cache: list[V2Voice] | None = None
    app.state.voices_cache_at: float = 0.0

    tmpdir = pathlib.Path.home() / ".cache" / "myna" / "tmp"

    def _producer(text, voice, speed):
        tmpdir.mkdir(parents=True, exist_ok=True)
        for chunk in chunking.chunk_text(text, cfg["chunk_chars"]):
            wav = app.state.synthesize(
                chunk,
                voice=voice,
                speed=speed,
                base_url=cfg["engine_url"],
                model=cfg["model"],
                lang_code=cfg["lang_code"],
            )
            p = tmpdir / f"{uuid.uuid4().hex}.wav"
            p.write_bytes(wav)
            yield str(p)

    def _speak(req: SpeakReq):
        text = req.text
        if req.url:
            text = app.state.extract(req.url)
            if not text:
                return {"ok": False, "reason": "extract_failed"}
        text = (text or "").strip()
        if not text:
            return {"ok": False, "reason": "empty"}
        if req.mode == "summary":
            text = app.state.summarize(
                text,
                model=cfg["summary_model"],
                base_url=cfg["ollama_url"],
                think=cfg["summary_think"],
                timeout=cfg["summary_timeout"],
            )
        voice = req.voice or cfg["voice"]
        speed = req.speed or app.state.speed
        app.state.player.play(
            _producer(text, voice, speed),
            meta={"source": req.source or "speak", "preview": text[:60]},
        )
        return {"ok": True}

    # ----- v1 endpoints (unchanged behaviour) -----

    @app.post("/speak")
    def speak(req: SpeakReq):
        return _speak(req)

    @app.post("/announce")
    def announce(req: AnnounceReq):
        rid = app.state.registry.add(req.label, req.text)
        return {"ok": True, "id": rid}

    @app.get("/registry")
    def registry():
        return {"items": app.state.registry.list_items()}

    @app.post("/play/{item_id}")
    def play_item(item_id: str, mode: str = "full"):
        item = app.state.registry.pop(item_id)
        if not item:
            return {"ok": False, "reason": "not_found"}
        return _speak(SpeakReq(text=item["text"], mode=mode, source=item["label"]))

    @app.post("/pause")
    def pause():
        app.state.player.pause()
        return {"ok": True}

    @app.post("/resume")
    def resume():
        app.state.player.resume()
        return {"ok": True}

    @app.post("/stop")
    def stop():
        app.state.player.stop()
        return {"ok": True}

    @app.post("/speed")
    def speed(req: SpeedReq):
        app.state.speed = max(0.5, min(2.0, req.value))
        return {"ok": True, "speed": app.state.speed}

    @app.get("/status")
    def status():
        st = app.state.player.status()
        return {
            "state": st["state"],
            "now_playing": st["now_playing"],
            "speed": app.state.speed,
            "registry_count": len(app.state.registry.list_items()),
            "engine": "up" if app.state.engine_up(cfg["engine_url"]) else "down",
        }

    # ----- v2 helpers -----

    def _check_engine_cached() -> bool:
        """Return cached engine status; re-check if older than TTL.

        Always swallows engine_up() exceptions and treats them as "down".
        Updates app.state.last_engine_{check_at,status}.
        """
        now = time.time()
        if now - app.state.last_engine_check_at < _ENGINE_CHECK_TTL_S:
            return app.state.last_engine_status
        try:
            up = bool(app.state.engine_up(cfg["engine_url"]))
        except Exception:
            up = False
        app.state.last_engine_check_at = now
        app.state.last_engine_status = up
        return up

    def _engine_check_age_s() -> float:
        if app.state.last_engine_check_at == 0.0:
            return 0.0
        return max(0.0, time.time() - app.state.last_engine_check_at)

    def _fetch_voices_from_engine() -> list[V2Voice]:
        """Try Kokoro's /v1/voices; fall back to a hardcoded list of known ids.

        The configured default voice is marked default=true.
        """
        default_id = cfg["voice"]
        ids: list[str] = []
        try:
            resp = httpx.get(f"{cfg['engine_url']}/v1/voices", timeout=2.0)
            resp.raise_for_status()
            data = resp.json()
            # Try several common shapes: ["af_heart", ...] or {"voices": [...]} or
            # {"voices": [{"id": "af_heart"}, ...]}
            if isinstance(data, list):
                ids = [v if isinstance(v, str) else v.get("id", "") for v in data]
            elif isinstance(data, dict):
                raw = data.get("voices") or data.get("data") or []
                for v in raw:
                    if isinstance(v, str):
                        ids.append(v)
                    elif isinstance(v, dict):
                        ids.append(v.get("id") or v.get("name") or "")
            ids = [i for i in ids if i]
        except Exception:
            ids = []
        if not ids:
            ids = list(_KOKORO_FALLBACK_VOICE_IDS)
        # Make sure the configured default is present.
        if default_id and default_id not in ids:
            ids.insert(0, default_id)
        return [
            V2Voice(
                id=vid,
                label=_voice_label(vid),
                lang=_voice_lang(vid),
                default=(vid == default_id),
            )
            for vid in ids
        ]

    def _prepare_v2_text(req: V2SynthesizeReq, *, mode: str) -> str:
        """Apply the same text/url/summarise pipeline as v1 _speak, with v2
        error semantics (HTTPException so FastAPI returns a JSON body).
        """
        if req.text is not None and req.url is not None:
            raise HTTPException(
                status_code=400,
                detail={"ok": False, "reason": "both_text_and_url"},
            )
        if (req.text is None or not req.text.strip()) and not req.url:
            # Only treat as 'neither' if both are absent. Empty text counts as empty
            # (separate test) only when text is provided but blank.
            if req.text is None and req.url is None:
                raise HTTPException(
                    status_code=400,
                    detail={"ok": False, "reason": "neither_text_nor_url"},
                )

        text: str | None
        if req.url:
            text = app.state.extract(req.url)
            if not text:
                raise HTTPException(
                    status_code=400,
                    detail={"ok": False, "reason": "extract_failed"},
                )
        else:
            text = req.text

        text = (text or "").strip()
        if not text:
            raise HTTPException(
                status_code=400,
                detail={"ok": False, "reason": "empty"},
            )

        if mode == "summary":
            text = app.state.summarize(
                text,
                model=cfg["summary_model"],
                base_url=cfg["ollama_url"],
                think=cfg["summary_think"],
                timeout=cfg["summary_timeout"],
            )

        return text

    def _v2_synthesize_response(
        req: V2SynthesizeReq, *, mode: str
    ) -> StreamingResponse:
        # Pre-check the engine. We do this before any work so the Swift client
        # gets a quick 502 rather than waiting on a doomed pipeline.
        if not _check_engine_cached():
            return JSONResponse(
                status_code=502,
                content={"ok": False, "reason": "engine_down"},
            )

        text = _prepare_v2_text(req, mode=mode)

        chunk_chars = req.chunk_chars or cfg["chunk_chars"]
        chunks = chunking.chunk_text(text, chunk_chars)
        if not chunks:
            raise HTTPException(
                status_code=400,
                detail={"ok": False, "reason": "empty"},
            )
        total = len(chunks)
        voice = req.voice or cfg["voice"]
        speed = req.speed
        session_id = req.session_id or uuid.uuid4().hex

        # Synthesize the first chunk eagerly so engine errors surface as a real
        # HTTP 502 (we haven't started streaming yet). Subsequent chunks are
        # synthesized inside the generator; failures there end the stream early.
        try:
            first_wav = app.state.synthesize(
                chunks[0],
                voice=voice,
                speed=speed,
                base_url=cfg["engine_url"],
                model=cfg["model"],
                lang_code=cfg["lang_code"],
            )
        except Exception as exc:
            return JSONResponse(
                status_code=502,
                content={"ok": False, "reason": "engine_error", "detail": str(exc)},
            )

        boundary = b"mynachunk"

        def _part_headers(idx: int, total: int, preview: str) -> bytes:
            preview_encoded = urllib.parse.quote(preview[:200], safe="")
            return (
                b"--" + boundary + b"\r\n"
                b"Content-Type: audio/wav\r\n"
                b"X-Chunk-Index: " + str(idx).encode() + b"\r\n"
                b"X-Chunk-Total-Estimate: " + str(total).encode() + b"\r\n"
                b"X-Chunk-Text: " + preview_encoded.encode() + b"\r\n\r\n"
            )

        def _final_part(actual_chunks: int) -> bytes:
            body = json.dumps(
                {"ok": True, "chunks": actual_chunks, "session_id": session_id}
            ).encode()
            return (
                b"--" + boundary + b"\r\n"
                b"Content-Type: application/json\r\n\r\n"
                + body + b"\r\n"
                b"--" + boundary + b"--\r\n"
            )

        def _generator():
            # First chunk (already synthesized eagerly)
            yield _part_headers(0, total, chunks[0])
            yield first_wav
            yield b"\r\n"
            yielded = 1
            for idx in range(1, total):
                try:
                    wav = app.state.synthesize(
                        chunks[idx],
                        voice=voice,
                        speed=speed,
                        base_url=cfg["engine_url"],
                        model=cfg["model"],
                        lang_code=cfg["lang_code"],
                    )
                except Exception:
                    # Engine died mid-stream — terminate cleanly with the
                    # closing JSON part reporting the actual count.
                    break
                yield _part_headers(idx, total, chunks[idx])
                yield wav
                yield b"\r\n"
                yielded += 1
            yield _final_part(yielded)

        return StreamingResponse(
            _generator(),
            media_type="multipart/mixed; boundary=mynachunk",
        )

    # ----- v2 endpoints -----

    @app.post("/v2/synthesize")
    def v2_synthesize(req: V2SynthesizeReq):
        return _v2_synthesize_response(req, mode=req.mode)

    @app.post("/v2/synthesize-summary")
    def v2_synthesize_summary(req: V2SynthesizeReq):
        return _v2_synthesize_response(req, mode="summary")

    @app.get("/v2/status")
    def v2_status() -> V2Status:
        engine_up_now = _check_engine_cached()
        player_st = app.state.player.status()
        reg_items = app.state.registry.list_items()
        return V2Status(
            state="down" if not engine_up_now else "idle",
            engine=V2EngineInfo(
                url=cfg["engine_url"],
                status="up" if engine_up_now else "down",
                model=cfg["model"],
                last_check_age_s=_engine_check_age_s(),
            ),
            daemon=V2DaemonInfo(
                version=__version__,
                uptime_s=max(0.0, time.time() - app.state.started_at),
                pid=os.getpid(),
            ),
            config=V2ConfigInfo(
                voice=cfg["voice"],
                speed=app.state.speed,
                lang_code=cfg["lang_code"],
                chunk_chars=cfg["chunk_chars"],
                summary_model=cfg["summary_model"],
            ),
            registry=V2RegistryInfo(
                count=len(reg_items),
                items=[V2RegistryItem(**i) for i in reg_items],
            ),
            v1_player=V2V1PlayerInfo(
                state=player_st["state"],
                now_playing=player_st["now_playing"],
            ),
        )

    @app.get("/v2/voices")
    def v2_voices() -> V2Voices:
        if not _check_engine_cached():
            return V2Voices(voices=[], engine="down")
        now = time.time()
        if (
            app.state.voices_cache is not None
            and now - app.state.voices_cache_at < _VOICES_CACHE_TTL_S
        ):
            return V2Voices(voices=app.state.voices_cache)
        voices = _fetch_voices_from_engine()
        app.state.voices_cache = voices
        app.state.voices_cache_at = now
        return V2Voices(voices=voices)

    @app.post("/v2/extract")
    def v2_extract(req: V2ExtractReq) -> V2ExtractResp:
        url = (req.url or "").strip()
        if not (url.startswith("http://") or url.startswith("https://")):
            raise HTTPException(
                status_code=400,
                detail={"ok": False, "reason": "invalid_url"},
            )
        result = app.state.extract(url)
        # Support both legacy `str | None` and richer `dict` returns (title/byline).
        if result is None:
            return V2ExtractResp(ok=False, reason="extract_failed")
        if isinstance(result, dict):
            text = result.get("text")
            if not text:
                return V2ExtractResp(ok=False, reason="extract_failed")
            return V2ExtractResp(
                ok=True,
                text=text,
                title=result.get("title"),
                byline=result.get("byline"),
            )
        # Plain string
        if not result:
            return V2ExtractResp(ok=False, reason="extract_failed")
        return V2ExtractResp(ok=True, text=result)

    @app.post("/v2/summarize")
    def v2_summarize(req: V2SummarizeReq) -> V2SummarizeResp:
        text = (req.text or "").strip()
        if not text:
            raise HTTPException(
                status_code=400,
                detail={"ok": False, "reason": "empty"},
            )
        summary = app.state.summarize(
            text,
            model=cfg["summary_model"],
            base_url=cfg["ollama_url"],
            think=cfg["summary_think"],
            timeout=cfg["summary_timeout"],
        )
        return V2SummarizeResp(ok=True, summary=summary)

    @app.get("/v2/health")
    def v2_health() -> V2Health:
        return V2Health(
            ok=True,
            version=__version__,
            engine_up=_check_engine_cached(),
        )

    return app
