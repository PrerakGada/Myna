"""HTTP routes for the render API (docs/native-app/RENDER_API.md).

Registered from create_app with one call, `register_render_routes`, so the
rest of app.py doesn't change shape. Section numbers below match the doc:

  1. OpenAI-compatible speech — /v1/audio/speech, /v1/models, /v1/audio/voices
  2. Render jobs — /v2/renders…
  3. Formats and transcoding — /v2/formats, /v2/transcode
  4. API access — /v2/api/settings, /v2/api/log

/v1/* answers errors in OpenAI's shape so OpenAI SDKs surface them; /v2/*
keeps the daemon's `{"ok": false, "reason", "detail"}`.
"""

from __future__ import annotations

import contextlib
import re
import threading
import time
from typing import Literal, Optional

from fastapi import Request
from fastapi.exception_handlers import request_validation_exception_handler
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, Response
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from . import encode
from . import engines as engine_catalog
from . import render_jobs as jobs_mod
from .api_access import ApiAccess, is_loopback_client, openai_error
from .render import (
    OPENAI_MODEL_ALIASES,
    SPEED_ACCEPT,
    RenderError,
    clamp_speed,
    default_voice_id,
    engine_voices,
    openai_voice_map,
    plan_chunks,
    render_chunk_chars,
    render_to_wav,
    resolve_engine,
    resolve_render_voice,
)

SPEECH_MAX_CHARS = 40_000
JOB_MAX_CHARS = 2_000_000
DEFAULT_SECTION_PAUSE_MS = 1200
_SPEECH_RETRIES = (1.0,)


class SpeechReq(BaseModel):
    input: str
    model: Optional[str] = None
    voice: Optional[str] = None
    response_format: Optional[str] = "mp3"
    speed: Optional[float] = None
    instructions: Optional[str] = None  # accepted, ignored
    # Myna's own: "auto" (the default) cleans markdown, code and URLs out
    # with the base pass; "literal" reads the input as written. OpenAI
    # clients never send it, and unknown fields are ignored as before.
    myna_prep: Optional[Literal["auto", "literal"]] = None


class RenderSectionReq(BaseModel):
    title: Optional[str] = None
    text: str


class RenderReq(BaseModel):
    title: Optional[str] = None
    text: Optional[str] = None
    url: Optional[str] = None
    sections: Optional[list[RenderSectionReq]] = None
    voice: Optional[str] = None
    speed: Optional[float] = None
    format: str = "m4a"
    source: Optional[str] = None
    section_pause_ms: Optional[int] = None
    # Text prep: "auto" cleans per the source's preset, "literal" reads as
    # written. `source_kind` is the document's kind (Studio: web, pdf, epub,
    # markdown, …); web/pdf/epub, or a `url`, get the article preset.
    prep: Literal["auto", "literal"] = "auto"
    source_kind: Optional[str] = None


class ApiSettingsUpdate(BaseModel):
    lan_enabled: Optional[bool] = None
    regenerate_key: Optional[bool] = None


def _v2_error(status: int, reason: str, detail: str = "") -> JSONResponse:
    body = {"ok": False, "reason": reason}
    if detail:
        body["detail"] = detail
    return JSONResponse(status_code=status, content=body)


def _port(request: Request, cfg: dict) -> int:
    server = request.scope.get("server")
    return server[1] if server and server[1] else cfg["daemon_port"]


def _log(request: Request, **fields) -> None:
    """Annotate this request's API-log entry (AccessMiddleware writes it)."""
    extra = request.scope.get("myna.log")
    if isinstance(extra, dict):
        extra.update({k: v for k, v in fields.items() if v is not None})


def _title_from_text(text: str) -> str:
    first = next((line.strip() for line in text.splitlines() if line.strip()), "")
    first = re.sub(r"^#+\s*", "", first)
    return (first[:77].rstrip() + "…") if len(first) > 80 else (first or "Untitled")


