"""Karaoke subtitle ribbon — daemon side.

Sub-modules:
    timing  — WordTimingEstimator (Option B: char-weighted per-voice CPS)
    socket  — KaraokeClient that writes NDJSON to ~/.myna/karaoke.sock

See docs/v0.2-plan/02-karaoke-architecture.md for the full protocol spec
(Winston). The wire schemas defined in this package are LOCKED for v0.2 —
Track C ships sidecar code reading those exact shapes.
"""
