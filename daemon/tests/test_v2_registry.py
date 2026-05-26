"""Tests for /v2/registry/* — Claude Code Stop-hook toast registry.

Spec: docs/v0.2-plan/01-feature-stories.md S08.
"""

import json
import threading
import time

import pytest

from myna.v2_registry import V2Registry

from .v2_helpers import make_client


# ---------- pure registry unit tests ----------

def test_registry_round_trip_persistence(tmp_path):
    path = tmp_path / "registry.json"
    r = V2Registry(path=path)
    r.announce(
        id="u_1",
        source="claude-code",
        project_id="myna",
        title="Hello world",
        ttl_s=600,
    )
    # File written
    assert path.exists()
    data = json.loads(path.read_text())
    assert len(data) == 1
    assert data[0]["id"] == "u_1"

    # New instance reads the saved entry
    r2 = V2Registry(path=path)
    snap = r2.snapshot()
    assert len(snap["pending"]) == 1
    assert snap["pending"][0]["id"] == "u_1"


def test_registry_corrupt_file_resets(tmp_path):
    path = tmp_path / "registry.json"
    path.write_text("not json at all")
    r = V2Registry(path=path)
    assert r.snapshot() == {"pending": [], "played": []}


def test_registry_non_list_resets(tmp_path):
    path = tmp_path / "registry.json"
    path.write_text(json.dumps({"oops": "wrong shape"}))
    r = V2Registry(path=path)
    assert r.snapshot() == {"pending": [], "played": []}


def test_registry_ttl_filters_pending(tmp_path):
    fake_now = {"t": 1_000_000}

    def clock():
        return fake_now["t"]

    r = V2Registry(path=tmp_path / "r.json", clock=clock)
    r.announce(id="u_short", source="cc", project_id="p", title="t", ttl_s=1)
    r.announce(id="u_long", source="cc", project_id="p", title="t", ttl_s=600)
    # Inside TTL: both pending
    assert {e["id"] for e in r.snapshot()["pending"]} == {"u_short", "u_long"}
    # Advance past short TTL
    fake_now["t"] += 2_000  # +2s in ms
    pending = r.snapshot()["pending"]
    assert {e["id"] for e in pending} == {"u_long"}


def test_registry_announce_same_id_replaces(tmp_path):
    r = V2Registry(path=tmp_path / "r.json")
    r.announce(id="dup", source="cc", project_id="p", title="first", ttl_s=600)
    r.announce(id="dup", source="cc", project_id="p", title="second", ttl_s=600)
    snap = r.snapshot()
    assert len(snap["pending"]) == 1
    assert snap["pending"][0]["title"] == "second"


def test_registry_played_cap(tmp_path):
    fake_now = {"t": 1_000_000}
    r = V2Registry(path=tmp_path / "r.json", clock=lambda: fake_now["t"], played_cap=5)
    for i in range(8):
        r.announce(id=f"u_{i}", source="cc", project_id="p", title=f"t{i}", ttl_s=600)
        fake_now["t"] += 10
        r.mark_played(f"u_{i}")
        fake_now["t"] += 10
    played = r.snapshot()["played"]
    assert len(played) == 5
    # Most recent first
    assert [e["id"] for e in played] == ["u_7", "u_6", "u_5", "u_4", "u_3"]


def test_registry_dismiss_excludes_from_pending(tmp_path):
    r = V2Registry(path=tmp_path / "r.json")
    r.announce(id="a", source="cc", project_id="p", title="t", ttl_s=600)
    r.mark_dismissed("a")
    assert r.snapshot()["pending"] == []


def test_registry_play_excludes_from_pending(tmp_path):
    r = V2Registry(path=tmp_path / "r.json")
    r.announce(id="a", source="cc", project_id="p", title="t", ttl_s=600)
    r.mark_played("a")
    snap = r.snapshot()
    assert snap["pending"] == []
    assert len(snap["played"]) == 1