def register_render_routes(app, cfg: dict, *, persist_config: bool) -> None:
    access = ApiAccess(cfg, save_config=app.state.save_config, persist_config=persist_config)
    app.state.api_access = access
    if not hasattr(app.state, "render_jobs"):
        app.state.render_jobs = None
    jobs_lock = threading.Lock()

    def jobs_for(port: Optional[int]) -> jobs_mod.RenderJobs:
        """The job store, created on first use (so building the app, as
        every test does, never reads or writes a renders folder)."""
        with jobs_lock:
            if app.state.render_jobs is None:
                directory = jobs_mod.renders_dir(
                    cfg, port=port, primary=access.primary(port), persist_config=persist_config,
                )
                app.state.render_jobs = jobs_mod.RenderJobs(app, directory)
            jobs = app.state.render_jobs
        jobs.start()
        return jobs

    # Resume queued renders when the service boots, stop the worker with the
    # daemon. Wraps create_app's own lifespan rather than editing it.
    inner_lifespan = app.router.lifespan_context

    @contextlib.asynccontextmanager
    async def _lifespan(a):
        port = getattr(app.state, "service_port", None)
        if port is not None:
            jobs_for(port)
        try:
            async with inner_lifespan(a) as state:
                yield state
        finally:
            if app.state.render_jobs is not None:
                app.state.render_jobs.stop()

    app.router.lifespan_context = _lifespan

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request, exc: RequestValidationError):
        if not request.url.path.startswith("/v1/"):
            return await request_validation_exception_handler(request, exc)
        errors = exc.errors()
        err = errors[0] if errors else {}
        loc = [str(p) for p in err.get("loc", ()) if p != "body"]
        param = loc[0] if loc else None
        code = "empty_input" if param == "input" and err.get("type") == "missing" else "invalid_request"
        return openai_error(400, code, f"{'.'.join(loc) or 'body'}: {err.get('msg', 'invalid')}", param)

    # ----- 1. OpenAI-compatible speech -----

    @app.post("/v1/audio/speech")
    def v1_audio_speech(req: SpeechReq, request: Request):
        fmt = (req.response_format or "mp3").lower()
        _log(request, chars=len(req.input), format=fmt)
        if not req.input.strip():
            return openai_error(400, "empty_input", "input is empty.", "input")
        if len(req.input) > SPEECH_MAX_CHARS:
            return openai_error(
                413, "input_too_long",
                f"input is {len(req.input):,} characters; the limit is {SPEECH_MAX_CHARS:,}. "
                "Use POST /v2/renders for long text.",
                "input",
            )
        if fmt not in encode.FORMATS:
            return openai_error(
                400, "invalid_format",
                f"response_format must be one of {', '.join(encode.FORMATS)}.", "response_format",
            )
        try:
            spec = encode.require(fmt)
        except encode.FormatUnavailable as exc:
            return openai_error(400, "format_unavailable", str(exc), "response_format")
        if req.speed is not None and not SPEED_ACCEPT[0] <= req.speed <= SPEED_ACCEPT[1]:
            return openai_error(400, "invalid_speed", "speed must be between 0.25 and 4.0.", "speed")
        try:
            engine = resolve_engine(cfg, req.model)
        except RenderError as exc:
            return openai_error(exc.status, exc.reason, exc.detail, "model")

        text = app.state.speakable(req.input, source="api", prep=req.myna_prep or "auto")
        if not text:
            return openai_error(
                400, "empty_input",
                "input has nothing to speak once markup is removed; send \"myna_prep\": \"literal\" "
                "to read it as written.",
                "input",
            )
        voice = resolve_render_voice(app, req.voice)
        speed = clamp_speed(req.speed, engine)
        _log(request, voice=voice)
        chunks = plan_chunks(text, render_chunk_chars(cfg))
        started = time.monotonic()
        try:
            wav, params, count, seconds = render_to_wav(
                app, chunks, voice=voice, speed=speed, retries=_SPEECH_RETRIES,
            )
            body = encode.encode_bytes(wav, fmt)
        except RenderError as exc:
            return openai_error(exc.status, exc.reason, exc.detail or exc.reason)
        except (encode.FormatUnavailable, encode.EncodeError) as exc:
            return openai_error(500, "encode_failed", str(exc))
        _log(request, audio_s=round(seconds, 2))
        return Response(
            content=body,
            media_type=spec.mime,
            headers={
                "X-Myna-Engine": engine.id,
                "X-Myna-Voice": voice,
                "X-Myna-Duration-S": f"{seconds:.2f}",
                "X-Myna-Sample-Rate": str(params.rate),
                "X-Myna-Chunks": str(count),
                "X-Myna-Render-Ms": str(int((time.monotonic() - started) * 1000)),
            },
        )

    @app.get("/v1/models")
    def v1_models():
        active = engine_catalog.active_spec(cfg)
        store = app.state.engine_store
        created = int(app.state.started_at)
        data = []
        for spec in engine_catalog.CATALOG:
            usable = (
                spec.id == active.id
                or spec.id == engine_catalog.DEFAULT_ENGINE_ID
                or store.is_installed(spec)
            )
            if usable:
                data.append({
                    "id": spec.id, "object": "model", "created": created,
                    "owned_by": "myna", "name": spec.name, "active": spec.id == active.id,
                })
        for alias in OPENAI_MODEL_ALIASES:
            data.append({
                "id": alias, "object": "model", "created": created,
                "owned_by": "myna", "active": True, "alias_of": active.id,
            })
        return {"object": "list", "data": data}

    @app.get("/v1/audio/voices")
    def v1_audio_voices():
        spec = engine_catalog.active_spec(cfg)
        voices = engine_voices(app)
        return {
            "engine": spec.id,
            "voices": voices,
            "openai_aliases": openai_voice_map(voices, default_voice_id(cfg)),
        }

    # ----- 2. Render jobs -----

    @app.post("/v2/renders", status_code=201)
    def v2_renders_create(req: RenderReq, request: Request):
        given = [x for x in (req.text, req.url, req.sections) if x is not None]
        if len(given) != 1:
            return _v2_error(400, "one_input_required", "Send exactly one of text, url or sections.")

        title = (req.title or "").strip()
        if req.url is not None:
            url = req.url.strip()
            if not (url.startswith("http://") or url.startswith("https://")):
                return _v2_error(400, "invalid_url", "url must start with http:// or https://.")
            extracted = app.state.extract(url)
            if isinstance(extracted, dict):
                title = title or (extracted.get("title") or "").strip()
                extracted = extracted.get("text")
            if not extracted or not str(extracted).strip():
                return _v2_error(400, "extract_failed", "Couldn't find readable text at that address.")
            sections = [{"title": "", "text": str(extracted).strip()}]
        elif req.sections is not None:
            sections = [
                {"title": (s.title or "").strip(), "text": s.text.strip()}
                for s in req.sections if s.text and s.text.strip()
            ]
        else:
            sections = [{"title": "", "text": (req.text or "").strip()}]
        sections = [s for s in sections if s["text"]]
        if not sections:
            return _v2_error(400, "empty", "There's no text to render.")
        chars = sum(len(s["text"]) for s in sections)
        _log(request, chars=chars, format=req.format)
        if chars > JOB_MAX_CHARS:
            return _v2_error(413, "input_too_long", f"The limit for one render is {JOB_MAX_CHARS:,} characters.")

        fmt = (req.format or "m4a").lower()
        if fmt not in jobs_mod.JOB_FORMATS:
            return _v2_error(400, "invalid_format", f"format must be one of {', '.join(jobs_mod.JOB_FORMATS)}.")
        try:
            encode.require(fmt)
        except encode.FormatUnavailable as exc:
            return _v2_error(400, "format_unavailable", str(exc))
        if req.speed is not None and not SPEED_ACCEPT[0] <= req.speed <= SPEED_ACCEPT[1]:
            return _v2_error(400, "invalid_speed", "speed must be between 0.25 and 4.0.")

        if not title:
            title = sections[0]["title"] or _title_from_text(sections[0]["text"])
        # The words to render (myna.speakable), per section so chapter
        # markers still line up. Titles are display-only and stay as given.
        sections = [
            {"title": s["title"], "text": app.state.speakable(
                s["text"], source=req.source, prep=req.prep, kind=req.source_kind, url=req.url is not None,
            )}
            for s in sections
        ]
        sections = [s for s in sections if s["text"]]
        if not sections:
            return _v2_error(400, "empty", "There's nothing to render once markup is removed; send prep: literal.")

        spec = engine_catalog.active_spec(cfg)
        voice = resolve_render_voice(app, req.voice)
        _log(request, voice=voice)
        pause = req.section_pause_ms
        pause = DEFAULT_SECTION_PAUSE_MS if pause is None else max(0, min(10_000, int(pause)))

        jobs = jobs_for(_port(request, cfg))
        job = jobs.create(
            title=title[:200],
            sections=sections,
            voice=voice,
            speed=clamp_speed(req.speed, spec),
            fmt=fmt,
            source=(req.source or "api").strip()[:32] or "api",
            section_pause_ms=pause,
            chunk_chars=render_chunk_chars(cfg),
        )
        return JSONResponse(status_code=201, content=job)

    @app.get("/v2/renders")
    def v2_renders_list(request: Request):
        return {"renders": jobs_for(_port(request, cfg)).all_jobs()}

    @app.get("/v2/renders/{job_id}")
    def v2_renders_get(job_id: str, request: Request):
        job = jobs_for(_port(request, cfg)).get(job_id) if jobs_mod.valid_id(job_id) else None
        return job if job is not None else _v2_error(404, "not_found", "No render with that id.")

    @app.get("/v2/renders/{job_id}/audio")
    def v2_renders_audio(job_id: str, request: Request):
        jobs = jobs_for(_port(request, cfg))
        job = jobs.get(job_id) if jobs_mod.valid_id(job_id) else None
        if job is None:
            return _v2_error(404, "not_found", "No render with that id.")
        if job["status"] != "done":
            return _v2_error(409, "not_ready", f"This render is {job['status']}.")
        path = jobs.file_for(job_id)
        if path is None:
            return _v2_error(404, "file_missing", "The rendered file is no longer on disk.")
        spec = encode.FORMATS[job["format"]]
        _log(request, format=job["format"], voice=job["voice"], audio_s=job["audio_s"])
        safe = re.sub(r'[\\/:*?"<>|\x00-\x1f]+', " ", job["title"]).strip()[:120] or job_id
        return FileResponse(path, media_type=spec.mime, filename=f"{safe}.{spec.ext}")

    @app.post("/v2/renders/{job_id}/cancel")
    def v2_renders_cancel(job_id: str, request: Request):
        job = jobs_for(_port(request, cfg)).cancel(job_id) if jobs_mod.valid_id(job_id) else None
        return job if job is not None else _v2_error(404, "not_found", "No render with that id.")

    @app.delete("/v2/renders/{job_id}")
    def v2_renders_delete(job_id: str, request: Request):
        removed = jobs_for(_port(request, cfg)).delete(job_id) if jobs_mod.valid_id(job_id) else False
        return {"ok": True} if removed else _v2_error(404, "not_found", "No render with that id.")

    # ----- 3. Formats and transcoding -----

    @app.get("/v2/formats")
    def v2_formats():
        return {"formats": encode.formats_payload()}

    @app.post("/v2/transcode")
    async def v2_transcode(request: Request, format: str = "m4a"):
        fmt = format.lower()
        if fmt not in encode.FORMATS:
            return _v2_error(400, "invalid_format", f"format must be one of {', '.join(encode.FORMATS)}.")
        body = await request.body()
        if len(body) < 44 or body[:4] != b"RIFF" or body[8:12] != b"WAVE":
            return _v2_error(400, "invalid_audio", "Send the audio as a WAV file (audio/wav).")
        _log(request, format=fmt)
        try:
            spec = encode.require(fmt)
            out = await run_in_threadpool(encode.encode_bytes, body, fmt)
        except encode.FormatUnavailable as exc:
            return _v2_error(400, "format_unavailable", str(exc))
        except encode.EncodeError as exc:
            return _v2_error(500, "encode_failed", str(exc))
        return Response(content=out, media_type=spec.mime)

    # ----- 4. API access -----

    def _is_loopback(request: Request) -> bool:
        client = request.scope.get("client")
        return is_loopback_client(client[0] if client else None)

    @app.get("/v2/api/settings")
    def v2_api_settings(request: Request):
        return access.settings(_port(request, cfg), loopback=_is_loopback(request))

    @app.post("/v2/api/settings")
    def v2_api_settings_update(update: ApiSettingsUpdate, request: Request):
        port = _port(request, cfg)
        if update.regenerate_key:
            access.regenerate_key(port)
        if update.lan_enabled is not None:
            access.set_lan(update.lan_enabled, port)
        return access.settings(port, loopback=_is_loopback(request))

    @app.get("/v2/api/log")
    def v2_api_log(limit: int = 100):
        return {"requests": access.recent(limit)}
