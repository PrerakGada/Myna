"""Voice-engine catalog, switching and download state (myna.engines + engine_store)."""

from __future__ import annotations

import pathlib

import pytest

from myna import app as app_mod
from myna import engines
from myna.engine_store import EngineStore, repo_dir

from .v2_helpers import make_client


# ----- catalog -----


def test_catalog_has_the_four_shortlisted_engines():
    assert [s.id for s in engines.CATALOG] == ["kokoro", "soprano", "pocket", "chatterbox"]
    assert engines.get("kokoro").native_speed is True
    assert all(not s.native_speed for s in engines.CATALOG if s.id != "kokoro")


def test_active_spec_resolves_legacy_configs():
    # No `engine` key, stock model → Kokoro.
    assert engines.active_spec({"model": "prince-canuma/Kokoro-82M"}).id == "kokoro"
    # No `engine` key, a catalog repo → that engine.
    assert engines.active_spec({"model": "mlx-community/pocket-tts"}).id == "pocket"
    # A custom repo stays Kokoro-shaped and keeps the custom repo.
    custom = engines.active_spec({"model": "someone/Kokoro-fork"})
    assert custom.id == "kokoro" and custom.repo == "someone/Kokoro-fork"
    # Explicit engine wins over a stale model.
    assert engines.active_spec({"engine": "soprano", "model": "prince-canuma/Kokoro-82M"}).id == "soprano"


def test_resolve_voice_maps_foreign_voices():
    pocket = engines.get("pocket")
    kokoro = engines.get("kokoro")
    assert engines.resolve_voice(pocket, "marius", None) == "marius"
    # The app still says af_heart after a switch to Pocket → Pocket's default.
    assert engines.resolve_voice(pocket, "af_heart", None) == "alba"
    # …or the voice last used on Pocket.
    assert engines.resolve_voice(pocket, "af_heart", "javert") == "javert"
    # Any Kokoro-shaped id is a Kokoro voice, even one not in the short list.
    assert engines.resolve_voice(kokoro, "bf_emma", None) == "bf_emma"
    assert engines.resolve_voice(kokoro, "alba", "am_adam") == "am_adam"


# ----- synthesize path -----


def _capture_synth(app):
    calls = []

    def synth(text, **kw):
        calls.append(kw)
        return b"RIFFfake"

    app.state.synthesize = synth
    return calls


def test_synth_sends_active_engine_model_voice_and_settings():
    client, _, app = make_client(config_overrides={"engine": "soprano", "model": "x"})
    calls = _capture_synth(app)
    r = client.post("/v2/synthesize", json={"text": "Hello there.", "voice": "af_heart", "speed": 1.0})
    assert r.status_code == 200
    kw = calls[0]
    assert kw["model"] == "mlx-community/Soprano-1.1-80M-bf16"
    assert kw["voice"] == "soprano"
    # Soprano's own sampling defaults, not the server's generic 0.7.
    assert kw["extra"]["temperature"] == 0.3


def test_kokoro_synth_sends_no_extra_settings():
    client, _, app = make_client()
    calls = _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": "am_adam", "speed": 1.0})
    assert calls[0]["voice"] == "am_adam"
    assert "extra" not in calls[0]


# ----- /v2/voices -----


def test_voices_lists_the_active_engines_voices():
    client, _, _ = make_client(config_overrides={"engine": "pocket"})
    voices = client.get("/v2/voices").json()["voices"]
    assert [v["id"] for v in voices][:2] == ["alba", "marius"]
    assert [v["id"] for v in voices if v["default"]] == ["alba"]


# ----- /v2/engines -----


def _store_with(tmp_path: pathlib.Path, installed: set[str]) -> EngineStore:
    hub = tmp_path / "hub"
    for spec in engines.CATALOG:
        if spec.id not in installed:
            continue
        for d in spec.downloads:
            snap = repo_dir(d.repo, hub) / "snapshots" / (d.revision or "abc")
            snap.mkdir(parents=True, exist_ok=True)
            if d.allow_patterns:
                for pat in d.allow_patterns:
                    f = snap / pat
                    f.parent.mkdir(parents=True, exist_ok=True)
                    f.write_bytes(b"x")
            else:
                (snap / "model.safetensors").write_bytes(b"x" * 10)
    return EngineStore(venv_dir=str(tmp_path / "venv"), hub_dir=hub)


def test_engines_endpoint_shape(tmp_path):
    client, _, app = make_client()
    app.state.engine_store = _store_with(tmp_path, {"kokoro", "pocket"})
    body = client.get("/v2/engines").json()
    assert body["active"] == "kokoro"
    by_id = {e["id"]: e for e in body["engines"]}
    assert by_id["kokoro"]["active"] is True
    assert by_id["kokoro"]["state"] == "installed"
    assert by_id["pocket"]["state"] == "installed"
    assert by_id["soprano"]["state"] == "not_installed"
    stats = by_id["soprano"]["stats"]
    assert {"first_word_s", "speed_x", "peak_memory_mb", "word_error_pct", "measured_on"} <= stats.keys()
    assert by_id["pocket"]["credit"].startswith("Pocket TTS by Kyutai")


