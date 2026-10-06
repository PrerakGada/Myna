# Engine bake-off

Phase 0 of multi-engine support: measure candidate voice engines on this Mac
the way Myna uses them, before building any UI around them.

```sh
# one-time: an isolated venv (never the live ~/.venvs/mlx-audio).
# Keep it at a SHORT path — espeak fails to find its data under a long one
# (e.g. a Claude scratchpad), which looks like a phonemizer bug but isn't.
uv venv --python 3.13 ~/.venvs/myna-bakeoff
uv pip install --python ~/.venvs/myna-bakeoff/bin/python 'mlx-audio[server]==0.5.7' \
  'misaki<0.8' num2words spacy phonemizer espeakng-loader soundfile psutil sentencepiece \
  https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl

# optional: Supertonic runs on ONNX, in its own venv
uv venv --python 3.13 ~/.venvs/myna-bakeoff-onnx
uv pip install --python ~/.venvs/myna-bakeoff-onnx/bin/python supertonic soundfile numpy

BAKEOFF_SUPERTONIC_PY=~/.venvs/myna-bakeoff-onnx/bin/python \
  ~/.venvs/myna-bakeoff/bin/python run.py ~/.cache/myna-bakeoff/out [engine_id ...]
python3 report.py ~/.cache/myna-bakeoff/out   # → report.html with audio players
```

Candidates and test texts live in `engines.py`. What each number means is in
the docstring of `bench_one.py`. If a Hugging Face download hangs, re-run with
`HF_HUB_DISABLE_XET=1`.
