"""Render jobs: long text to a finished audio file, in the background.

One worker thread, FIFO. The library is persisted so it survives a daemon
restart: `index.json` holds every job's public record, `sources/<id>.json`
holds a queued job's text until it has rendered (so a queued job picks up
again after a restart), and the finished file is `<id>.<ext>`.

Live reads win. Before every chunk the worker waits while the state machine
is `thinking` or `speaking` (or an engine switch is loading a model), so the
hotkey still speaks at once during a long render. Cancel takes effect between
chunks. A job that was rendering when the daemon stopped comes back `failed`
with reason `interrupted`; its partial audio is discarded.

Nothing here touches the state machine except to read it.
"""

from __future__ import annotations

import json
import logging
import os
import re
import secrets
import tempfile
import threading
import time
from pathlib import Path
from typing import Callable, Optional

from . import encode
from . import engines as engine_catalog
from .render import (
    PcmSink,
    RenderError,
    parse_wav,
    plan_chunks,
    preview_of,
    render_chunk_chars,
    synthesize_chunk,
)

logger = logging.getLogger(__name__)

DEFAULT_DIR = Path("~/Library/Application Support/Myna/renders")

JOB_FORMATS = ("m4a", "mp3", "wav", "aac", "flac", "opus")
ACTIVE = ("queued", "rendering", "encoding")
_ID_RE = re.compile(r"^r_[0-9a-f]{8}$")

# A read in `thinking` longer than this is a stale state (an interrupted
# synth), not a read; the voice-preview endpoint uses the same rule.
_STALE_THINKING_MS = 45_000
_YIELD_POLL_S = 0.25
# Engine hiccups (the supervisor restarts a dead engine within ~5 s; some
# engines 502 on the odd sentence) shouldn't fail an hour-long render.
_CHUNK_RETRIES = (2.0, 5.0, 10.0)

_PUBLIC_FIELDS = (
    "id", "title", "status", "source", "created_at", "started_at", "finished_at",
    "engine", "voice", "speed", "format", "chars", "words", "chunks_total",
    "chunks_done", "progress", "audio_s", "eta_s", "file_path", "bytes",
    "chapters", "error", "preview",
)


def valid_id(job_id: str) -> bool:
    return bool(_ID_RE.match(job_id or ""))


