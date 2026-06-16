"""Tests for GET /v2/voices/preview/{voice_id}.

Spec: docs/v0.2-plan/01-feature-stories.md S09.
"""

import json
import pathlib

import pytest

from myna.voice_previews import (
    SAMPLES,
    VoicePreviewCache,
    sample_for_voice,
)

from .v2_helpers import make_client


# ---------- module-level helpers ----------

def test_sample_for_voice_is_deterministic():
    s1 = sample_for_voice("af_heart")
    s2 = sample_for_voice("af_heart")
    assert s1 == s2
    assert s1 in SAMPLES


def test_samples_pool_has_variety():
    # Must include a question and a list — the README documents that mix
    # for prosody contrast; if someone trims the pool, fail loudly.
    assert any("?" in s for s in SAMPLES)
    assert any("," in s for s in SAMPLES)


# ---------- cache invalidation ----------

def test_cache_wipes_on_engine_version_bump(tmp_path):
    cache_dir = tmp_path / "vpc"
    cache = VoicePreviewCache(cache_dir=cache_dir, engine_version="v1")
    cache.put("af_heart", b"RIFFv1")
    assert cache.get("af_heart") == b"RIFFv1"

    # New cache with bumped version — should nuke the dir
    cache2 = VoicePreviewCache(cache_dir=cache_dir, engine_version="v2")
    assert cache2.get("af_heart") is None


def test_cache_keeps_files_when_version_matches(tmp_path):
    cache_dir = tmp_path / "vpc"
    cache = VoicePreviewCache(cache_dir=cache_dir, engine_version="v1")
    cache.put("af_heart", b"RIFFv1")
    # Re-open with same version
    cache2 = VoicePreviewCache(cache_dir=cache_dir, engine_version="v1")
    assert cache2.get("af_heart") == b"RIFFv1"


# ---------- HTTP route ----------

def _route_client(tmp_path):
    client, fp, app = make_client()
    # Re-point voice preview cache to a tmp dir so this test never touches
    # the user's ~/Library/Caches.
    app.state.voice_preview_cache = VoicePreviewCache(
        cache_dir=tmp_path / "vpc",
        engine_version=app.state.engine_version,
    )
    return client, fp, app


def test_preview_synthesizes_on_miss(tmp_path):
    client, fp, app = _route_client(tmp_path)
    captured = {}

    def synth(text, **kw):
        captured["text"] = text
        captured["voice"] = kw["voice"]
        return b"RIFFsynth"

    app.state.synthesize = synth
    r = client.get("/v2/voices/preview/af_heart")
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/wav"
    assert r.content == b"RIFFsynth"
    assert captured["voice"] == "af_heart"
    # Text drawn from the curated pool
    assert captured["text"] in SAMPLES


def test_preview_hits_cache_on_second_call(tmp_path):
    client, fp, app = _route_client(tmp_path)
    calls = {"n": 0}

    def synth(text, **kw):
        calls["n"] += 1
        return b"RIFFsynth"

    app.state.synthesize = synth
    r1 = client.get("/v2/voices/preview/af_heart")
    r2 = client.get("/v2/voices/preview/af_heart")
    assert r1.content == r2.content == b"RIFFsynth"
    assert calls["n"] == 1  # second call served from cache


def test_preview_503_when_thinking(tmp_path):
    client, fp, app = _route_client(tmp_path)
    app.state.machine.force("thinking", request_id="r")
    r = client.get("/v2/voices/preview/af_heart")
    assert r.status_code == 503
    assert r.headers.get("retry-after") == "2"
    body = r.json()
    assert body["ok"] is False
    assert body["reason"] == "engine_thinking"


def test_preview_ignores_stale_thinking(tmp_path):
    """A wedged 'thinking' older than the warming window must NOT block
    previews forever. Regression guard for the daemon getting stuck after an
    interrupted synth whose state never reset (root cause of recurring
    'audio stopped working' reports)."""
    client, fp, app = _route_client(tmp_path)
    app.state.synthesize = lambda text, **kw: b"RIFFfresh"
    app.state.machine.force("thinking", request_id="r")
    # Simulate the state having been entered ~100s ago — well past the 45s
    # STALE_THINKING_MS window the preview gate honours.
    app.state.machine._entered_at -= 100
    r = client.get("/v2/voices/preview/af_heart")
    assert r.status_code == 200
    assert r.content == b"RIFFfresh"


def test_preview_503_when_engine_down(tmp_path):
    client, fp, app = _route_client(tmp_path)
    app.state.engine_up = lambda base_url, **kw: False
    app.state.last_engine_check_at = 0.0
    r = client.get("/v2/voices/preview/af_heart")
    assert r.status_code == 503
    assert r.headers.get("retry-after") == "2"


def test_preview_502_on_engine_exception(tmp_path):
    client, fp, app = _route_client(tmp_path)

    def boom(text, **kw):
        raise RuntimeError("kokoro crashed")

    app.state.synthesize = boom
    r = client.get("/v2/voices/preview/af_heart")
    assert r.status_code == 502
    assert r.json()["reason"] == "engine_error"


def test_preview_persists_to_disk(tmp_path):
    client, fp, app = _route_client(tmp_path)
    app.state.synthesize = lambda text, **kw: b"RIFFsavedwav"
    client.get("/v2/voices/preview/af_bella")
    wav_path = app.state.voice_preview_cache.path_for("af_bella")
    assert wav_path.exists()
    assert wav_path.read_bytes() == b"RIFFsavedwav"
    # And manifest is written
    manifest = json.loads(
        (app.state.voice_preview_cache.manifest_path).read_text()
    )
    assert manifest["engine_version"] == app.state.engine_version
