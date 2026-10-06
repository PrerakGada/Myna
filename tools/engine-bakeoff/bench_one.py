"""Measure one TTS engine the way Myna uses it. Phase 0 of the multi-engine plan.

Run by the bake-off venv's interpreter, one engine per process so memory and
crashes stay isolated:

    venv/bin/python bench_one.py <engine_id> <out_dir>

What it measures, and why each number matters to Myna:
  load_s        model load from a warm disk cache (what a switch costs)
  first_audio_s Myna's first chunk is capped at 15 words and synthesized as
                one non-streaming request (config.py first_chunk_max_words),
                so the time to synthesize that sentence IS the wait before
                the first word. Median of 3, after a warm-up.
  stream_first_s time to the first streamed chunk, for engines that stream
  rtf           seconds of audio produced per second of wall time on a
                ~1,400-character article paragraph (>1 = faster than speech)
  peak_mem_mb   MLX peak memory during the long synthesis (weights included)
  wer           word error rate of a Parakeet transcript of the long clip
                against the input — an objective "did it say the words" check,
                not a quality score. Listening decides quality.
"""

from __future__ import annotations

import json
import os
import pathlib
import statistics
import sys
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from engines import ENGINES, FIRST_CHUNK, LONG_TEXT, WARMUP  # noqa: E402


def _hf_size_mb(repo: str) -> float | None:
    try:
        from huggingface_hub import snapshot_download

        path = pathlib.Path(snapshot_download(repo))
        total = sum(p.stat().st_size for p in path.rglob("*") if p.is_file())
        return total / 1e6
    except Exception:
        return None


def _collect(gen) -> tuple[list, int]:
    """Drain a generate() iterator into one numpy array + sample rate."""
    import numpy as np

    parts, sr = [], None
    for r in gen:
        parts.append(np.array(r.audio, dtype=np.float32).reshape(-1))
        sr = r.sample_rate
    audio = np.concatenate(parts) if parts else np.zeros(0, dtype=np.float32)
    return audio, sr


class _Result:
    def __init__(self, audio, sample_rate):
        self.audio, self.sample_rate = audio, sample_rate


class SupertonicModel:
    """Supertonic runs on ONNX, not MLX: wrap it in mlx-audio's generate()
    shape so the same measurements apply. Memory comes from the process's
    peak RSS instead of MLX's allocator."""

    def __init__(self, voice: str = "F1", steps: int = 8):
        from supertonic import TTS

        self.tts = TTS(auto_download=True)
        self.style = self.tts.get_voice_style(voice_name=voice)
        self.steps = steps
        self.sample_rate = int(getattr(self.tts, "sample_rate", 44100))

    def generate(self, text, **_):
        import numpy as np

        wav, _dur = self.tts.synthesize(
            text, voice_style=self.style, total_steps=self.steps, speed=1.0, lang="en"
        )
        yield _Result(np.asarray(wav, dtype=np.float32).reshape(-1), self.sample_rate)


def _peak_rss_mb() -> float:
    import resource

    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def main() -> None:
    engine_id, out_dir = sys.argv[1], pathlib.Path(sys.argv[2])
    spec = ENGINES[engine_id]
    if spec.get("runtime") == "supertonic":
        return main_supertonic(engine_id, out_dir, spec)
    main_mlx(engine_id, out_dir, spec)


def main_supertonic(engine_id: str, out_dir: pathlib.Path, spec: dict) -> None:
    import numpy as np
    import soundfile as sf

    result: dict = {"engine": engine_id, "repo": spec["repo"], "ok": False}
    try:
        t = time.perf_counter()
        model = SupertonicModel(**spec.get("gen", {}))
        result["load_s"] = time.perf_counter() - t
        cache = pathlib.Path.home() / ".cache" / "supertonic3"
        if cache.exists():
            result["disk_mb"] = sum(p.stat().st_size for p in cache.rglob("*") if p.is_file()) / 1e6
        _collect(model.generate(WARMUP))
        firsts = []
        for _ in range(3):
            t = time.perf_counter()
            audio, sr = _collect(model.generate(FIRST_CHUNK))
            firsts.append(time.perf_counter() - t)
        result["first_audio_s"] = statistics.median(firsts)
        result["first_audio_all"] = firsts
        sf.write(out_dir / f"{engine_id}_short.wav", audio, sr)
        t = time.perf_counter()
        audio, sr = _collect(model.generate(LONG_TEXT))
        wall = time.perf_counter() - t
        dur = len(audio) / sr
        result.update(
            long_wall_s=wall, long_audio_s=dur, rtf=dur / wall,
            peak_mem_mb=_peak_rss_mb(), mem_note="process peak RSS (ONNX)",
            sample_rate=sr,
        )
        sf.write(out_dir / f"{engine_id}_long.wav", audio, sr)
        result["ok"] = True
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"[:600]
        result["traceback"] = traceback.format_exc()[-2500:]
    (out_dir / f"{engine_id}.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "traceback"}, indent=2))


def main_mlx(engine_id: str, out_dir: pathlib.Path, spec: dict) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    result: dict = {"engine": engine_id, "repo": spec["repo"], "ok": False}

    try:
        import mlx.core as mx
        import numpy as np
        import soundfile as sf
        from mlx_audio.tts.utils import load_model

        kwargs = dict(spec.get("gen", {}))
        if spec.get("needs_ref"):
            kwargs["ref_audio"] = str(out_dir / "_reference.wav")
            if spec.get("ref_text"):
                kwargs["ref_text"] = spec["ref_text"]

        result["disk_mb"] = _hf_size_mb(spec["repo"])

        t = time.perf_counter()
        model = load_model(spec["repo"])
        mx.eval(model.parameters()) if hasattr(model, "parameters") else None
        result["load_s"] = time.perf_counter() - t
        result["weights_mb"] = mx.get_active_memory() / 1e6

        _collect(model.generate(WARMUP, **kwargs))

        firsts = []
        for _ in range(3):
            t = time.perf_counter()
            audio, sr = _collect(model.generate(FIRST_CHUNK, **kwargs))
            firsts.append(time.perf_counter() - t)
        result["first_audio_s"] = statistics.median(firsts)
        result["first_audio_all"] = firsts
        sf.write(out_dir / f"{engine_id}_short.wav", audio, sr)

        if spec.get("stream"):
            try:
                t = time.perf_counter()
                for _chunk in model.generate(
                    FIRST_CHUNK, stream=True, streaming_interval=0.32, **kwargs
                ):
                    result["stream_first_s"] = time.perf_counter() - t
                    break
            except Exception as exc:  # noqa: BLE001
                result["stream_error"] = f"{type(exc).__name__}: {exc}"[:300]

        mx.reset_peak_memory()
        t = time.perf_counter()
        audio, sr = _collect(model.generate(LONG_TEXT, **kwargs))
        wall = time.perf_counter() - t
        dur = len(audio) / sr if sr else 0.0
        result.update(
            long_wall_s=wall,
            long_audio_s=dur,
            rtf=(dur / wall) if wall else None,
            peak_mem_mb=mx.get_peak_memory() / 1e6,
            sample_rate=sr,
        )
        sf.write(out_dir / f"{engine_id}_long.wav", audio, sr)
        result["ok"] = True
    except Exception as exc:  # noqa: BLE001 - a failing engine is a result
        result["error"] = f"{type(exc).__name__}: {exc}"[:600]
        result["traceback"] = traceback.format_exc()[-2500:]

    (out_dir / f"{engine_id}.json").write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k != "traceback"}, indent=2))


if __name__ == "__main__":
    main()