def test_registry_delete(tmp_path):
    r = V2Registry(path=tmp_path / "r.json")
    r.announce(id="a", source="cc", project_id="p", title="t", ttl_s=600)
    assert r.delete("a") is True
    assert r.snapshot()["pending"] == []
    assert r.delete("a") is False  # second delete no-ops


# ---------- HTTP route tests ----------

def test_announce_route_persists(tmp_path):
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    r = client.post(
        "/v2/registry/announce",
        json={
            "id": "u_abc",
            "source": "claude-code",
            "project_id": "myna",
            "title": "First 80 chars of agent reply.",
            "ttl_s": 600,
        },
    )
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert body["announced_at_ms"] > 0


def test_list_route_partitions_pending_and_played(tmp_path):
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    client.post(
        "/v2/registry/announce",
        json={
            "id": "u_a",
            "source": "claude-code",
            "project_id": "p",
            "title": "Pending",
            "ttl_s": 600,
        },
    )
    client.post(
        "/v2/registry/announce",
        json={
            "id": "u_b",
            "source": "claude-code",
            "project_id": "p",
            "title": "Will be played",
            "ttl_s": 600,
        },
    )
    client.post("/v2/registry/play/u_b")
    body = client.get("/v2/registry/list").json()
    assert {e["id"] for e in body["pending"]} == {"u_a"}
    assert {e["id"] for e in body["played"]} == {"u_b"}


def test_play_route_404_for_unknown(tmp_path):
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    r = client.post("/v2/registry/play/nope")
    assert r.status_code == 404


def test_dismiss_route_404_for_unknown(tmp_path):
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    r = client.post("/v2/registry/dismiss/nope")
    assert r.status_code == 404


def test_dismiss_does_not_touch_caller_supplied_paths(tmp_path):
    """Security: an attacker posting an `audio_path` along with announce must
    not be able to coerce dismiss into deleting that file.

    The field was removed entirely (Pydantic by default ignores extra
    keys, so the announce still succeeds), and dismiss no longer touches
    the filesystem.
    """
    sentinel = tmp_path / "must_not_be_deleted.txt"
    sentinel.write_text("hello")
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    r = client.post(
        "/v2/registry/announce",
        json={
            "id": "u_audio",
            "source": "claude-code",
            "project_id": "p",
            "title": "t",
            "ttl_s": 600,
            # Sneaky extra field — must be silently ignored, never stored.
            "audio_path": str(sentinel),
        },
    )
    assert r.status_code == 200
    # And the registry entry must not have persisted audio_path either.
    entry = app.state.v2_registry.get("u_audio")
    assert entry is not None
    assert "audio_path" not in entry
    # Dismiss does NOT touch the file even though the announce body
    # included a path pointing at it.
    d = client.post("/v2/registry/dismiss/u_audio")
    assert d.status_code == 200
    assert sentinel.exists(), "dismiss must not delete caller-supplied paths"


def test_delete_route(tmp_path):
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    client.post(
        "/v2/registry/announce",
        json={
            "id": "u_x",
            "source": "claude-code",
            "project_id": "p",
            "title": "t",
            "ttl_s": 600,
        },
    )
    r = client.delete("/v2/registry/u_x")
    assert r.status_code == 200
    assert client.get("/v2/registry/list").json()["pending"] == []
    # Second delete -> 404
    r2 = client.delete("/v2/registry/u_x")
    assert r2.status_code == 404


