"""What the daemon's player is reading right now, word by word.

A read sent to `POST /speak` is cleaned (myna.speakable), cut into chunks,
synthesized one chunk at a time and played with afplay (myna.player). This
module follows that read and says which word is being spoken:

  GET /reading          a snapshot: the read, its words so far, the word now
  GET /reading/events   the same as Server-Sent Events, pushed as they happen

Where the times come from. Kokoro, for English voices, says when each word
starts and ends (the engine shim keeps its duration predictor's output;
myna.engine.word_timings fetches it). Every other engine, and Kokoro's other
languages, get an estimate: the chunk's real length spread over its words
by length, with extra weight for the pause after punctuation. Each chunk
says which it got ("model" or "estimated").

Where a word is. Every word carries two character ranges:
  "at"   into `spoken`, the text actually read (after cleanup)
  "src"  into `text`, exactly what the client sent, or null when the word
         isn't in it (cleanup said it: "Code block skipped", a URL's host)
A client that shows what it sent highlights `src`; one that shows the
cleaned text highlights `at`. Ranges count UTF-16 code units, as JavaScript
strings and NSString do, so an emoji before a word doesn't shift it.

The Mac app's own reads (POST /v2/synthesize) get the same words per chunk
in an `X-Chunk-Words` header (myna.app), built by `chunk_words` here.

The clock. A chunk's time starts when its afplay starts, and stands still
while the player is paused (SIGSTOP). afplay's own start-up, a few tens of
milliseconds, is not measured, so a highlight can lead the voice by that
much, never trail it.

Events (each `data:` is one JSON object, all carrying the read's "id"):
  snapshot  on connect: {"reading": <as GET /reading>}
  start     a read began: text, spoken, voice, speed
  chunk     a chunk began playing: index, timing, duration_ms, words
            (word times are ms from the chunk's start, so a client can run
            its own clock between events)
  word      the word now: i, chunk, text, start, end, src, at
  pause / resume   with the position in the chunk, ms
  end       reason: finished, stopped, replaced, error
"""

from __future__ import annotations

import asyncio
import json
import re
import struct
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Callable, Optional

# Event queue per subscriber. A client that stops reading loses events past
# this rather than growing the daemon's memory.
_QUEUE_MAX = 1000

# Estimated timing: extra weight, in characters, for the pause after a word
# that ends a clause or a sentence.
_CLAUSE_PAUSE = 3
_SENTENCE_PAUSE = 6

# A spoken word may be matched this many words past the last match without
# question; further than that, the next spoken word must match right after
# it too. Cleanup drops whole code blocks, so a far match can be right.
_NEAR_WORDS = 3
_MAX_CANDIDATES = 30

_WORD_RE = re.compile(r"[^\W_]+(?:['’.\-][^\W_]+)*")


def _fold(ch: str) -> str:
    low = ch.lower()
    return low if len(low) == 1 else ch


def _norm(word: str) -> str:
    return "".join(_fold(c) for c in word if c.isalnum())


