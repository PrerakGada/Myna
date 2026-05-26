"""Integration: /v2/synthesize emits karaoke start/stop/scheduled-words.

We swap app.state.karaoke for a recording stub and assert the synth
pipeline calls start once per chunk + stop once at end-of-stream, with
words list matching the chunked text. Word events themselves are scheduled
on a background loop in production (KaraokeEmitter); the recording stub
captures `schedule_word_events` calls verbatim, so this test verifies
the daemon hands the right (i, t_ms) pairs to the emitter — Track C's
sidecar consumes them downstream.
"""

import struct

import pytest

from myna.karaoke.timing import WordTimingEstimator

from .v2_helpers import make_client, parse_multipart


class RecordingEmitter:
    """Stand-in for KaraokeEmitter — records every call."""

    def __init__(self):
        self.calls: list[tuple[str, tuple, dict]] = []

    def _rec(self, name, *args, **kwargs):
        self.calls.append((name, args, kwargs))

    def start(self, *a, **kw): self._rec("start", *a, **kw)
    def word(self, *a, **kw): self._rec("word", *a, **kw)
    def pause(self, *a, **kw): self._rec("pause", *a, **kw)
    def resume(self, *a, **kw): self._rec("resume", *a, **kw)
    def stop(self, *a, **kw): self._rec("stop", *a, **kw)
    def config(self, *a, **kw): self._rec("config", *a, **kw)
    def schedule_word_events(self, *a, **kw): self._rec("schedule_word_events", *a, **kw)
    def shutdown(self): pass


def _real_wav(num_samples: int = 24000) -> bytes:
    """Build a canonical 24kHz mono 16-bit WAV so the timing path can
    parse a sample count instead of falling back to CPS-derived estimate.
    """
    rate = 24000
    block = 2
    size = num_samples * block
    head = (
        b"RIFF" + struct.pack("<I", 36 + size) + b"WAVE"
        + b"fmt " + struct.pack("<I", 16)
        + struct.pack("<H", 1) + struct.pack("<H", 1)
        + struct.pack("<I", rate) + struct.pack("<I", rate * block)
        + struct.pack("<H", block) + struct.pack("<H", 16)
        + b"data" + struct.pack("<I", size)
    )
    return head + b"\x00" * size


def test_synth_emits_start_per_chunk_and_one_stop():
    client, fp, app = make_client(config_overrides={"chunk_chars": 20})
    rec = RecordingEmitter()
    app.state.karaoke = rec
    app.state.synthesize = lambda text, **kw: _real_wav(24000)

    r = client.post(
        "/v2/synthesize",
        json={"text": "One two three. Four five six.", "session_id": "rid_k"},
    )
    assert r.status_code == 200
    # Drain stream
    r.content

    names = [c[0] for c in rec.calls]
    # 2 chunks expected per chunk_chars=20 → 2 starts + 1 stop
    assert names.count("start") == 2
    assert names.count("stop") == 1
    # And schedule_word_events fires per start
    assert names.count("schedule_word_events") == 2


def test_synth_start_carries_words_voice_duration():
    client, fp, app = make_client()
    rec = RecordingEmitter()
    app.state.karaoke = rec
    samples = 24000  # 1s
    app.state.synthesize = lambda text, **kw: _real_wav(samples)

    r = client.post(
        "/v2/synthesize",
        json={
            "text": "Hello karaoke world.",
            "voice": "af_heart",
            "session_id": "rid_w",
        },
    )
    r.content  # drain

    starts = [c for c in rec.calls if c[0] == "start"]
    assert len(starts) == 1
    _, args, _ = starts[0]
    utt_id, sentence, words, dur_ms, voice = args
    assert utt_id.startswith("rid_w_")
    assert "Hello" in sentence
    assert words == ["Hello", "karaoke", "world."]
    assert dur_ms == 1000  # 24k samples / 24kHz = 1s
    assert voice == "af_heart"


def test_synth_word_events_align_with_estimator():
    client, fp, app = make_client()
    rec = RecordingEmitter()
    app.state.karaoke = rec
    samples = 48000  # 2s
    app.state.synthesize = lambda text, **kw: _real_wav(samples)

    client.post(
        "/v2/synthesize",
        json={"text": "alpha beta gamma delta.", "voice": "af_heart"},
    ).content

    scheds = [c for c in rec.calls if c[0] == "schedule_word_events"]
    assert len(scheds) == 1
    _, args, _ = scheds[0]
    utt_id, timings = args
    # The estimator's output is deterministic — re-derive and compare.
    expected = WordTimingEstimator("af_heart").estimate(
        "alpha beta gamma delta.", audio_samples=samples
    )
    assert timings == expected
    assert timings[0] == (0, 0)
    # Word indices are monotone
    assert [t[0] for t in timings] == list(range(len(timings)))
    # tMs monotone non-decreasing
    times = [t[1] for t in timings]
    assert times == sorted(times)


def test_synth_truncated_stream_still_emits_stop():
    client, fp, app = make_client(config_overrides={"chunk_chars": 20})
    rec = RecordingEmitter()
    app.state.karaoke = rec
    calls = {"n": 0}

    def synth(text, **kw):
        calls["n"] += 1
        if calls["n"] == 1:
            return _real_wav(24000)
        raise RuntimeError("engine died mid-stream")

    app.state.synthesize = synth

    r = client.post(
        "/v2/synthesize",
        json={"text": "One two three. Four five six."},
    )
    r.content  # drain
    names = [c[0] for c in rec.calls]
    # Still exactly one stop, even on truncation — Track C relies on stop
    # to fade the ribbon out.
    assert names.count("stop") == 1
    # And state ends in error
    assert app.state.machine.state == "error"