def test_concurrent_announce_preserves_all_entries_and_valid_json(tmp_path):
    """Concurrency: N threads each call announce() with a distinct id.
    All N entries must be present in the in-memory snapshot AND the
    on-disk JSON must be parseable (not corrupt). Pre-fix, the disk file
    could be a half-written {.tmp → replace} race; the in-memory list
    could also lose entries when two threads' read-modify-writes
    interleaved.
    """
    path = tmp_path / "concurrent.json"
    r = V2Registry(path=path)
    N = 50
    barrier = threading.Barrier(N)
    errors: list[BaseException] = []

    def worker(i):
        try:
            barrier.wait()
            r.announce(
                id=f"u_{i:03d}",
                source="cc",
                project_id="p",
                title=f"entry {i}",
                ttl_s=600,
            )
        except BaseException as exc:
            errors.append(exc)

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(N)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == [], f"workers raised: {errors}"

    # All entries present in-memory
    snap = r.snapshot()
    assert len(snap["pending"]) == N, (
        f"expected {N} pending, got {len(snap['pending'])}"
    )
    assert {e["id"] for e in snap["pending"]} == {f"u_{i:03d}" for i in range(N)}

    # On-disk JSON parses cleanly and matches
    on_disk = json.loads(path.read_text())
    assert isinstance(on_disk, list)
    assert len(on_disk) == N
    assert {e["id"] for e in on_disk} == {f"u_{i:03d}" for i in range(N)}


def test_play_route_triggers_synthesis_from_title(tmp_path):
    """S08 flow: clicking Play on the CC toast must synthesise the
    registered title (CC-hook entries carry no audio file).
    """
    seen_texts: list[str] = []

    def fake_synth(text, **kw):
        seen_texts.append(text)
        return b"RIFFfake"

    client, fp, app = make_client(
        registry_path=tmp_path / "r.json",
        synthesize=fake_synth,
    )
    # Announce a known title.
    client.post(
        "/v2/registry/announce",
        json={
            "id": "u_play",
            "source": "claude-code",
            "project_id": "myna",
            "title": "Hello from the agent, here is your toast reply.",
            "ttl_s": 600,
        },
    )
    # Play it.
    r = client.post("/v2/registry/play/u_play")
    assert r.status_code == 200
    assert r.json()["ok"] is True
    # The v1 player received the queued producer for actual playback.
    play_calls = [c for c in fp.calls if c[0] == "play"]
    assert play_calls, "player.play() must be invoked for the CC Play action"
    _, args, kwargs = play_calls[0]
    # The producer is a lazy generator. Drain it to confirm synthesis
    # happens with the registered title — this is what the real Player
    # thread would do.
    producer = args[0] if args else kwargs.get("producer")
    assert producer is not None
    list(producer)  # drain → triggers synthesize() calls
    assert seen_texts, "synthesize was not invoked when player drained the producer"
    assert "Hello from the agent" in seen_texts[0]
    # The meta carries a cc: source so /status can tell where it came from.
    meta = kwargs.get("meta") or {}
    assert meta.get("source", "").startswith("cc:"), (
        f"expected cc: source on play meta, got {meta!r}"
    )


def test_play_route_marks_played_even_if_title_empty(tmp_path):
    """If somehow an entry has an empty title, mark_played still runs but
    no synthesis is queued. Defensive — guards against future callers
    that announce with title='' (Pydantic would accept that today).
    """
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    # Reach past the HTTP layer to plant an empty-title entry.
    app.state.v2_registry.announce(
        id="u_blank",
        source="cc",
        project_id="p",
        title="",
        ttl_s=600,
    )
    r = client.post("/v2/registry/play/u_blank")
    assert r.status_code == 200
    assert r.json()["ok"] is True
    # No player.play() because there's nothing to synthesise.
    assert [c for c in fp.calls if c[0] == "play"] == []
    # But the entry IS marked played.
    snap = app.state.v2_registry.snapshot()
    assert any(e["id"] == "u_blank" for e in snap["played"])


def test_default_ttl_is_600(tmp_path):
    client, fp, app = make_client(registry_path=tmp_path / "r.json")
    r = client.post(
        "/v2/registry/announce",
        json={
            "id": "u_def",
            "project_id": "p",
            "title": "t",
        },
    )
    assert r.status_code == 200
    entry = app.state.v2_registry.get("u_def")
    assert entry is not None
    assert entry["ttl_s"] == 600
    assert entry["source"] == "claude-code"