class Aligner:
    """Finds words, in order, in a text they were taken from.

    Matching runs on the text's letters and digits only, lowercased, so
    markup, punctuation and splitting ("well-known" as one word or three,
    "4.99" or "4" "99") don't matter. A match must start where a word starts
    in the text, or right where the last match ended.
    """

    def __init__(self, text: str):
        stream: list[str] = []
        index: list[int] = []
        starts: list[bool] = []
        # _u16[i]: where code point i starts, in UTF-16 code units.
        u16 = [0]
        for ch in text:
            u16.append(u16[-1] + (2 if ord(ch) > 0xFFFF else 1))
        self._u16 = u16
        for i, ch in enumerate(text):
            if not ch.isalnum():
                continue
            stream.append(_fold(ch))
            index.append(i)
            starts.append(i == 0 or not text[i - 1].isalnum())
        self._stream = "".join(stream)
        self._index = index
        self._starts = starts
        # _before[k]: how many words start before stream position k.
        before = [0]
        for s in starts:
            before.append(before[-1] + (1 if s else 0))
        self._before = before
        self.cursor = 0
        self._last: Optional[tuple[int, int]] = None  # stream span of the last match

    def _ok(self, p: int) -> bool:
        return p == self.cursor or self._starts[p]

    def _near(self, p: int) -> bool:
        return self._before[p] - self._before[self.cursor] <= _NEAR_WORDS

    def _follows(self, end: int, following: list[str]) -> bool:
        nxt = next((w for w in following if w), None)
        if nxt is None:
            return False
        # Right where this match ends, or at the next word's start.
        q = end
        while q < len(self._stream) and not self._starts[q]:
            q += 1
        return self._stream.startswith(nxt, end) or self._stream.startswith(nxt, q)

    def locate(self, word: str, following: tuple[str, ...] = ()) -> Optional[tuple[int, int]]:
        """The range of `word` in the text, or None; advances past a match.
        `following` are the next words' normalized forms, to confirm a far match."""
        self._last = None
        w = _norm(word)
        if not w:
            return None
        p = self._stream.find(w, self.cursor)
        tried = 0
        while p != -1 and tried < _MAX_CANDIDATES:
            tried += 1
            if self._ok(p) and (self._near(p) or self._follows(p + len(w), list(following))):
                self._last = (p, p + len(w))
                self.cursor = p + len(w)
                return self._source_range(p, p + len(w))
            p = self._stream.find(w, p + 1)
        return None

    def locate_all(self, words: list[str]) -> list[Optional[tuple[int, int]]]:
        normed = [_norm(w) for w in words]
        begin = self.cursor
        out: list[Optional[tuple[int, int]]] = []
        spans: list[Optional[tuple[int, int]]] = []
        for i, w in enumerate(words):
            out.append(self.locate(w, tuple(normed[i + 1 : i + 3])))
            spans.append(self._last)
        self._fill_gaps(out, spans, begin)
        return out

    def _source_range(self, a: int, b: int) -> tuple[int, int]:
        """Stream span [a, b) as a UTF-16 range in the text."""
        return (self._u16[self._index[a]], self._u16[self._index[b - 1] + 1])

    def _fill_gaps(self, out, spans, begin: int) -> None:
        """Unmatched words between two matches take the text's words in that
        gap when the count says how: as many words as there are, one each
        ("Myna" read as "Mynah"); one word in the gap, all of them on it
        ("nginx" read as "engine x"). Anything else stays unmatched."""
        i = 0
        while i < len(out):
            if out[i] is not None:
                i += 1
                continue
            j = i
            while j < len(out) and out[j] is None:
                j += 1
            if j == len(out):
                return  # no match after the run: its gap isn't known yet
            left = spans[i - 1][1] if i > 0 else begin
            right = spans[j][0]
            starts = [k for k in range(left, right) if self._starts[k]]
            ranges = [
                self._source_range(s, starts[n + 1] if n + 1 < len(starts) else right)
                for n, s in enumerate(starts)
            ]
            if len(ranges) == j - i:
                out[i:j] = ranges
            elif len(ranges) == 1:
                out[i:j] = ranges * (j - i)
            i = j


def wav_duration_ms(wav: bytes) -> int:
    """Length of a RIFF/WAVE buffer in ms, from its fmt and data chunks; 0
    when it can't be read."""
    if len(wav) < 12 or wav[0:4] != b"RIFF" or wav[8:12] != b"WAVE":
        return 0
    pos, byte_rate, data_size = 12, 0, -1
    while pos + 8 <= len(wav):
        cid = wav[pos : pos + 4]
        size = struct.unpack_from("<I", wav, pos + 4)[0]
        body = pos + 8
        if cid == b"fmt " and size >= 16 and body + 12 <= len(wav):
            byte_rate = struct.unpack_from("<I", wav, body + 8)[0]
        elif cid == b"data":
            # A streamed WAV may carry a placeholder size; trust the bytes.
            data_size = min(size, len(wav) - body)
            break
        pos = body + size + (size & 1)
    if byte_rate <= 0 or data_size < 0:
        return 0
    return int(data_size * 1000 / byte_rate)


