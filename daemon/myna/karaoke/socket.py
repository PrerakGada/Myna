"""KaraokeClient — NDJSON writer over Unix socket to the MynaKaraoke sidecar.

Daemon is the CLIENT writing to the socket; sidecar is the SERVER listening.
The sidecar is spawned on demand by `connect()` if a binary path is known
(env MYNA_KARAOKE_BINARY for dev, or apps/macos's nested
Resources/MynaKaraoke.app binary in production).

Protocol (locked for v0.2 — Track C reads these exact shapes):

    {"v":1,"type":"start","id":"u_...","sentence":"...",
     "words":[{"i":0,"t":"Hello"}, ...], "estimatedDurationMs":int,
     "voice":"af_heart"}
    {"v":1,"type":"word","id":"u_...","i":2,"tMs":1100}
    {"v":1,"type":"pause","id":"u_..."}
    {"v":1,"type":"resume","id":"u_...","tMs":1100}
    {"v":1,"type":"stop","id":"u_..."}
    {"v":1,"type":"config","fontSize":18,"position":"bottom","theme":"dark","opacity":0.95}

Reconnect policy:
    - On EPIPE / OSError while writing, the FD is closed.
    - We retry with 500ms backoff, up to MAX_RETRIES (default 3) inside a
      single send call. After that the client disables itself for the
      session (no further connect attempts) so audio stays unaffected.
    - The most-recent `start` message and the most-recent `word` event are
      cached and replayed on every successful reconnect.

Socket path: ~/.myna/karaoke.sock (mode 0600, parent dir 0700).
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import pathlib
from typing import Optional


logger = logging.getLogger(__name__)


DEFAULT_SOCKET_PATH = pathlib.Path.home() / ".myna" / "karaoke.sock"
PROTOCOL_VERSION = 1
MAX_RETRIES = 3
BACKOFF_S = 0.5


def ensure_socket_dir(path: pathlib.Path) -> None:
    """Create the parent dir with 0700 if it doesn't already exist."""
    parent = path.parent
    if not parent.exists():
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)


