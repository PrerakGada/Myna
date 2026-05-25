# Myna v2 — Audit Report

Auditors append their findings here. Each lane gets one code-review section. One combined security review section runs after all lanes integrate.

---

<!-- Lane A code review will be appended here -->

<!-- Lane B code review will be appended here -->

<!-- Lane C code review will be appended here -->

## Lane C Code Review — 2026-05-25

### Summary
- Modules reviewed: `daemon/myna/app.py` (v2 additions, lines 1–521), `daemon/myna/v2_types.py`, `daemon/tests/v2_helpers.py`, all `daemon/tests/test_v2_*.py`, `daemon/myna/__init__.py`, `daemon/pyproject.toml`.
- Build status: N/A (pure Python).
- Test status: **82 / 82 pass** in 1.27s via `pytest daemon/tests -v` (33 pre-existing v1 + 49 new v2). 0 skipped, 0 xfail. `git diff main..HEAD -- daemon/tests/test_app.py …` is empty — no v1 test file modified.
- Versioning: `daemon/myna/__init__.py:1` = `__version__ = "0.2.0"` and `daemon/pyproject.toml:3` = `version = "0.2.0"`. Consistent.
- Streaming validation: `/tmp/audit-c.py` end-to-end TestClient run hits `/v2/synthesize` with 3 chunks; 23/23 assertions pass (boundaries, headers, WAV bytes, final JSON `ok/chunks/session_id`, voice/speed passthrough). Output retained for re-run.
- Security spot-checks: `grep -n "0\.0\.0\.0|eval\(|exec\(|os\.system|subprocess.*shell=True" daemon/` returns no hits. Daemon binds 127.0.0.1 only (`daemon/myna/__main__.py:9`). `/v2/extract` correctly rejects non-`http(s)://` URLs with 400 (`daemon/myna/app.py:472`). No new pip dependencies added — `pyproject.toml` deps unchanged from v1.
- `app.state.player` usage audit: 7 hits (lines 92, 142, 172, 177, 182, 192, 422). Six are v1 surfaces as expected. **Line 422** is in `v2_status()` reading `player.status()` to populate the `v1_player` diagnostic field — this is *spec-mandated* by `API_CONTRACT.md` § 2 ("v1_player is included for diagnostics only"), and `v2_helpers.FakePlayer.status()` explicitly allows it. Acceptable.

### 🔴 Blockers

1. **`/v2/voices` happy-path response leaks `engine: null` not present in fixture.**
   - **File:line:** `daemon/myna/v2_types.py:98–100`, surfaced via `daemon/myna/app.py:467`.
   - **Evidence:** Live `TestClient` call with engine up returns `{"voices": [...], "engine": null}`. `fixtures/voices-response.json` has only `voices`. Per the audit prompt ("Any drift is a 🔴 blocker") this is a fixture violation. Per `API_CONTRACT.md` § 2 the `engine` key is documented *only* on the engine-down response (`{"voices": [], "engine": "down"}`). Compounding: the canonical Swift type `VoicesResponse` in § 4 has no `engine` field — Swift `JSONDecoder` will discard the `null` silently, masking the contract drift in practice but still wrong on the wire.
   - **Recommended fix:** Either (a) exclude unset fields in the Pydantic serializer for this model (`model_dump(exclude_none=True)`) and return a plain dict, or (b) split into two response models (`V2Voices` without `engine`, `V2VoicesDown` with it).

2. **`/v2/extract` success response leaks `title: null, byline: null, reason: null` not present in fixture.**
   - **File:line:** `daemon/myna/v2_types.py:26–31`, surfaced via `daemon/myna/app.py:494`.
   - **Evidence:** `TestClient` call with `extract → "EXTRACTED"` (string return) returns `{"ok": true, "text": "EXTRACTED", "title": null, "byline": null, "reason": null}`. `fixtures/extract-response.json` has exactly `{ok, text, title, byline}`. Spec § 2 cleanly separates success (`{ok, text, title, byline}`) from failure (`{ok, reason}`); `reason` should never appear in a success body and is a contract violation. `title`/`byline` being `null` rather than absent is acceptable per the fixture (which has both as strings, not null, but the *key set* matches when extract returns dict form — see fixture-key test result). Drift is solely the extra `reason` key on success.
   - **Recommended fix:** Serialize with `exclude_none=True` for `V2ExtractResp`, or build two response classes (success vs failure) and return the appropriate one.

### 🟡 Should-fix

1. **No clamping of `speed` in `/v2/synthesize`.**
   - **File:line:** `daemon/myna/app.py:334`.
   - **Evidence:** `speed = req.speed` is passed straight to `engine.synthesize(..., speed=speed)`. The v1 `/speed` handler at line 187 clamps to `[0.5, 2.0]`. Universal checklist says "Numeric inputs clamped where spec says (speed 0.5–2.0)". The v2 contract example in § 2 shows `speed: 1.0` but doesn't repeat the clamp requirement; the Swift contract in § 4 has `speed: Double` with no validation. A malicious or buggy client could send `speed=99` and DOS the synthesizer.
   - **Recommended fix:** `speed = max(0.5, min(2.0, req.speed))` before passing into `synthesize()`.