def estimate_words(chunk: str, duration_ms: int) -> list[tuple[str, int, int]]:
    """(word, start_ms, end_ms) spread over the chunk by length, with weight
    for the pause after punctuation."""
    spans = [(m.group(0), m.end()) for m in _WORD_RE.finditer(chunk)]
    if not spans:
        return []
    weights = []
    for word, end in spans:
        after = chunk[end : end + 2].strip()[:1]  # " —" counts as "—"
        pause = 0
        if after and after in ".!?":
            pause = _SENTENCE_PAUSE
        elif after and after in ",;:—":
            pause = _CLAUSE_PAUSE
        weights.append(len(word) + 1 + pause)
    total = sum(weights)
    if duration_ms <= 0:
        duration_ms = int(total * 1000 / 14.0)  # ~14 characters a second
    out, acc = [], 0
    for (word, _), wt in zip(spans, weights):
        start = int(duration_ms * acc / total)
        acc += wt
        out.append((word, start, int(duration_ms * acc / total)))
    return out


def chunk_words(chunk: str, wav: bytes, timings: Optional[dict]) -> tuple[str, int, list[tuple[str, int, int]]]:
    """One chunk's words as (word, start_ms, end_ms): Kokoro's own times when
    the engine had them, else an estimate. Returns (timing, duration_ms, words)."""
    duration = wav_duration_ms(wav)
    model = _model_words(timings)
    if model:
        return "model", duration, model
    return "estimated", duration, estimate_words(chunk, duration)


def header_words(chunk: str, wav: bytes, timings: Optional[dict]) -> tuple[str, str]:
    """(timing, JSON) for a chunk's `X-Chunk-Words` header:
    [[start_ms, end_ms, at_start, at_end], ...], `at` in UTF-16 units of the
    chunk's text. Words that can't be placed in the text are left out."""
    timing, _, words = chunk_words(chunk, wav, timings)
    ranges = Aligner(chunk).locate_all([w for w, _, _ in words])
    rows = [[s, e, r[0], r[1]] for (_, s, e), r in zip(words, ranges) if r]
    return timing, json.dumps(rows, separators=(",", ":"))


@dataclass
class _Chunk:
    index: int
    timing: str
    duration_ms: int
    words: list[dict]

    def public(self) -> dict:
        return {
            "index": self.index,
            "timing": self.timing,
            "duration_ms": self.duration_ms,
            "words": self.words,
        }


@dataclass
class _Reading:
    id: str
    text: Optional[str]
    spoken: str
    voice: Optional[str]
    speed: float
    src: Optional[Aligner]
    at: Aligner
    state: str = "preparing"  # preparing, playing, paused, ended
    reason: Optional[str] = None
    chunks: list[_Chunk] = field(default_factory=list)
    words_seen: int = 0
    playing: int = -1  # index into chunks of the chunk playing
    t0: float = 0.0  # clock when the playing chunk started, moved on by pauses
    paused_at: Optional[float] = None
    word: Optional[int] = None  # global index of the word now

    def header(self) -> dict:
        return {
            "id": self.id,
            "text": self.text,
            "spoken": self.spoken,
            "voice": self.voice,
            "speed": self.speed,
        }


