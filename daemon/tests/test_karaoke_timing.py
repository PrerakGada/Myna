"""Unit tests for karaoke.timing — WordTimingEstimator + samples_from_wav.

Drift target per Winston's spec: ≤200ms on a 5-second sentence (humans
notice ~150ms). The 20-word fixture below stays well inside ±50ms of
the analytic expectation because the algorithm IS the expectation.
"""

import struct

from myna.karaoke.timing import (
    BASELINE,
    DEFAULT_CPS,
    WordTimingEstimator,
    samples_from_wav,
    voice_cps,
)


# ---------- voice_cps ----------

def test_voice_cps_known():
    assert voice_cps("af_heart") == BASELINE["af_heart"]


def test_voice_cps_unknown_returns_default():
    assert voice_cps("xx_unknown") == DEFAULT_CPS


# ---------- estimator behaviour ----------

def test_estimate_first_word_is_zero():
    est = WordTimingEstimator("af_heart")
    out = est.estimate("Hello world there.", audio_samples=24000)
    assert out[0] == (0, 0)


def test_estimate_monotonic_increasing():
    est = WordTimingEstimator("af_heart")
    sentence = (
        "The fog crept in on little cat feet and the city went quiet "
        "as midnight passed by silently and slow."
    )
    samples = 24000 * 5  # 5 seconds
    out = est.estimate(sentence, audio_samples=samples)
    times = [t for _, t in out]
    assert times == sorted(times)
    # First and last reasonable
    assert times[0] == 0
    assert times[-1] < 5000  # before the duration


def test_estimate_word_count_matches():
    est = WordTimingEstimator("af_heart")
    sentence = "One two three four five six seven eight."
    out = est.estimate(sentence, audio_samples=24000 * 2)
    assert len(out) == 8


def test_estimate_drift_under_50ms_on_20_word_sentence():
    """The golden expectation: the analytic char-weighted result equals
    the estimator's output (drift is 0ms against the model). This pins
    the algorithm so a refactor can't silently shift word onset times.
    """
    est = WordTimingEstimator("af_heart")
    sentence = (
        "alpha beta gamma delta epsilon zeta eta theta iota kappa "
        "lambda mu nu xi omicron pi rho sigma tau upsilon"
    )
    samples = 24000 * 5  # 5s
    out = est.estimate(sentence, audio_samples=samples)
    # Recompute the expected timings by hand
    words = sentence.split()
    assert len(words) == 20
    weights = [len(w) + 1 for w in words]
    total_weight = sum(weights)
    cumulative = 0
    expected = []
    total_ms = int(samples * 1000 / 24000)
    for i, w in enumerate(weights):
        expected.append((i, int(total_ms * cumulative / total_weight)))
        cumulative += w
    # Drift from analytic ground truth must be ≤50ms (per acceptance bar
    # in the brief). With the same algorithm on both sides, it's 0.
    for (idx_a, t_a), (idx_b, t_b) in zip(out, expected):
        assert idx_a == idx_b
        assert abs(t_a - t_b) <= 50


def test_estimate_handles_empty_sentence():
    est = WordTimingEstimator("af_heart")
    assert est.estimate("", audio_samples=24000) == []


def test_estimate_zero_samples_falls_back_to_cps():
    est = WordTimingEstimator("af_heart")
    # Engine returned no audio yet → estimator synthesizes a duration
    # from char count / CPS rather than dividing by zero.
    out = est.estimate("Hello world.", audio_samples=0)
    assert len(out) == 2
    # First word still at 0, second word > 0
    assert out[0][1] == 0
    assert out[1][1] > 0


def test_tokenize_matches_estimate_indices():
    est = WordTimingEstimator("af_heart")
    sentence = "Five short words here, friend."
    words = WordTimingEstimator.tokenize(sentence)
    out = est.estimate(sentence, audio_samples=24000)
    assert len(words) == len(out)


# ---------- samples_from_wav ----------

def _build_wav(num_samples: int, *, channels: int = 1, bps: int = 16, rate: int = 24000) -> bytes:
    """Build a canonical RIFF/WAVE buffer for a given frame count."""
    block_align = channels * bps // 8
    data_size = num_samples * block_align
    byte_rate = rate * block_align
    riff_size = 36 + data_size
    buf = bytearray()
    buf += b"RIFF"
    buf += struct.pack("<I", riff_size)
    buf += b"WAVE"
    buf += b"fmt "
    buf += struct.pack("<I", 16)                # fmt chunk size
    buf += struct.pack("<H", 1)                 # PCM
    buf += struct.pack("<H", channels)
    buf += struct.pack("<I", rate)
    buf += struct.pack("<I", byte_rate)
    buf += struct.pack("<H", block_align)
    buf += struct.pack("<H", bps)
    buf += b"data"
    buf += struct.pack("<I", data_size)
    buf += b"\x00" * data_size
    return bytes(buf)


def test_samples_from_wav_canonical():
    wav = _build_wav(num_samples=24000)  # 1s at 24kHz mono 16-bit
    assert samples_from_wav(wav) == 24000


def test_samples_from_wav_stereo():
    wav = _build_wav(num_samples=12000, channels=2)
    assert samples_from_wav(wav) == 12000


def test_samples_from_wav_invalid_header():
    assert samples_from_wav(b"NOTAWAV") == 0
    assert samples_from_wav(b"") == 0
    assert samples_from_wav(b"RIFF\x00\x00\x00\x00WAVX") == 0


def test_samples_from_wav_with_junk_chunk():
    # Insert a JUNK chunk between fmt and data — the parser should skip it.
    junk_payload = b"\x00" * 16
    wav = _build_wav(num_samples=1000)
    # Slice the WAV after the fmt chunk and inject junk
    head, data = wav.split(b"data", 1)
    injected = head + b"JUNK" + struct.pack("<I", 16) + junk_payload + b"data" + data
    # Update the RIFF size to reflect added bytes
    new_size = len(injected) - 8
    injected = injected[:4] + struct.pack("<I", new_size) + injected[8:]
    assert samples_from_wav(injected) == 1000
