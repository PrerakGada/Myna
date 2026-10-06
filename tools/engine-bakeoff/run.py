"""Run the whole bake-off: download, make the clone reference, bench each
engine in its own process, transcribe for word error rate, write a report.

    venv/bin/python run.py <out_dir> [engine_id ...]
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from engines import ENGINES, LONG_TEXT, REFERENCE_TEXT  # noqa: E402

STT_REPO = "mlx-community/parakeet-tdt-0.6b-v3"


def engine_env() -> dict:
    """Same espeak paths the daemon's supervisor gives the real engine."""
    env = dict(os.environ)
    import espeakng_loader as e

    env.setdefault("PHONEMIZER_ESPEAK_LIBRARY", e.get_library_path())
    env.setdefault("ESPEAK_DATA_PATH", e.get_data_path())
    return env


def download(repos: list[str]) -> None:
    from huggingface_hub import snapshot_download

    for repo in repos:
        print(f"==> download {repo}", flush=True)
        try:
            snapshot_download(repo)
        except Exception as exc:  # noqa: BLE001
            print(f"    download failed: {exc}", flush=True)


def make_reference(out: pathlib.Path) -> None:
    ref = out / "_reference.wav"
    if ref.exists():
        return
    code = (
        "import numpy as np, soundfile as sf\n"
        "from mlx_audio.tts.utils import load_model\n"
        f"m = load_model({ENGINES['kokoro']['repo']!r})\n"
        f"rs = list(m.generate({REFERENCE_TEXT!r}, voice='am_michael', lang_code='a'))\n"
        "a = np.concatenate([np.array(r.audio).reshape(-1) for r in rs])\n"
        f"sf.write({str(ref)!r}, a, rs[0].sample_rate)\n"
    )
    subprocess.run([sys.executable, "-c", code], env=engine_env(), check=True)


def _words(text: str) -> list[str]:
    text = text.lower().replace("’", "'")
    return re.findall(r"[a-z0-9']+", text)


def wer(ref: str, hyp: str) -> float:
    r, h = _words(ref), _words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r))


def transcribe_all(out: pathlib.Path, ids: list[str]) -> None:
    from mlx_audio.stt.utils import load_model

    stt = load_model(STT_REPO)
    # The reference transcript is Parakeet reading Kokoro-free ground truth:
    # the input text itself. Numbers are compared as words Parakeet writes,
    # so every engine pays the same normalization noise.
    for eid in ids:
        res_path = out / f"{eid}.json"
        wav = out / f"{eid}_long.wav"
        if not res_path.exists() or not wav.exists():
            continue
        res = json.loads(res_path.read_text())
        try:
            text = stt.generate(str(wav)).text
            res["transcript"] = text
            res["wer"] = wer(LONG_TEXT, text)
        except Exception as exc:  # noqa: BLE001
            res["wer_error"] = str(exc)[:300]
        res_path.write_text(json.dumps(res, indent=2))


def main() -> None:
    out = pathlib.Path(sys.argv[1]).resolve()
    ids = sys.argv[2:] or list(ENGINES)
    out.mkdir(parents=True, exist_ok=True)
    download(sorted({ENGINES[i]["repo"] for i in ids if "runtime" not in ENGINES[i]} | {STT_REPO}))
    make_reference(out)
    for eid in ids:
        print(f"==> bench {eid}", flush=True)
        try:
            # Non-MLX runtimes live in their own venv (BAKEOFF_<RUNTIME>_PY).
            runtime = ENGINES[eid].get("runtime")
            py = os.environ.get(f"BAKEOFF_{runtime.upper()}_PY") if runtime else None
            subprocess.run(
                [py or sys.executable, str(HERE / "bench_one.py"), eid, str(out)],
                env=engine_env(),
                timeout=900,
            )
        except subprocess.TimeoutExpired:
            (out / f"{eid}.json").write_text(
                json.dumps({"engine": eid, "ok": False, "error": "timed out after 15 min"})
            )
    transcribe_all(out, ids)
    print(f"==> done: {out}")


if __name__ == "__main__":
    main()