class ReadingTracker:
    """Follows one read at a time. Thread-safe: the producer and the player
    call in from the player's thread, routes from the event loop, and a
    ticker thread of its own emits `word` events on time."""

    def __init__(self, clock: Callable[[], float] = time.monotonic, *, ticker: bool = True):
        self._clock = clock
        self._cond = threading.Condition(threading.RLock())
        self._current: Optional[_Reading] = None
        self._subscribers: dict[int, tuple[asyncio.AbstractEventLoop, asyncio.Queue]] = {}
        self._ticker_on = ticker
        self._ticker: Optional[threading.Thread] = None

    # ----- the read's side: begin, chunks, the player's events -----

    def begin(self, *, text: Optional[str], spoken: str, voice: Optional[str], speed: float) -> str:
        reading = _Reading(
            id=f"r-{uuid.uuid4().hex[:12]}",
            text=text,
            spoken=spoken,
            voice=voice,
            speed=speed,
            src=Aligner(text) if text else None,
            at=Aligner(spoken),
        )
        with self._cond:
            old = self._current
            if old is not None and old.state != "ended":
                self._end(old, "replaced")
            self._current = reading
            self._emit("start", reading.header())
            self._ensure_ticker()
        return reading.id

    def add_chunk(self, reading_id: str, chunk: str, wav: bytes, timings: Optional[dict]) -> None:
        """A chunk is synthesized and about to be queued for the player."""
        timing, duration, raw = chunk_words(chunk, wav, timings)
        with self._cond:
            r = self._live(reading_id)
            if r is None:
                return
            texts = [w for w, _, _ in raw]
            ats = r.at.locate_all(texts)
            srcs = r.src.locate_all(texts) if r.src is not None else [None] * len(raw)
            words = []
            for (word, start, end), at, src in zip(raw, ats, srcs):
                words.append({
                    "i": r.words_seen + len(words),
                    "text": word,
                    "start": start,
                    "end": end,
                    "src": list(src) if src else None,
                    "at": list(at) if at else None,
                })
            r.words_seen += len(words)
            r.chunks.append(_Chunk(len(r.chunks), timing, duration, words))

    def listener(self, reading_id: str) -> "PlayerListener":
        return PlayerListener(self, reading_id)

    def chunk_started(self, reading_id: str) -> None:
        with self._cond:
            r = self._live(reading_id)
            if r is None or r.playing + 1 >= len(r.chunks):
                return
            r.playing += 1
            r.t0 = self._clock()
            r.paused_at = None
            r.state = "playing"
            chunk = r.chunks[r.playing]
            self._emit("chunk", {"id": r.id, **chunk.public()})
            self._cond.notify_all()

    def paused(self, reading_id: str) -> None:
        with self._cond:
            r = self._live(reading_id)
            if r is None or r.state != "playing":
                return
            r.paused_at = self._clock()
            r.state = "paused"
            self._emit("pause", {"id": r.id, "position_ms": self._position(r)})
            self._cond.notify_all()

    def resumed(self, reading_id: str) -> None:
        with self._cond:
            r = self._live(reading_id)
            if r is None or r.state != "paused":
                return
            if r.paused_at is not None:
                r.t0 += self._clock() - r.paused_at
            r.paused_at = None
            r.state = "playing"
            self._emit("resume", {"id": r.id, "position_ms": self._position(r)})
            self._cond.notify_all()

    def ended(self, reading_id: str, reason: str) -> None:
        with self._cond:
            r = self._live(reading_id)
            if r is not None:
                self._end(r, reason)

    # ----- the word now -----

    def tick(self) -> Optional[float]:
        """Emit a `word` event if the word has changed. Returns seconds until
        the next word starts, or None when nothing is playing."""
        with self._cond:
            r = self._current
            if r is None or r.state != "playing" or r.playing < 0:
                return None
            chunk = r.chunks[r.playing]
            pos = self._position(r)
            now = None
            for w in chunk.words:
                if w["start"] <= pos:
                    now = w
                else:
                    break
            if now is not None and now["i"] != r.word:
                r.word = now["i"]
                self._emit("word", self._word_event(r, now, chunk.index))
            upcoming = [w["start"] for w in chunk.words if w["start"] > pos]
            return (upcoming[0] - pos) / 1000.0 if upcoming else None

    def _ensure_ticker(self) -> None:
        if not self._ticker_on or (self._ticker is not None and self._ticker.is_alive()):
            return
        self._ticker = threading.Thread(target=self._tick_loop, name="myna-reading", daemon=True)
        self._ticker.start()

    def _tick_loop(self) -> None:
        while True:
            with self._cond:
                wait = self.tick()
                # None: idle, paused, or past the chunk's last word. A chunk
                # starting, a pause, a resume or an end wakes us.
                self._cond.wait(timeout=None if wait is None else max(0.005, wait))

    # ----- readers -----

    def snapshot(self) -> Optional[dict]:
        with self._cond:
            r = self._current
            if r is None:
                return None
            chunk = r.chunks[r.playing] if r.playing >= 0 else None
            word = None
            if r.word is not None:
                # The word now can still be the last chunk's, until the
                # playing chunk's first word starts.
                for c in r.chunks:
                    found = next((w for w in c.words if w["i"] == r.word), None)
                    if found is not None:
                        word = self._word_event(r, found, c.index)
                        break
            return {
                **r.header(),
                "state": r.state,
                "reason": r.reason,
                "chunk": chunk.index if chunk else None,
                "position_ms": self._position(r) if chunk else None,
                "word": word,
                "chunks": [c.public() for c in r.chunks],
            }

    def subscribe(self, loop: asyncio.AbstractEventLoop) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=_QUEUE_MAX)
        with self._cond:
            self._subscribers[id(queue)] = (loop, queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue) -> None:
        with self._cond:
            self._subscribers.pop(id(queue), None)

    # ----- internals; call with the lock held -----

    def _live(self, reading_id: str) -> Optional[_Reading]:
        r = self._current
        if r is None or r.id != reading_id or r.state == "ended":
            return None
        return r

    def _position(self, r: _Reading) -> int:
        at = r.paused_at if r.paused_at is not None else self._clock()
        return max(0, int((at - r.t0) * 1000))

    def _word_event(self, r: _Reading, w: dict, chunk_index: int) -> dict:
        return {"id": r.id, "chunk": chunk_index, **w}

    def _end(self, r: _Reading, reason: str) -> None:
        r.state = "ended"
        r.reason = reason
        r.paused_at = None
        self._emit("end", {"id": r.id, "reason": reason})
        self._cond.notify_all()

    def _emit(self, event: str, data: dict) -> None:
        for key, (loop, queue) in list(self._subscribers.items()):
            try:
                loop.call_soon_threadsafe(_offer, queue, (event, data))
            except RuntimeError:  # the subscriber's loop has closed
                self._subscribers.pop(key, None)


class PlayerListener:
    """What myna.player calls as it plays one read."""

    def __init__(self, tracker: ReadingTracker, reading_id: str):
        self._tracker = tracker
        self.reading_id = reading_id

    def started(self) -> None:
        self._tracker.chunk_started(self.reading_id)

    def paused(self) -> None:
        self._tracker.paused(self.reading_id)

    def resumed(self) -> None:
        self._tracker.resumed(self.reading_id)

    def ended(self, reason: str) -> None:
        self._tracker.ended(self.reading_id, reason)


def _offer(queue: asyncio.Queue, item) -> None:
    try:
        queue.put_nowait(item)
    except asyncio.QueueFull:
        pass


def _model_words(timings: Optional[dict]) -> list[tuple[str, int, int]]:
    """Kokoro's tokens as (word, start_ms, end_ms), punctuation dropped."""
    if not timings:
        return []
    out = []
    for item in timings.get("words") or ():
        try:
            word, start, end = item[0], float(item[1]), float(item[2])
        except (TypeError, ValueError, IndexError):
            return []
        if isinstance(word, str) and any(c.isalnum() for c in word):
            out.append((word, int(start * 1000), int(end * 1000)))
    return out


def sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"
