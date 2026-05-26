"""Word-timing estimation (Option B — char-weighted per-voice CPS).

Drift target: ≤200ms on 5-second sentences. See Winston's analysis in
docs/v0.2-plan/02-karaoke-architecture.md § 3.

The estimator is intentionally cheap, deterministic, and dependency-free:
given a sentence + the total audio sample count, it returns
[(word_index, t_ms), ...] anchored at sentence start (t_ms[0] == 0).
"""

from __future__ import annotations

import struct


def samples_from_wav(wav_bytes: bytes) -> int:
    """Return the number of audio frames in a RIFF/WAVE buffer.

    Robust to:
      - missing/short header (returns 0 → caller falls back to CPS guess)
      - non-PCM formats (best-effort: uses 'data' chunk size / block align)
      - extra chunks before the format chunk (LIST / fmt + JUNK + data)

    This is a pragmatic parser, not a full implementation — Kokoro emits
    canonical 24kHz 16-bit mono LE WAVs. If a future engine ships something
    weirder we'll hear about it from the integration test.
    """
    if len(wav_bytes) < 44 or wav_bytes[0:4] != b"RIFF" or wav_bytes[8:12] != b"WAVE":
        return 0
    # Walk chunks looking for 'fmt ' and 'data'.
    pos = 12
    block_align = 2  # default for 16-bit mono
    data_size = 0
    while pos + 8 <= len(wav_bytes):
        chunk_id = wav_bytes[pos:pos + 4]
        try:
            chunk_size = struct.unpack_from("<I", wav_bytes, pos + 4)[0]
        except struct.error:
            return 0
        chunk_start = pos + 8
        if chunk_id == b"fmt " and chunk_size >= 16:
            try:
                # fmt chunk layout: audio_format(2), num_channels(2),
                # sample_rate(4), byte_rate(4), block_align(2), bps(2)
                block_align = struct.unpack_from(
                    "<H", wav_bytes, chunk_start + 12
                )[0] or 2
            except struct.error:
                pass
        elif chunk_id == b"data":
            data_size = chunk_size
            break
        pos = chunk_start + chunk_size
        # Chunks pad to even byte boundaries
        if chunk_size & 1:
            pos += 1
    if data_size == 0 or block_align == 0:
        return 0
    return data_size // block_align


# Chars-per-second baseline per voice. Measured empirically once per voice
# (placeholder values today — calibrate before v0.3 if drift is wider than
# the ±200ms tolerance Winston quoted). Unknown voices fall back to 14.0.
BASELINE: dict[str, float] = {
    "af_heart": 14.0,
    "af_bella": 13.8,
    "af_sky": 13.5,
    "am_michael": 14.2,
    "am_adam": 14.5,
    "bf_emma": 13.6,
    "bm_lewis": 14.3,
}

DEFAULT_CPS = 14.0


def voice_cps(voice: str) -> float:
    return BASELINE.get(voice, DEFAULT_CPS)


class WordTimingEstimator:
    """Char-weighted timing estimator.

    Construction args:
        voice:        Kokoro voice id (e.g. "af_heart"); selects the CPS baseline.
        sample_rate:  audio sample rate of synthesized WAV (Kokoro defaults to 24k).

    Method:
        estimate(sentence, audio_samples) -> list of (word_index, t_ms_relative_to_start)

    Algorithm:
        Total duration: total_ms = audio_samples * 1000 / sample_rate.
        Per-word weight: len(word) + 1 (the +1 accounts for the trailing space).
        Cumulative weight up to (but not including) word i divided by total weight
        gives the word's onset as a fraction of total duration.
        t_ms[0] is always 0; t_ms[i] ascends monotonically.
    """

    def __init__(self, voice: str, sample_rate: int = 24000):
        self.voice = voice
        self.cps = voice_cps(voice)
        self.sample_rate = sample_rate

    def estimate(
        self,
        sentence: str,
        audio_samples: int,
    ) -> list[tuple[int, int]]:
        words = sentence.split()
        if not words:
            return []
        total_ms = int(audio_samples * 1000 / self.sample_rate)
        if total_ms <= 0:
            # No audio yet (engine returned zero-length / unknown duration).
            # Fall back to CPS-driven synthetic duration so the estimator
            # still emits a usable rampset.
            total_chars = sum(len(w) + 1 for w in words)
            total_ms = max(1, int(1000.0 * total_chars / self.cps))
        weights = [len(w) + 1 for w in words]
        total_weight = sum(weights)
        out: list[tuple[int, int]] = []
        cumulative = 0
        for i, w in enumerate(weights):
            out.append((i, int(total_ms * cumulative / total_weight)))
            cumulative += w
        return out

    # -------- helpers used by callers when building the start frame --------

    def estimated_duration_ms(self, sentence: str, audio_samples: int) -> int:
        if audio_samples > 0:
            return int(audio_samples * 1000 / self.sample_rate)
        # Fallback: CPS-derived synthetic duration
        words = sentence.split()
        chars = sum(len(w) + 1 for w in words)
        return max(1, int(1000.0 * chars / self.cps))

    @staticmethod
    def tokenize(sentence: str) -> list[str]:
        """Public tokenizer — sidecar must NOT re-tokenize.

        Returns the same list `estimate()` indexes against. Single source
        of truth: whitespace split. If a future revision adds punctuation
        handling it MUST update this method (sidecar's i values must line
        up with the words list emitted in the start frame).
        """
        return sentence.split()
