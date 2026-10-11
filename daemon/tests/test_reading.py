"""Which word the v1 player is reading: myna.reading, the player's listener
calls, the engine's word timings, and GET /reading(/events)."""

import asyncio
import copy
import io
import threading
import time
import wave

from fastapi.testclient import TestClient

from myna import engine, engine_shim
from myna.app import create_app
from myna.config import DEFAULTS
from myna.player import Player
from myna.reading import Aligner, ReadingTracker, estimate_words, wav_duration_ms


def _wav(ms: int, rate: int = 24000) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * (rate * ms // 1000))
    return buf.getvalue()


class Clock:
    def __init__(self):
        self.t = 100.0

    def __call__(self):
        return self.t


class Events:
    """Collects what a tracker emits to one subscriber."""

    def __init__(self, tracker):
        self.loop = asyncio.new_event_loop()
        self.queue = tracker.subscribe(self.loop)

    def drain(self):
        self.loop.run_until_complete(asyncio.sleep(0))
        out = []
        while not self.queue.empty():
            out.append(self.queue.get_nowait())
        return out


def _span(text, rng):
    return text[rng[0] : rng[1]] if rng else None


# ----- Aligner -----


def test_aligner_finds_words_through_markdown():
    sent = "**The button** sits `outside` the flex-row, so it never gets width."
    words = ["The", "button", "sits", "outside", "the", "flex", "row", "so", "it", "never", "gets", "width"]
    got = [_span(sent, r) for r in Aligner(sent).locate_all(words)]
    assert got == ["The", "button", "sits", "outside", "the", "flex", "row", "so", "it", "never", "gets", "width"]


def test_aligner_leaves_words_cleanup_added_unmatched():
    sent = "```\nprint(1)\n```\nSee the docs."
    words = ["Code", "block", "skipped", "See", "the", "docs"]
    got = [_span(sent, r) for r in Aligner(sent).locate_all(words)]
    assert got == [None, None, None, "See", "the", "docs"]


def test_aligner_never_matches_inside_a_word():
    # "a" is inside "data"; the spoken "a" isn't in the text at all.
    sent = "The data is ready."
    got = [_span(sent, r) for r in Aligner(sent).locate_all(["The", "a", "data", "is", "ready"])]
    assert got == ["The", None, "data", "is", "ready"]


def test_aligner_gives_respelt_words_the_word_they_replaced():
    # The pronunciation list reads "Myna" as "Mynah" and "nginx" as "engine x".
    sent = "Myna now runs behind nginx today."
    words = ["Mynah", "now", "runs", "behind", "engine", "x", "today"]
    got = [_span(sent, r) for r in Aligner(sent).locate_all(words)]
    assert got == ["Myna", "now", "runs", "behind", "nginx", "nginx", "today"]


def test_aligner_leaves_a_gap_it_cannot_split():
    sent = "Start here. one two three. End."
    words = ["Start", "here", "Code", "block", "End"]
    got = [_span(sent, r) for r in Aligner(sent).locate_all(words)]
    assert got == ["Start", "here", None, None, "End"]


def test_aligner_takes_a_far_match_only_when_the_next_word_agrees():
    sent = "Intro. One two three four five six seven. The end is here."
    # "the" alone far ahead would be a guess; "The end" together is a match.
    a = Aligner(sent)
    assert _span(sent, a.locate("Intro")) == "Intro"
    assert a.locate("the", ()) is None
    assert _span(sent, a.locate("The", ("end",))) == "The"
    assert _span(sent, a.locate("end")) == "end"


def test_aligner_joins_split_and_merged_tokens():
    sent = "It's well-known that $4.99 isn't much."
    words = ["It's", "well", "known", "that", "4.99", "is", "n't", "much"]
    got = [_span(sent, r) for r in Aligner(sent).locate_all(words)]
    assert got == ["It's", "well", "known", "that", "4.99", "is", "n't", "much"]


# ----- timing helpers -----


def test_wav_duration_reads_the_header():
    assert wav_duration_ms(_wav(1500)) == 1500
    assert wav_duration_ms(_wav(500, rate=32000)) == 500
    assert wav_duration_ms(b"not a wav") == 0


def test_estimate_spreads_the_chunk_and_pauses_at_punctuation():
    words = estimate_words("Hello there, world. Bye", 2000)
    assert [w for w, _, _ in words] == ["Hello", "there", "world", "Bye"]
    starts = [s for _, s, _ in words]
    assert starts == sorted(starts) and starts[0] == 0
    assert words[-1][2] == 2000
    # "world" is followed by a full stop, so it holds longer than "Hello".
    length = {w: e - s for w, s, e in words}
    assert length["world"] > length["Hello"]


def test_engine_and_shim_agree_on_the_timings_key():
    for text, speed in [("Hello.", 1.0), ("Hello.", 1), ("Ünïcode — ok", 1.25)]:
        assert engine.word_timings_key(text, speed) == engine_shim.word_timings_key(text, speed)
    assert engine.word_timings_key("a", 1.0) != engine.word_timings_key("a", 1.1)


# ----- the tracker -----


MODEL = {
    "words": [["Hello", 0.1, 0.4], [",", 0.4, 0.45], ["big", 0.5, 0.7], ["world", 0.75, 1.1], [".", 1.1, 1.2]],
    "exact": True,
}


def _tracker():
    clock = Clock()
    return ReadingTracker(clock=clock, ticker=False), clock


def test_words_follow_the_player_clock():
    tracker, clock = _tracker()
    events = Events(tracker)
    sent = "**Hello**, big world."
    rid = tracker.begin(text=sent, spoken="Hello, big world.", voice="af_heart", speed=1.0)
    tracker.add_chunk(rid, "Hello, big world.", _wav(1300), MODEL)
    listener = tracker.listener(rid)
    listener.started()

    assert tracker.tick() == 0.1  # nothing spoken yet; "Hello" starts in 100 ms
    clock.t += 0.2
    tracker.tick()
    clock.t += 0.35  # 550 ms: "big"
    tracker.tick()
    got = events.drain()
    kinds = [k for k, _ in got]
    assert kinds == ["start", "chunk", "word", "word"]
    chunk = got[1][1]
    assert chunk["timing"] == "model" and chunk["duration_ms"] == 1300
    assert [w["text"] for w in chunk["words"]] == ["Hello", "big", "world"]  # punctuation dropped
    hello, big = got[2][1], got[3][1]
    assert (hello["i"], hello["start"], hello["end"]) == (0, 100, 400)
    assert _span(sent, hello["src"]) == "Hello"
    assert _span("Hello, big world.", big["at"]) == "big"
    assert tracker.snapshot()["word"]["text"] == "big"


def test_pause_holds_the_word_and_resume_carries_on():
    tracker, clock = _tracker()
    events = Events(tracker)
    rid = tracker.begin(text=None, spoken="Hello, big world.", voice=None, speed=1.0)
    tracker.add_chunk(rid, "Hello, big world.", _wav(1300), MODEL)
    listener = tracker.listener(rid)
    listener.started()
    clock.t += 0.2
    tracker.tick()
    listener.paused()
    clock.t += 5.0  # paused for five seconds
    assert tracker.tick() is None
    assert tracker.snapshot()["position_ms"] == 200
    listener.resumed()
    clock.t += 0.35
    tracker.tick()
    got = events.drain()
    assert [k for k, _ in got] == ["start", "chunk", "word", "pause", "resume", "word"]
    assert got[3][1]["position_ms"] == 200
    assert got[5][1]["text"] == "big"
    assert got[5][1]["src"] is None  # no text was sent, so no src ranges


def test_word_indexes_run_on_across_chunks_and_estimates_fill_in():
    tracker, clock = _tracker()
    events = Events(tracker)
    spoken = "Hello, big world. Second part here."
    rid = tracker.begin(text=spoken, spoken=spoken, voice=None, speed=1.0)
    tracker.add_chunk(rid, "Hello, big world.", _wav(1300), MODEL)
    tracker.add_chunk(rid, "Second part here.", _wav(900), None)
    listener = tracker.listener(rid)
    listener.started()
    clock.t += 1.2
    tracker.tick()
    listener.started()  # chunk two
    tracker.tick()
    got = events.drain()
    chunks = [d for k, d in got if k == "chunk"]
    assert [c["timing"] for c in chunks] == ["model", "estimated"]
    assert [w["i"] for w in chunks[1]["words"]] == [3, 4, 5]
    words = [d for k, d in got if k == "word"]
    assert (words[-1]["i"], words[-1]["chunk"], words[-1]["text"]) == (3, 1, "Second")
    assert _span(spoken, words[-1]["at"]) == "Second"


def test_a_new_read_replaces_the_old_and_its_late_events_are_ignored():
    tracker, clock = _tracker()
    events = Events(tracker)
    first = tracker.begin(text=None, spoken="One.", voice=None, speed=1.0)
    old = tracker.listener(first)
    second = tracker.begin(text=None, spoken="Two.", voice=None, speed=1.0)
    old.ended("stopped")  # the old run winding down
    old.started()
    tracker.ended(second, "finished")
    got = events.drain()
    assert [(k, d.get("reason")) for k, d in got] == [
        ("start", None),
        ("end", "replaced"),
        ("start", None),
        ("end", "finished"),
    ]
    assert got[1][1]["id"] == first and got[3][1]["id"] == second
    assert tracker.snapshot()["state"] == "ended"


def test_ticker_thread_emits_words_on_real_time():
    tracker = ReadingTracker()
    events = Events(tracker)
    rid = tracker.begin(text=None, spoken="Hello, big world.", voice=None, speed=1.0)
    tracker.add_chunk(rid, "Hello, big world.", _wav(1300), MODEL)
    tracker.listener(rid).started()
    time.sleep(0.6)
    words = [d["text"] for k, d in events.drain() if k == "word"]
    assert words == ["Hello", "big"]
    tracker.ended(rid, "stopped")


# ----- the player's listener calls -----


class Proc:
    def __init__(self, pid=1, polls=1):
        self.pid = pid
        self._polls = polls

    def poll(self):
        if self._polls <= 0:
            return 0
        self._polls -= 1
        return None

    def kill(self):
        self._polls = 0


class Heard:
    def __init__(self):
        self.calls = []
        self.done = threading.Event()

    def started(self):
        self.calls.append("started")

    def paused(self):
        self.calls.append("paused")

    def resumed(self):
        self.calls.append("resumed")

    def ended(self, reason):
        self.calls.append(f"ended:{reason}")
        self.done.set()


def test_player_tells_the_listener_each_file_and_the_end():
    heard = Heard()
    p = Player(spawn=lambda path: Proc(polls=0), sig=lambda pid, s: None)
    p.play(iter(["a.wav", "b.wav"]), meta={}, listener=heard)
    assert heard.done.wait(2)
    assert heard.calls == ["started", "started", "ended:finished"]


def test_player_pause_resume_and_stop_reach_the_listener():
    heard = Heard()
    p = Player(spawn=lambda path: Proc(polls=10_000), sig=lambda pid, s: None)
    p.play(iter(["a.wav"]), meta={}, listener=heard)
    deadline = time.time() + 2
    while "started" not in heard.calls and time.time() < deadline:
        time.sleep(0.01)
    p.pause()
    p.resume()
    p.stop()
    assert heard.calls[:4] == ["started", "paused", "resumed", "ended:stopped"]


def test_an_old_run_mid_synthesis_never_plays_over_the_new_one():
    release = threading.Event()
    spawned = []

    def slow_producer():
        yield "old-1.wav"
        release.wait(2)  # synthesizing the next chunk, slower than stop()'s join
        yield "old-2.wav"

    p = Player(spawn=lambda path: spawned.append(path) or Proc(polls=0), sig=lambda pid, s: None)
    p.play(slow_producer(), meta={})
    time.sleep(0.1)
    p.play(iter(["new.wav"]), meta={})
    release.set()
    time.sleep(0.3)
    assert "old-2.wav" not in spawned
    assert spawned == ["old-1.wav", "new.wav"]


# ----- routes -----


class ListeningPlayer:
    """Consumes the producer and tells the listener, like the real one."""

    def __init__(self):
        self._state = "idle"

    def play(self, producer, meta, listener=None):
        for _ in producer:
            if listener is not None:
                listener.started()
        self._state = "playing"

    def pause(self): pass
    def resume(self): pass
    def stop(self): pass

    def status(self):
        return {"state": self._state, "now_playing": None}


def _client(**state):
    app = create_app(copy.deepcopy(DEFAULTS), persist_config=False)
    app.state.player = ListeningPlayer()
    app.state.synthesize = lambda text, **kw: _wav(1000)
    app.state.engine_up = lambda base_url, **kw: True
    for k, v in state.items():
        setattr(app.state, k, v)
    return TestClient(app, base_url="http://127.0.0.1"), app


def test_speak_returns_the_read_and_reading_shows_its_words():
    asked = []

    def timings(text, *, speed, base_url):
        asked.append(text)
        return {"words": [[w, i * 0.2, i * 0.2 + 0.15] for i, w in enumerate(text.rstrip(".").split())], "exact": True}

    client, app = _client(word_timings=timings)
    sent = "Read **this** now."
    r = client.post("/speak", json={"text": sent, "source": "claude_code"})
    rid = r.json()["id"]
    snap = client.get("/reading").json()["reading"]
    assert snap["id"] == rid and snap["text"] == sent
    assert snap["spoken"] == "Read this now."
    assert asked == ["Read this now."]
    words = snap["chunks"][0]["words"]
    assert [_span(sent, w["src"]) for w in words] == ["Read", "this", "now"]


def test_other_engines_are_not_asked_for_timings():
    asked = []
    client, app = _client(word_timings=lambda *a, **kw: asked.append(a))
    app.state.cfg["engine"] = "pocket"
    client.post("/speak", json={"text": "Hello there."})
    assert asked == []
    assert client.get("/reading").json()["reading"]["chunks"][0]["timing"] == "estimated"


def test_reading_events_open_with_a_snapshot_and_end_on_shutdown():
    client, app = _client(word_timings=lambda *a, **kw: None)
    client.post("/speak", json={"text": "Hello there."})
    app.state.shutting_down = lambda: True
    body = client.get("/reading/events").text
    assert body.startswith("retry: 2000\nevent: snapshot\ndata: ")
    assert '"spoken": "Hello there."' in body


# ----- UTF-16 ranges and the app's per-chunk words -----


def _u16(text: str, rng):
    """Slice by UTF-16 code units, as JavaScript and NSString do."""
    units = text.encode("utf-16-le")
    return units[rng[0] * 2 : rng[1] * 2].decode("utf-16-le")


def test_ranges_count_utf16_units_so_emoji_dont_shift_words():
    sent = "🎉 Shipped ✅ today 👍🏽 really."
    got = Aligner(sent).locate_all(["Shipped", "today", "really"])
    assert [_u16(sent, r) for r in got] == ["Shipped", "today", "really"]
    assert got[0] == (3, 10)  # 🎉 is two units, then a space


def test_header_words_place_each_word_in_the_chunk():
    from myna.reading import header_words

    chunk = "Hello, big 🌍 world."
    timing, raw = header_words(chunk, _wav(1300), {
        "words": [["Hello", 0.1, 0.4], [",", 0.4, 0.45], ["big", 0.5, 0.7], ["world", 0.75, 1.1]],
        "exact": True,
    })
    rows = __import__("json").loads(raw)
    assert timing == "model"
    assert [r[:2] for r in rows] == [[100, 400], [500, 700], [750, 1100]]
    assert [_u16(chunk, r[2:]) for r in rows] == ["Hello", "big", "world"]
    timing, raw = header_words(chunk, _wav(1300), None)
    assert timing == "estimated" and len(__import__("json").loads(raw)) == 3


def test_v2_synthesize_sends_each_chunks_words():
    from .v2_helpers import make_client, parse_multipart

    client, *_ = make_client(
        synthesize=lambda text, **kw: _wav(800),
        word_timings=lambda text, **kw: {
            "words": [[w, i * 0.2, i * 0.2 + 0.15] for i, w in enumerate(text.rstrip(".").split())],
            "exact": True,
        },
    )
    r = client.post("/v2/synthesize", json={"text": "Read this now."})
    parts = [p for p in parse_multipart(r.content) if p["headers"].get("Content-Type") == "audio/wav"]
    headers = parts[0]["headers"]
    assert headers["X-Chunk-Timing"] == "model"
    rows = __import__("json").loads(headers["X-Chunk-Words"])
    assert [r[:2] for r in rows] == [[0, 150], [200, 350], [400, 550]]