def _atomic_write(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


class RenderJobs:
    def __init__(
        self,
        app,
        directory: Path,
        *,
        retries: tuple[float, ...] = _CHUNK_RETRIES,
        yield_poll_s: float = _YIELD_POLL_S,
        clock: Callable[[], float] = time.time,
    ):
        self._app = app
        self.dir = Path(directory).expanduser()
        self._retries = retries
        self._poll = yield_poll_s
        self._clock = clock
        self._lock = threading.RLock()
        self._wake = threading.Condition(self._lock)
        self._jobs: dict[str, dict] = {}
        self._sources: dict[str, dict] = {}
        self._cancel: set[str] = set()
        self._stop = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._loaded = False

    # ----- lifecycle -----

    def start(self) -> None:
        """Load the library and start the worker. Idempotent."""
        with self._lock:
            self._load()
            if self._thread is None or not self._thread.is_alive():
                self._stop.clear()
                self._thread = threading.Thread(target=self._run, name="myna-render", daemon=True)
                self._thread.start()

    def stop(self, timeout: float = 2.0) -> None:
        self._stop.set()
        with self._wake:
            self._wake.notify_all()
        if self._thread is not None:
            self._thread.join(timeout=timeout)

    def _load(self) -> None:
        if self._loaded:
            return
        self._loaded = True
        index = self.dir / "index.json"
        if not index.exists():
            return
        try:
            records = json.loads(index.read_text(encoding="utf-8")).get("renders", [])
        except (OSError, ValueError) as exc:
            logger.warning("render index unreadable, starting empty: %s", exc)
            return
        changed = False
        for rec in records:
            if not isinstance(rec, dict) or not valid_id(rec.get("id", "")):
                continue
            job = {k: rec.get(k) for k in _PUBLIC_FIELDS}
            if job["status"] in ("rendering", "encoding"):
                self._fail(job, "interrupted", "Myna's voice service stopped while this was rendering.")
                self._partial_path(job["id"]).unlink(missing_ok=True)
                self._source_path(job["id"]).unlink(missing_ok=True)
                changed = True
            elif job["status"] == "queued" and not self._source_path(job["id"]).exists():
                self._fail(job, "interrupted", "The text for this render was lost.")
                changed = True
            self._jobs[job["id"]] = job
        if changed:
            self._persist()

    # ----- paths -----

    def _source_path(self, job_id: str) -> Path:
        return self.dir / "sources" / f"{job_id}.json"

    def _partial_path(self, job_id: str) -> Path:
        return self.dir / f"{job_id}.partial.wav"

    def _persist(self) -> None:
        self.dir.mkdir(parents=True, exist_ok=True)
        records = sorted(self._jobs.values(), key=lambda j: j["created_at"] or 0, reverse=True)
        _atomic_write(self.dir / "index.json", json.dumps({"renders": records}, indent=1) + "\n")

    # ----- public API (called from request threads) -----

    def create(
        self,
        *,
        title: str,
        sections: list[dict],
        voice: str,
        speed: float,
        fmt: str,
        source: str,
        section_pause_ms: int,
        chunk_chars: int,
    ) -> dict:
        spec = engine_catalog.active_spec(self._app.state.cfg)
        text = "\n\n".join(s["text"] for s in sections)
        plans = [plan_chunks(s["text"], chunk_chars) for s in sections]
        with self._lock:
            self._load()
            job_id = self._new_id()
            job = {
                "id": job_id,
                "title": title,
                "status": "queued",
                "source": source,
                "created_at": self._clock(),
                "started_at": None,
                "finished_at": None,
                "engine": spec.id,
                "voice": voice,
                "speed": speed,
                "format": fmt,
                "chars": sum(len(c) for p in plans for c in p),
                "words": len(text.split()),
                "chunks_total": sum(len(p) for p in plans),
                "chunks_done": 0,
                "progress": 0.0,
                "audio_s": 0.0,
                "eta_s": None,
                "file_path": None,
                "bytes": None,
                "chapters": [] if len(sections) > 1 else None,
                "error": None,
                "preview": preview_of(text),
            }
            source_rec = {
                "sections": sections,
                "section_pause_ms": section_pause_ms,
                "chunk_chars": chunk_chars,
            }
            self.dir.mkdir(parents=True, exist_ok=True)
            self._source_path(job_id).parent.mkdir(parents=True, exist_ok=True)
            _atomic_write(self._source_path(job_id), json.dumps(source_rec))
            self._jobs[job_id] = job
            self._sources[job_id] = source_rec
            self._persist()
            self._wake.notify_all()
            return dict(job)

    def all_jobs(self) -> list[dict]:
        with self._lock:
            self._load()
            return [dict(j) for j in sorted(self._jobs.values(), key=lambda j: j["created_at"] or 0, reverse=True)]

    def get(self, job_id: str) -> Optional[dict]:
        with self._lock:
            self._load()
            job = self._jobs.get(job_id)
            return dict(job) if job else None

    def cancel(self, job_id: str) -> Optional[dict]:
        with self._lock:
            self._load()
            job = self._jobs.get(job_id)
            if job is None:
                return None
            if job["status"] in ACTIVE:
                self._cancel.add(job_id)
                job["status"] = "cancelled"
                job["finished_at"] = self._clock()
                job["eta_s"] = None
                self._source_path(job_id).unlink(missing_ok=True)
                self._sources.pop(job_id, None)
                self._persist()
                self._wake.notify_all()
            return dict(job)

    def delete(self, job_id: str) -> bool:
        with self._lock:
            self._load()
            job = self._jobs.pop(job_id, None)
            if job is None:
                return False
            self._cancel.add(job_id)
            self._sources.pop(job_id, None)
            self._source_path(job_id).unlink(missing_ok=True)
            if job.get("file_path"):
                Path(job["file_path"]).unlink(missing_ok=True)
            self._persist()
            self._wake.notify_all()
            return True

    def file_for(self, job_id: str) -> Optional[Path]:
        job = self.get(job_id)
        if not job or job["status"] != "done" or not job.get("file_path"):
            return None
        path = Path(job["file_path"])
        return path if path.exists() else None

    # ----- worker -----

    def _new_id(self) -> str:
        while True:
            job_id = "r_" + secrets.token_hex(4)
            if job_id not in self._jobs:
                return job_id

    def _next_queued(self) -> Optional[dict]:
        with self._wake:
            while not self._stop.is_set():
                queued = [j for j in self._jobs.values() if j["status"] == "queued"]
                if queued:
                    return min(queued, key=lambda j: j["created_at"] or 0)
                self._wake.wait(timeout=5.0)
            return None

    def _run(self) -> None:
        while not self._stop.is_set():
            job = self._next_queued()
            if job is None:
                return
            try:
                self._render(job)
            except Exception as exc:  # never let one job kill the worker
                logger.exception("render %s crashed", job["id"])
                with self._lock:
                    if self._jobs.get(job["id"]) is job and job["status"] in ACTIVE:
                        self._fail(job, "render_failed", str(exc)[:500])
                        self._persist()
                self._partial_path(job["id"]).unlink(missing_ok=True)

    def _cancelled(self, job: dict) -> bool:
        with self._lock:
            return job["id"] in self._cancel or self._jobs.get(job["id"]) is not job

    def _live_read_busy(self) -> bool:
        state = self._app.state
        if getattr(state, "engine_switch", None):
            return True
        machine = state.machine
        if machine.state == "speaking":
            return True
        return machine.state == "thinking" and machine.since_ms() < _STALE_THINKING_MS

    def _wait_for_live_reads(self, job: dict) -> None:
        while self._live_read_busy() and not self._cancelled(job) and not self._stop.is_set():
            self._stop.wait(self._poll)

    def _fail(self, job: dict, reason: str, detail: str) -> None:
        job["status"] = "failed"
        job["error"] = {"reason": reason, "detail": detail}
        job["finished_at"] = self._clock()
        job["eta_s"] = None

    def _render(self, job: dict) -> None:
        job_id = job["id"]
        cfg = self._app.state.cfg
        with self._lock:
            src = self._sources.get(job_id)
        if src is None:
            try:
                src = json.loads(self._source_path(job_id).read_text(encoding="utf-8"))
            except (OSError, ValueError):
                with self._lock:
                    self._fail(job, "interrupted", "The text for this render was lost.")
                    self._persist()
                return

        with self._lock:
            if self._cancelled(job):
                return
            job["status"] = "rendering"
            job["started_at"] = self._clock()
            self._persist()

        sections = src["sections"]
        pause_ms = int(src.get("section_pause_ms") or 0)
        chunk_chars = int(src.get("chunk_chars") or render_chunk_chars(cfg))
        plans = [plan_chunks(s["text"], chunk_chars) for s in sections]
        chars_total = max(1, sum(len(c) for p in plans for c in p))
        chars_done = 0
        synth_s = 0.0
        partial = self._partial_path(job_id)
        sink = PcmSink(path=str(partial))
        chapters: list[dict] = []

        try:
            for s_idx, (section, plan) in enumerate(zip(sections, plans)):
                if s_idx > 0 and sink.frames:
                    sink.add_silence(pause_ms)
                chapter = {"title": section.get("title") or f"Section {s_idx + 1}", "start_s": round(sink.seconds, 3)}
                for c_idx, chunk in enumerate(plan):
                    self._wait_for_live_reads(job)
                    if self._cancelled(job) or self._stop.is_set():
                        return
                    active = engine_catalog.active_spec(self._app.state.cfg)
                    if active.id != job["engine"]:
                        raise RenderError(
                            "engine_changed",
                            f"The voice engine changed to {active.name} while this was rendering. Start it again.",
                        )
                    t0 = time.monotonic()
                    wav = synthesize_chunk(
                        self._app, chunk, voice=job["voice"], speed=job["speed"], retries=self._retries,
                    )
                    synth_s += time.monotonic() - t0
                    params, pcm = parse_wav(wav)
                    sink.add(params, pcm)
                    chars_done += len(chunk)
                    with self._lock:
                        if c_idx == 0 and job["chapters"] is not None:
                            chapters.append(chapter)
                            job["chapters"] = list(chapters)
                        job["chunks_done"] += 1
                        job["progress"] = round(min(1.0, chars_done / chars_total), 4)
                        job["audio_s"] = round(sink.seconds, 2)
                        if job["chunks_done"] >= 2:
                            job["eta_s"] = round(synth_s / chars_done * (chars_total - chars_done), 1)
            sink.close()
            if sink.params is None:
                raise RenderError("empty", "There was nothing to speak.")

            with self._lock:
                if self._cancelled(job):
                    return
                job["status"] = "encoding"
                job["eta_s"] = None
                self._persist()

            out = self.dir / f"{job_id}.{encode.FORMATS[job['format']].ext}"
            try:
                encode.encode_file(
                    partial, job["format"], out, chapters=job["chapters"], title=job["title"],
                )
            except (encode.FormatUnavailable, encode.EncodeError) as exc:
                raise RenderError("encode_failed", str(exc)) from None

            with self._lock:
                if self._cancelled(job):
                    out.unlink(missing_ok=True)
                    return
                job["status"] = "done"
                job["finished_at"] = self._clock()
                job["progress"] = 1.0
                job["eta_s"] = 0.0
                job["audio_s"] = round(sink.seconds, 2)
                job["file_path"] = str(out)
                job["bytes"] = out.stat().st_size
                self._source_path(job_id).unlink(missing_ok=True)
                self._sources.pop(job_id, None)
                self._persist()
        except RenderError as exc:
            with self._lock:
                if not self._cancelled(job):
                    self._fail(job, exc.reason, exc.detail)
                    self._source_path(job_id).unlink(missing_ok=True)
                    self._sources.pop(job_id, None)
                    self._persist()
        finally:
            sink.close()
            partial.unlink(missing_ok=True)
            with self._lock:
                self._cancel.discard(job_id)


def renders_dir(cfg: dict, *, port: Optional[int], primary: bool, persist_config: bool) -> Path:
    """Where the library lives.

    `renders_dir` in config wins. An app built without persistence (every
    test) gets a fresh temp folder, never the user's. The daemon the app
    talks to uses ~/Library/Application Support/Myna/renders. A second daemon
    on another port (a dev worktree, a test instance) shares the user's
    config but must not share the library, since two workers rewriting one
    index.json lose each other's jobs, so it gets `renders-<port>` beside it.
    """
    if cfg.get("renders_dir"):
        return Path(os.path.expanduser(cfg["renders_dir"]))
    if not persist_config:
        return Path(tempfile.mkdtemp(prefix="myna-renders-"))
    base = DEFAULT_DIR.expanduser()
    return base if primary else base.with_name(f"renders-{port or 'dev'}")