def test_activate_switches_persists_and_unloads_previous(tmp_path, monkeypatch):
    client, _, app = make_client()
    app.state.engine_store = _store_with(tmp_path, {"kokoro", "pocket"})
    saved = []
    app.state.save_config = saved.append
    loaded, unloaded = [], []
    monkeypatch.setattr(app_mod.engine, "load_model", lambda url, model, **kw: loaded.append(model))
    monkeypatch.setattr(app_mod.engine, "unload_model", lambda url, model, **kw: unloaded.append(model))
    calls = _capture_synth(app)

    r = client.post("/v2/engines/pocket/activate")
    assert r.status_code == 200, r.text
    assert r.json()["active"] == "pocket"
    assert r.json()["voice"] == "alba"
    assert loaded == ["mlx-community/pocket-tts"]
    assert unloaded == ["prince-canuma/Kokoro-82M"]
    # The warm-up line went to Pocket with Pocket's settings.
    assert calls[-1]["model"] == "mlx-community/pocket-tts"
    assert saved[-1]["engine"] == "pocket"
    assert saved[-1]["engine_voices"]["kokoro"] == "af_heart"
    assert client.get("/v2/status").json()["engine"]["id"] == "pocket"


def test_activate_failure_leaves_previous_engine(tmp_path, monkeypatch):
    client, _, app = make_client()
    app.state.engine_store = _store_with(tmp_path, {"kokoro", "pocket"})
    app.state.save_config = lambda _u: pytest.fail("must not persist a failed switch")

    def boom(url, model, **kw):
        raise RuntimeError("model load failed")

    monkeypatch.setattr(app_mod.engine, "load_model", boom)
    r = client.post("/v2/engines/pocket/activate")
    assert r.status_code == 502
    assert client.get("/v2/engines").json()["active"] == "kokoro"


def test_activate_requires_download(tmp_path):
    client, _, app = make_client()
    app.state.engine_store = _store_with(tmp_path, {"kokoro"})
    r = client.post("/v2/engines/chatterbox/activate")
    assert r.status_code == 409
    assert r.json()["detail"]["reason"] == "not_installed"


def test_unknown_engine_is_404():
    client, _, _ = make_client()
    assert client.post("/v2/engines/nope/activate").status_code == 404


def test_cannot_remove_active_or_default(tmp_path):
    client, _, app = make_client(config_overrides={"engine": "pocket"})
    app.state.engine_store = _store_with(tmp_path, {"kokoro", "pocket"})
    assert client.delete("/v2/engines/pocket").status_code == 409  # active
    assert client.delete("/v2/engines/kokoro").status_code == 409  # fallback


def test_remove_deletes_only_that_engines_files(tmp_path):
    store = _store_with(tmp_path, {"kokoro", "pocket", "soprano"})
    store.remove("pocket")
    assert not store.is_installed(engines.get("pocket"))
    assert store.is_installed(engines.get("soprano"))
    assert store.is_installed(engines.get("kokoro"))


# ----- engine_store state -----


def test_dangling_snapshot_link_is_not_installed(tmp_path):
    store = _store_with(tmp_path, {"chatterbox"})
    spec = engines.get("chatterbox")
    assert store.is_installed(spec)
    snap = repo_dir("mlx-community/S3TokenizerV2", store.hub) / "snapshots" / "abc"
    (snap / "model.safetensors").unlink()
    (snap / "model.safetensors").symlink_to(snap / "missing-blob")
    assert not store.is_installed(spec)


def test_stale_incomplete_blob_does_not_hide_a_finished_download(tmp_path):
    store = _store_with(tmp_path, {"chatterbox"})
    blobs = repo_dir("mlx-community/S3TokenizerV2", store.hub) / "blobs"
    blobs.mkdir(parents=True, exist_ok=True)
    (blobs / "abc.3e76db28.incomplete").write_bytes(b"x")
    assert store.is_installed(engines.get("chatterbox"))


def test_install_without_engine_venv_is_refused(tmp_path):
    client, _, app = make_client()
    app.state.engine_store = EngineStore(venv_dir=str(tmp_path / "missing"), hub_dir=tmp_path / "hub")
    r = client.post("/v2/engines/soprano/install")
    assert r.status_code == 409
    assert r.json()["detail"]["reason"] == "no_engine_venv"


def test_shared_hub_store_sizes_and_removal(tmp_path):
    """Newer huggingface_hub links repo blobs into a hub-wide store."""
    hub = tmp_path / "hub"
    store_file = hub / "blobs" / "1f" / "abc"
    store_file.parent.mkdir(parents=True)
    store_file.write_bytes(b"x" * 5000)
    shared_file = hub / "blobs" / "2e" / "def"
    shared_file.parent.mkdir(parents=True)
    shared_file.write_bytes(b"y" * 100)

    def link_repo(repo, targets):
        root = repo_dir(repo, hub)
        (root / "blobs").mkdir(parents=True)
        snap = root / "snapshots" / "rev"
        snap.mkdir(parents=True)
        for i, t in enumerate(targets):
            (root / "blobs" / f"b{i}").symlink_to(t)
            (snap / f"model{i}.safetensors").symlink_to(root / "blobs" / f"b{i}")

    link_repo("mlx-community/Soprano-1.1-80M-bf16", [store_file, shared_file])
    link_repo("someone/other-model", [shared_file])
    store = EngineStore(venv_dir=str(tmp_path / "venv"), hub_dir=hub)
    soprano = engines.get("soprano")
    assert store.is_installed(soprano)
    assert store.disk_mb(soprano) == pytest.approx(0.0051)

    store.remove("soprano")
    assert not store_file.exists()  # freed
    assert shared_file.exists()  # another repo still links to it
    assert not store.is_installed(soprano)


def test_previews_do_not_change_the_remembered_voice():
    client, _, app = make_client(config_overrides={"engine": "pocket"})
    _capture_synth(app)
    client.post("/v2/synthesize", json={"text": "Hello there.", "voice": "marius", "speed": 1.0})
    client.get("/v2/voices/preview/javert")
    assert app.state.cfg["engine_voices"]["pocket"] == "marius"
