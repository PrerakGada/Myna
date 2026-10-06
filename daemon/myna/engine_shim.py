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

CHATTERBOX AND CLIP VOICES (mlx-audio 0.5.7)
--------------------------------------------
Chatterbox Turbo speaks in a clip's voice when a request carries
`ref_audio`. Two things upstream make that unusable as-is:

  * `prepare_conditionals()` stores the clip's voice on the model
    (`self._conds`), replacing the built-in voice for good. A read in the
    built-in voice after a cloned one comes out in the clone's voice until
    the engine restarts.
  * It re-analyses the clip on every request (~0.5 s), and Myna sends one
    request per sentence.

`apply_chatterbox_voice_patch` keeps the built-in conditionals aside and
restores them for any request without `ref_audio`, and caches the
conditionals derived from each clip (keyed by the audio's bytes).
"""

from __future__ import annotations

import collections
import hashlib
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
    if sine_gen is not None and hasattr(sine_gen, "_match_f0_length"):
        # mlx-audio 0.5.x fixed this upstream (it trims sine_waves to f0's
        # length itself). Patching over it would only replace the fix.
        print("[myna-shim] SineGen already length-safe upstream — no patch needed", file=sys.stderr)
        return False
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


_CLIP_CACHE_SIZE = 8


def apply_chatterbox_voice_patch() -> bool:
    """Make Chatterbox Turbo's clip voices per-request and cached. See the
    module docstring. Returns True if the patch took effect; never raises."""
    try:
        import numpy as np
        from mlx_audio.tts.models.chatterbox_turbo import chatterbox_turbo as ct
    except Exception as exc:  # noqa: BLE001 - never block engine startup
        print(f"[myna-shim] Chatterbox not importable, clip patch skipped: {exc}", file=sys.stderr)
        return False
    cls = getattr(ct, "ChatterboxTurboTTS", None)
    if cls is None or not hasattr(cls, "prepare_conditionals") or not hasattr(cls, "generate"):
        print("[myna-shim] Chatterbox shape changed upstream — clip patch skipped", file=sys.stderr)
        return False

    original_prepare = cls.prepare_conditionals
    original_generate = cls.generate

    def _state(model) -> dict:
        # object.__setattr__: mlx's Module is a dict and would otherwise try
        # to treat this as a parameter.
        state = model.__dict__.get("_myna_voice_state")
        if state is None:
            state = {"builtin": model._conds, "clips": collections.OrderedDict()}
            object.__setattr__(model, "_myna_voice_state", state)
        return state

    def _key(ref_audio, args, kwargs) -> str:
        if isinstance(ref_audio, str):
            raw = ref_audio.encode()
        else:
            raw = np.asarray(ref_audio).tobytes()
        extra = repr((args, sorted(kwargs.items()))).encode()
        return hashlib.blake2b(raw + extra, digest_size=16).hexdigest()

    def prepare_conditionals(self, ref_audio, *args, **kwargs):
        clips = _state(self)["clips"]
        key = _key(ref_audio, args, kwargs)
        if key in clips:
            clips.move_to_end(key)
            self._conds = clips[key]
            return None
        result = original_prepare(self, ref_audio, *args, **kwargs)
        clips[key] = self._conds
        while len(clips) > _CLIP_CACHE_SIZE:
            clips.popitem(last=False)
        return result

    def generate(self, text, *args, **kwargs):
        state = _state(self)  # first call captures the built-in voice
        if kwargs.get("ref_audio") is None and state["builtin"] is not None:
            self._conds = state["builtin"]
        yield from original_generate(self, text, *args, **kwargs)

    cls.prepare_conditionals = prepare_conditionals
    cls.generate = generate
    print("[myna-shim] Chatterbox clip-voice patch applied", file=sys.stderr)
    return True


def main() -> None:
    apply_sinegen_patch()
    apply_chatterbox_voice_patch()
    # argv[0] must look like the module so mlx-audio's own arg parsing and any
    # usage/error output stay correct.
    sys.argv = ["mlx_audio.server", *sys.argv[1:]]
    runpy.run_module("mlx_audio.server", run_name="__main__")


if __name__ == "__main__":
    main()
