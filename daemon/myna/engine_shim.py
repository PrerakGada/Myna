"""Launch mlx-audio's server with the Kokoro vocoder length bug patched out.

Run as a FILE, by the engine venv's interpreter — not as `-m myna.engine_shim`.
The `myna` package lives in the daemon's environment; mlx-audio lives in
`~/.venvs/mlx-audio`. Only this file's path crosses between them, so it must
import nothing from `myna` and nothing outside the stdlib + mlx-audio.

    ~/.venvs/mlx-audio/bin/python .../myna/engine_shim.py --host H --port P

THE BUG (upstream, present in mlx-audio 0.4.4 through at least 0.4.7)
---------------------------------------------------------------------
`SineGen._f02sine()` in mlx_audio/tts/models/kokoro/istftnet.py interpolates
down by `1/upsample_scale` and back up. That round-trip does not always return
the original length, so `sine_waves` comes back one frame (300 samples) longer
than `f0`. `noise_amp` is derived from `f0`, so:

    noise = noise_amp * mx.random.normal(sine_waves.shape)
    ValueError: [broadcast_shapes] Shapes (1,34800,1) and (1,35100,9)
                cannot be broadcast

The engine 500s, the daemon turns that into a 502, and the app receives a
truncated stream and plays nothing. Measured on natural prose: 11 of 32
sentence lengths failed (~34%). It is length/content dependent and fails in
contiguous bands of word count, which is why it presents as random.

THE FIX
-------
Trim `sine_waves` and `uv` to the shorter of the two before computing
`noise_amp`. Verified against the real stack: every previously-failing length
synthesizes, and previously-working lengths return byte-identical durations.

Patching here rather than editing site-packages means `myna setup`, a
`pip install --upgrade`, or a fresh engine venv cannot silently undo it.
"""

from __future__ import annotations

import runpy
import sys


def apply_sinegen_patch() -> bool:
    """Patch SineGen.__call__ in-process. Returns True if it took effect.

    Every failure path is swallowed: a shim that refuses to start the engine
    would be strictly worse than the bug it fixes. If mlx-audio's internals
    have moved, we log and run the stock server.
    """
    try:
        import mlx.core as mx
        from mlx_audio.tts.models.kokoro import istftnet
    except Exception as exc:  # noqa: BLE001 - never block engine startup
        print(f"[myna-shim] mlx-audio internals not importable: {exc}", file=sys.stderr)
        return False

    sine_gen = getattr(istftnet, "SineGen", None)
    if sine_gen is None or not hasattr(sine_gen, "_f02sine") or not hasattr(sine_gen, "_f02uv"):
        print("[myna-shim] SineGen shape changed upstream — running unpatched", file=sys.stderr)
        return False

    def patched_call(self, f0):
        fn = f0 * mx.arange(1, self.harmonic_num + 2)[None, None, :]
        sine_waves = self._f02sine(fn) * self.sine_amp
        uv = self._f02uv(f0)
        # The interpolate round-trip above can return one frame more than f0.
        # Align both to the shorter length so noise_amp broadcasts cleanly.
        common = min(sine_waves.shape[1], uv.shape[1])
        sine_waves = sine_waves[:, :common, :]
        uv = uv[:, :common, :]
        noise_amp = uv * self.noise_std + (1 - uv) * self.sine_amp / 3
        noise = noise_amp * mx.random.normal(sine_waves.shape)
        sine_waves = sine_waves * uv + noise
        return sine_waves, uv, noise

    sine_gen.__call__ = patched_call
    print("[myna-shim] Kokoro SineGen length patch applied", file=sys.stderr)
    return True


def main() -> None:
    apply_sinegen_patch()
    # argv[0] must look like the module so mlx-audio's own arg parsing and any
    # usage/error output stay correct.
    sys.argv = ["mlx_audio.server", *sys.argv[1:]]
    runpy.run_module("mlx_audio.server", run_name="__main__")


if __name__ == "__main__":
    main()