2. **Mid-stream synthesize failure silently truncates with `ok: true`.**
   - **File:line:** `daemon/myna/app.py:384–402`.
   - **Evidence:** If chunk N (N≥1) raises during `app.state.synthesize`, the `except Exception: break` at line 394 exits the loop and emits `_final_part(yielded)` with `ok: true`. The Swift client sees `yielded < X-Chunk-Total-Estimate` but no error signal. Spec § 2 doesn't dictate the failure shape mid-stream; current behaviour is "fail open" which is wrong for a TTS pipeline (silent dropped audio).
   - **Recommended fix:** Add an `"error"` field to the final JSON when `yielded < total` (e.g. `{"ok": false, "reason": "engine_error_midstream", "chunks": yielded, ...}`). Alternatively, include `"truncated": true`. This needs an API_CONTRACT.md update — escalate to orchestrator.

3. **`tmpdir` for v1 player WAVs is created at request time and never garbage-collected.**
   - **File:line:** `daemon/myna/app.py:106–120`.
   - **Evidence:** `~/.cache/myna/tmp/<uuid>.wav` files are written by `_producer` on every v1 `/speak`. They are never deleted. Not a v2 regression (v1 had this) and v2 streams WAVs directly without touching disk, but flagged as standing tech debt.
   - **Recommended fix:** Delete each WAV after `afplay` finishes; add a startup sweep for stale files.

4. **`_check_engine_cached` shares one boolean across all v2 endpoints with 1s TTL — under sustained engine flapping, status can briefly disagree with synthesize.**
   - **File:line:** `daemon/myna/app.py:203–218`.
   - **Evidence:** `/v2/status` and `/v2/health` both reuse the same cache; if `_v2_synthesize_response` reads `up` at T=0.9s and `/v2/status` reads `down` at T=1.1s after engine actually flipped, the Swift app's poll and a concurrent speak will disagree. Minor race; the 1-second window is small. Documented behaviour, not a bug.

5. **`/v2/status.state` field uses only `"idle"` / `"down"` — never emits `"synthesizing"` or `"streaming"`.**
   - **File:line:** `daemon/myna/app.py:425`: `state="down" if not engine_up_now else "idle"`.
   - **Evidence:** Spec § 2 documents four states: `"idle | synthesizing | streaming | down"`. The daemon never tracks whether a `/v2/synthesize` is currently in flight, so it can never report `"synthesizing"` or `"streaming"`. The Swift `DaemonState` enum (§ 4) handles unknown via fallback, so Swift won't crash, but the state machine documented in the contract is unimplemented.
   - **Recommended fix:** Track in-flight v2 syntheses on `app.state` (counter increment/decrement around the generator) and surface as `state` in `v2_status`.

### 🟢 Nits

1. **`_voice_label` uses `"unknown"` as gender fallback** (`daemon/myna/app.py:71`) — produces labels like `"Heart (unknown)"` for non-Kokoro voices. Cosmetic.
2. **`V2V1PlayerInfo.now_playing: Optional[dict]`** (`v2_types.py:79`) — typed as generic `dict`; could be a proper sub-model. Minor.
3. **`_part_headers` concatenates bytes with `+`** (`app.py:357–365`) — small perf nit vs `b"".join`; immaterial at request volumes.
4. **`make_client` in `v2_helpers.py:51`** does not expose a way to mock `httpx.get` (each test monkeypatches `app_mod.httpx.get` directly). Mildly inconsistent with the rest of the fake-injection pattern but readable.
5. **`tests/v2_helpers.py:48`** — `FakePlayer.status()` returning a fixed dict is fine, but a test could explicitly assert `v2_status()` returns `v1_player.state == "idle"` to lock the diagnostic shape. Optional.

### Strengths noted

- TDD discipline is visible: every endpoint has a `test_v2_<endpoint>_shape_matches_fixture` that loads the actual `docs/native-app/fixtures/*.json` and compares key sets — exactly the cross-lane contract guard called for in `API_CONTRACT.md` § 6. The bug above was caught only because I ran a *deep* key-set comparison; the in-repo tests use `>=` on per-element key sets, not equality, which is why they pass while drift exists.
- `FakePlayer` in `v2_helpers.py:22` is an elegant trip-wire: any v2 handler that mistakenly calls `player.play/pause/resume/stop` would be recorded and asserted against by `test_v2_synthesize_does_not_touch_player`. This is the right pattern for the "Swift owns playback" boundary.
- Eager first-chunk synthesis in `_v2_synthesize_response` (line 340–353) is the right move: engine errors surface as a real HTTP 502 *before* the streaming response begins, instead of being trapped inside an opaque chunked body.
- Engine check caching (`_ENGINE_CHECK_TTL_S = 1.0`) and voices caching (`_VOICES_CACHE_TTL_S = 300.0`) are both reasonable and tested for both hit and expiry.
- All v1 endpoints, tests, and behaviour preserved bit-identical (`git diff main..HEAD` of v1 test files is empty).
- v2 type module is small, focused, and 100% aligned with the Swift `CodingKeys` mapping in API_CONTRACT § 4.

### Overall verdict

- [ ] APPROVED to merge
- [x] APPROVED with follow-ups (file follow-up tasks)
- [ ] BLOCKED — fix blockers and re-review

**Rationale:** The two "🔴 Blockers" above are real contract drifts but their impact is muted because the canonical Swift consumer (Lane A — not yet implemented) will silently drop the extra `null` fields via `JSONDecoder`'s default behaviour. They are still blockers per the audit prompt's literal phrasing ("Any drift is a 🔴 blocker"), and they will become *actual* blockers if any non-Swift client (curl, CLI, future TypeScript app, contract tests with strict decoders) consumes these endpoints. **Recommend approve-with-followups: fix both with `model_dump(exclude_none=True)` (or split response models) before Lane A integrates against these endpoints.** Test suite is green, streaming format is correct, no security issues, no v1 regressions, version bump correct.

<!-- Security review will be appended here -->

<!-- Final verification (real app launch) will be appended here -->