class KaraokeClient:
    """Async NDJSON writer.

    Caller responsibility: instantiate once per app, call connect() before
    the first emit, and never assume connect() succeeded (the client
    silently disables itself if the sidecar can't be reached and audio
    must keep flowing regardless).

    All public emit_* methods are coroutines and never raise. Failure paths
    fold into the disable-this-session flag.
    """

    def __init__(
        self,
        socket_path: Optional[pathlib.Path] = None,
        *,
        binary_path: Optional[str] = None,
        max_retries: int = MAX_RETRIES,
        backoff_s: float = BACKOFF_S,
    ):
        self.socket_path = socket_path or DEFAULT_SOCKET_PATH
        # binary_path resolution order:
        #   ctor arg -> env MYNA_KARAOKE_BINARY -> None (no spawn possible)
        self.binary_path = binary_path or os.environ.get(
            "MYNA_KARAOKE_BINARY"
        )
        self.max_retries = max_retries
        self.backoff_s = backoff_s

        self._writer: Optional[asyncio.StreamWriter] = None
        self._reader: Optional[asyncio.StreamReader] = None
        self._sidecar_proc: Optional[asyncio.subprocess.Process] = None
        self._disabled: bool = False

        # Replay cache for reconnect
        self._last_start: Optional[dict] = None
        self._last_word: Optional[dict] = None

    # ----- public API -----

    @property
    def disabled(self) -> bool:
        return self._disabled

    async def connect(self) -> bool:
        """Best-effort: connect to existing socket, else spawn sidecar.

        Returns True on success, False otherwise (client disables itself
        for the session if all spawn paths fail).
        """
        if self._disabled:
            return False
        if self._writer is not None:
            return True
        ensure_socket_dir(self.socket_path)
        # First try the existing socket (sidecar already running, e.g. dev)
        if self.socket_path.exists():
            if await self._open_existing():
                return True
        # Spawn the sidecar binary if we have a path
        if self.binary_path:
            if await self._spawn_and_connect():
                return True
        logger.info(
            "karaoke: no sidecar binary available "
            "(set MYNA_KARAOKE_BINARY or provide ctor arg); "
            "disabling for this session"
        )
        self._disabled = True
        return False

    async def emit_start(
        self,
        utterance_id: str,
        sentence: str,
        words: list[str],
        estimated_duration_ms: int,
        voice: str,
    ) -> bool:
        msg = {
            "v": PROTOCOL_VERSION,
            "type": "start",
            "id": utterance_id,
            "sentence": sentence,
            "words": [{"i": i, "t": w} for i, w in enumerate(words)],
            "estimatedDurationMs": int(estimated_duration_ms),
            "voice": voice,
        }
        self._last_start = msg
        self._last_word = None
        return await self._send(msg)

    async def emit_word(self, utterance_id: str, i: int, t_ms: int) -> bool:
        msg = {
            "v": PROTOCOL_VERSION,
            "type": "word",
            "id": utterance_id,
            "i": int(i),
            "tMs": int(t_ms),
        }
        self._last_word = msg
        return await self._send(msg)

    async def emit_pause(self, utterance_id: str) -> bool:
        msg = {"v": PROTOCOL_VERSION, "type": "pause", "id": utterance_id}
        return await self._send(msg)

    async def emit_resume(self, utterance_id: str, t_ms: int) -> bool:
        msg = {
            "v": PROTOCOL_VERSION,
            "type": "resume",
            "id": utterance_id,
            "tMs": int(t_ms),
        }
        return await self._send(msg)

    async def emit_stop(self, utterance_id: str) -> bool:
        msg = {"v": PROTOCOL_VERSION, "type": "stop", "id": utterance_id}
        ok = await self._send(msg)
        self._last_start = None
        self._last_word = None
        return ok

    async def emit_config(
        self,
        *,
        font_size: Optional[int] = None,
        position: Optional[str] = None,
        theme: Optional[str] = None,
        opacity: Optional[float] = None,
    ) -> bool:
        msg: dict = {"v": PROTOCOL_VERSION, "type": "config"}
        if font_size is not None:
            msg["fontSize"] = int(font_size)
        if position is not None:
            msg["position"] = position
        if theme is not None:
            msg["theme"] = theme
        if opacity is not None:
            msg["opacity"] = float(opacity)
        return await self._send(msg)

    async def close(self) -> None:
        """Shut down cleanly. Safe to call multiple times."""
        await self._teardown_writer()
        if self._sidecar_proc is not None:
            with contextlib.suppress(BaseException):
                self._sidecar_proc.terminate()
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(
                        self._sidecar_proc.wait(),
                        timeout=2.0,
                    )
            self._sidecar_proc = None

    # ----- internals -----

    async def _send(self, msg: dict) -> bool:
        """Write one NDJSON frame with reconnect-on-failure.

        Returns True on success, False if the message couldn't be delivered
        within max_retries attempts (the client disables itself).
        """
        if self._disabled:
            return False
        line = (json.dumps(msg, separators=(",", ":")) + "\n").encode()
        for attempt in range(self.max_retries):
            if self._writer is None:
                if not await self.connect():
                    return False
            try:
                self._writer.write(line)
                await self._writer.drain()
                return True
            except (BrokenPipeError, ConnectionResetError, OSError) as exc:
                logger.info(
                    "karaoke: send failed attempt=%d err=%s; reconnecting",
                    attempt,
                    exc,
                )
                await self._teardown_writer()
                await asyncio.sleep(self.backoff_s)
                # Replay cached state on a fresh connection.
                if await self.connect():
                    await self._replay_cache()
        logger.info(
            "karaoke: giving up after %d attempts; disabling",
            self.max_retries,
        )
        self._disabled = True
        return False

    async def _replay_cache(self) -> None:
        """Re-send cached start + last word after a reconnect."""
        if self._last_start is None:
            return
        try:
            line = (
                json.dumps(self._last_start, separators=(",", ":")) + "\n"
            ).encode()
            self._writer.write(line)
            if self._last_word is not None:
                line = (
                    json.dumps(self._last_word, separators=(",", ":")) + "\n"
                ).encode()
                self._writer.write(line)
            await self._writer.drain()
        except (BrokenPipeError, ConnectionResetError, OSError):
            # Replay failed; leave the writer in a broken state — the next
            # _send call retries through the same path.
            await self._teardown_writer()

    async def _open_existing(self) -> bool:
        try:
            reader, writer = await asyncio.open_unix_connection(
                path=str(self.socket_path)
            )
        except (FileNotFoundError, ConnectionRefusedError, OSError) as exc:
            logger.info("karaoke: connect existing failed: %s", exc)
            return False
        self._reader, self._writer = reader, writer
        return True

    async def _spawn_and_connect(self) -> bool:
        """Spawn the sidecar binary; wait briefly for socket to appear; connect."""
        try:
            proc = await asyncio.create_subprocess_exec(
                self.binary_path,
                "--socket",
                str(self.socket_path),
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
        except (FileNotFoundError, OSError) as exc:
            logger.info("karaoke: spawn failed (%s)", exc)
            return False
        self._sidecar_proc = proc
        # Poll up to 2s for the sidecar to create the socket + start accepting.
        deadline = asyncio.get_event_loop().time() + 2.0
        while asyncio.get_event_loop().time() < deadline:
            if self.socket_path.exists():
                if await self._open_existing():
                    return True
            await asyncio.sleep(0.05)
        logger.info("karaoke: sidecar didn't open socket in 2s; giving up")
        # The proc is still around — terminate it so we don't leak.
        with contextlib.suppress(BaseException):
            proc.terminate()
        self._sidecar_proc = None
        return False

    async def _teardown_writer(self) -> None:
        if self._writer is None:
            return
        with contextlib.suppress(BaseException):
            self._writer.close()
            with contextlib.suppress(BaseException):
                await self._writer.wait_closed()
        self._writer = None
        self._reader = None


class NullKaraokeClient:
    """No-op client used when karaoke is disabled in config.

    Mirrors KaraokeClient's emit_* surface but is a synchronous-friendly
    stub (returns immediately, no coroutine cost beyond the awaitable
    wrapper). The synth orchestration awaits these methods unconditionally;
    using a Null variant lets the orchestration loop stay branch-free.
    """

    @property
    def disabled(self) -> bool:
        return True

    async def connect(self) -> bool:
        return False

    async def emit_start(self, *args, **kwargs) -> bool:
        return False

    async def emit_word(self, *args, **kwargs) -> bool:
        return False

    async def emit_pause(self, *args, **kwargs) -> bool:
        return False

    async def emit_resume(self, *args, **kwargs) -> bool:
        return False

    async def emit_stop(self, *args, **kwargs) -> bool:
        return False

    async def emit_config(self, *args, **kwargs) -> bool:
        return False

    async def close(self) -> None:
        return None


def make_karaoke_client(config: dict) -> "KaraokeClient | NullKaraokeClient":
    """Honor `karaoke.enabled` from the loaded config (default True)."""
    karaoke_cfg = config.get("karaoke") or {}
    if karaoke_cfg.get("enabled", True) is False:
        return NullKaraokeClient()
    return KaraokeClient()


# ---------- sync emitter (drives a background loop in a daemon thread) ----------


class KaraokeEmitter:
    """Synchronous facade: schedules KaraokeClient coroutines onto a
    background asyncio loop running in a dedicated daemon thread.

    The FastAPI sync route handlers cannot await directly; emitter.start(...)
    / emitter.word(...) etc. are non-blocking schedule calls that return
    immediately. The background loop drives the actual writes + reconnect
    logic. Tests can substitute a NullEmitter or a stub.
    """

    def __init__(self, client: "KaraokeClient | NullKaraokeClient"):
        self._client = client
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread = None
        if isinstance(client, NullKaraokeClient):
            self._enabled = False
        else:
            self._enabled = True
            self._start_loop()

    def _start_loop(self) -> None:
        import threading

        self._loop = asyncio.new_event_loop()

        def _run():
            asyncio.set_event_loop(self._loop)
            self._loop.run_forever()

        self._thread = threading.Thread(target=_run, daemon=True)
        self._thread.start()

    def _schedule(self, coro) -> None:
        if not self._enabled or self._loop is None:
            # Drain the coroutine to avoid "coroutine was never awaited"
            # warnings when karaoke is disabled.
            coro.close()
            return
        asyncio.run_coroutine_threadsafe(coro, self._loop)

    # -------- public sync emit API --------

    def start(
        self,
        utterance_id: str,
        sentence: str,
        words: list[str],
        estimated_duration_ms: int,
        voice: str,
    ) -> None:
        self._schedule(
            self._client.emit_start(
                utterance_id,
                sentence,
                words,
                estimated_duration_ms,
                voice,
            )
        )

    def word(self, utterance_id: str, i: int, t_ms: int) -> None:
        self._schedule(self._client.emit_word(utterance_id, i, t_ms))

    def pause(self, utterance_id: str) -> None:
        self._schedule(self._client.emit_pause(utterance_id))

    def resume(self, utterance_id: str, t_ms: int) -> None:
        self._schedule(self._client.emit_resume(utterance_id, t_ms))

    def stop(self, utterance_id: str) -> None:
        self._schedule(self._client.emit_stop(utterance_id))

    def config(self, **kw) -> None:
        self._schedule(self._client.emit_config(**kw))

    def schedule_word_events(
        self,
        utterance_id: str,
        timings: list[tuple[int, int]],
    ) -> None:
        """Schedule a sequence of word events at their relative tMs offsets,
        anchored at "now" on the background loop.

        Each (i, t_ms) becomes an awaitable that sleeps until t_ms past
        the reference time then emits. If the reference time has already
        passed the t_ms (rare; only if synth lagged behind the schedule),
        the event fires immediately.
        """
        if not self._enabled or self._loop is None:
            return
        # Capture loop time on the loop's thread for precise alignment.
        async def _run_all():
            loop = asyncio.get_event_loop()
            t0 = loop.time()
            for i, t_ms in timings:
                target = t0 + (t_ms / 1000.0)
                now = loop.time()
                delay = max(0.0, target - now)
                if delay:
                    await asyncio.sleep(delay)
                await self._client.emit_word(utterance_id, i, t_ms)

        asyncio.run_coroutine_threadsafe(_run_all(), self._loop)

    def shutdown(self) -> None:
        if self._loop is not None and self._thread is not None:
            try:
                # Run client.close() to completion on the bg loop, *then*
                # stop the loop. Otherwise the close coroutine gets GC'd
                # mid-flight and emits "coroutine was never awaited".
                fut = asyncio.run_coroutine_threadsafe(
                    self._client.close(), self._loop
                )
                fut.result(timeout=2.0)
            except (BaseException, TimeoutError):
                pass
            self._loop.call_soon_threadsafe(self._loop.stop)
            self._thread.join(timeout=2.0)
        self._enabled = False


class NullKaraokeEmitter:
    """No-op sync emitter. Same shape as KaraokeEmitter."""

    def start(self, *a, **kw) -> None: ...
    def word(self, *a, **kw) -> None: ...
    def pause(self, *a, **kw) -> None: ...
    def resume(self, *a, **kw) -> None: ...
    def stop(self, *a, **kw) -> None: ...
    def config(self, *a, **kw) -> None: ...
    def schedule_word_events(self, *a, **kw) -> None: ...
    def shutdown(self) -> None: ...


def make_karaoke_emitter(config: dict) -> "KaraokeEmitter | NullKaraokeEmitter":
    karaoke_cfg = config.get("karaoke") or {}
    if karaoke_cfg.get("enabled", True) is False:
        return NullKaraokeEmitter()
    return KaraokeEmitter(KaraokeClient())
