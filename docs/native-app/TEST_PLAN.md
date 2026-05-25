# Myna v2 — Test Plan

**Purpose:** Each parallel worker is handed a test file with failing tests and told "make these green." Tests are the spec workers cannot violate. Coverage is broad on contracts (every endpoint, every input type) and deep on the risky bits (audio playback timing, hotkey collision, URL scheme validation, signing).

This doc lists every test file that must exist by end of overnight, with each test's purpose. Workers may add more tests but may not delete or relax any test in this plan.

---

## 1. Levels of testing

| Level | What | Where | Runs in |
|---|---|---|---|
| Unit | One function/class in isolation | XCTest / pytest | `swift test`, `pytest` |
| Contract | Shape of HTTP request/response | Both sides decode shared fixture | both suites |
| Integration | Two components together (DaemonClient ↔ real daemon, AudioPlayer ↔ real WAV file) | XCTest with launched daemon, pytest with FastAPI TestClient | CI |
| Acceptance | The actual user flow | Manual checklist run by L0 auditor | Audit gate |

**TDD rule:** All test files below are written **before** their implementation file. CI fails if any implementation file exists without a corresponding test file ≥ 50% the size of the impl.

---

## 2. Lane A test files (Swift, XCTest)

Path: `apps/macos/Tests/`

### `NetworkTests/DaemonClientTests.swift`

| Test | Assertion |
|---|---|
| `test_health_returns_health_when_daemon_up` | mock URLSession returns sample health JSON; client decodes |
| `test_health_throws_transport_when_connection_refused` | mock URLSession throws; client surfaces `DaemonError.transport` |
| `test_status_decodes_full_v2_status_fixture` | load `fixtures/status-response.json`, decode to `DaemonStatus`, assert engine.status == "up" |
| `test_voices_returns_empty_when_engine_down` | mock returns `{"voices": [], "engine": "down"}`; client returns `[]` |
| `test_synthesize_streams_chunks_in_order` | mock returns 3-part multipart; client yields 3 `SynthesizedChunk` with index 0,1,2 |
| `test_synthesize_handles_partial_chunk_boundary` | feed bytes split mid-boundary; parser reassembles correctly |
| `test_synthesize_propagates_502_engine_down` | mock returns 502 JSON; client throws `DaemonError.engineDown` |
| `test_synthesize_validates_empty_text_locally` | client rejects empty/whitespace text before network call |
| `test_extract_url_returns_text` | mock returns extract response; client decodes |
| `test_extract_failure_returns_extract_failed` | mock returns failure; client throws `.extractFailed` |
| `test_summarize_returns_summary` | mock returns summary; client decodes |
| `test_announce_post_serializes_correctly` | encode `AnnounceRequest`, assert JSON matches fixture |
| `test_registry_decodes_items` | mock returns 2-item registry; client decodes |
| `test_play_item_pops_registry` | client calls `/play/{id}?mode=full`; assert URL constructed correctly |
| `test_url_validation_rejects_non_http` | `file://` and `myna://` URLs rejected before network call |
| `test_timeout_default_30s` | assert URLSession timeout is 30s; long synthesize has separate longer timeout |

### `AudioTests/AudioPlayerTests.swift`

| Test | Assertion |
|---|---|
| `test_enqueue_single_buffer_plays_to_end` | enqueue 1-sec sine wave; wait; assert state == .idle, position == duration |
| `test_pause_resume_preserves_position` | enqueue 5-sec; play 1s; pause; assert position ≈ 1.0; resume; play to end |
| `test_stop_clears_queue` | enqueue 3 buffers; play; stop; assert queue empty, state idle |
| `test_speed_change_does_not_change_pitch` | set rate 2.0; assert AVAudioUnitTimePitch.rate == 2.0, pitch unchanged |
| `test_seek_within_chunk` | enqueue 5-sec; seek to 3s; assert position == 3.0 |
| `test_seek_across_chunks_forward` | enqueue 3×2s chunks; seek +5s from start; assert global position ≈ 5s, in chunk 2 |
| `test_seek_across_chunks_backward` | enqueue 3×2s; play to chunk 3; seek -5s; assert position in chunk 1 |
| `test_seek_clamps_at_zero` | seek -100s; position == 0, state == playing |
| `test_seek_clamps_at_total_duration` | seek +1000s; position == total, state == idle |
| `test_session_replacement_stops_prior` | play session A; start session B; assert A stopped, B playing |
| `test_buffer_callback_dequeues_next` | enqueue 2; assert second auto-plays after first |
| `test_speed_persists_across_chunks` | set 1.5×; play 3-chunk session; assert all play at 1.5× |
| `test_state_publisher_emits_changes` | subscribe; play; pause; stop; assert ordered emissions |
| `test_concurrent_play_is_thread_safe` | spawn 10 concurrent play() calls; assert no crash, last wins |

### `AudioTests/PlaybackQueueTests.swift`

| Test | Assertion |
|---|---|
| `test_global_position_sums_played_chunks` | mock chunks of durations [2,3,4]; play 2.5s into chunk 2; global == 4.5 |
| `test_chunk_containing_global_position_correct` | given chunks + global pos, returns (chunkIndex, offsetInChunk) |
| `test_total_duration_sums_all_chunks` | total == sum of chunk durations |

### `InputTests/SelectionServiceTests.swift`

| Test | Assertion |
|---|---|
| `test_capture_returns_pasteboard_string_after_cmd_c` | with injected pasteboard providing "hello", capture returns "hello" |
| `test_capture_restores_prior_clipboard` | clipboard pre-populated with "before"; capture; assert clipboard == "before" |
| `test_capture_returns_nil_when_no_selection` | pasteboard returns nil; capture returns nil |
| `test_capture_returns_nil_when_accessibility_denied` | mock CGEvent failure; capture returns nil (no crash) |

### `InputTests/ChromeServiceTests.swift`

| Test | Assertion |
|---|---|
| `test_chrome_url_returns_active_tab_url` | mock NSAppleScript returns URL; service returns it |
| `test_chrome_not_running_returns_nil` | mock returns error; service returns nil |
| `test_url_validation_https_passes` | "https://example.com" valid |
| `test_url_validation_file_scheme_rejected` | "file:///etc/passwd" rejected |

### `InputTests/HotkeyManagerTests.swift`

| Test | Assertion |
|---|---|
| `test_default_shortcuts_match_v1_for_compatibility` | the five defaults exactly match v1 keybindings.json |
| `test_handler_invoked_on_shortcut_press` | register handler; simulate KeyboardShortcuts trigger; handler called |
| `test_handler_unregistered_on_disable` | disable; trigger; handler NOT called |

### `URLSchemeTests/URLSchemeHandlerTests.swift`

| Test | Assertion |
|---|---|
| `test_speak_selection_routes_to_selection_service` | open `myna://speak-selection`; assert selection service invoked, mode .full |
| `test_speak_selection_summary_mode_parsed` | `myna://speak-selection?mode=summary`; mode == .summary |
| `test_toggle_pause_routes` | `myna://toggle-pause`; player.toggle() called |
| `test_seek_delta_parsed_positive` | `myna://seek?delta=%2B15`; seek(+15) called |
| `test_seek_delta_parsed_negative` | `myna://seek?delta=-15`; seek(-15) called |
| `test_speed_value_parsed` | `myna://speed?value=1.25`; setSpeed(1.25) called |
| `test_speed_delta_parsed` | `myna://speed?delta=%2B0.25`; bumpSpeed(+0.25) called |
| `test_speed_value_clamped_low` | `myna://speed?value=0.1`; setSpeed(0.5) (clamped) |
| `test_speed_value_clamped_high` | `myna://speed?value=10.0`; setSpeed(2.0) |
| `test_seek_delta_clamped` | `myna://seek?delta=99999`; seek(3600) |
| `test_unknown_action_logged_no_crash` | `myna://nonsense`; logs error, returns gracefully |
| `test_malformed_url_handled` | `myna://?%FF`; no crash |
| `test_no_arbitrary_text_speak` | `myna://speak?text=hello` — NOT a route; ignored. Only speaks from selection/clipboard. |

### `SettingsTests/SettingsViewModelTests.swift`

| Test | Assertion |
|---|---|
| `test_default_values_match_daemon_config` | first-run values mirror daemon's config defaults |
| `test_voice_persists_across_relaunch` | set; reinit; read; assert preserved |
| `test_reset_clears_all_user_defaults` | set bunch; reset; assert defaults |
| `test_daemon_url_validation_rejects_remote` | "http://example.com" rejected; only 127.0.0.1/localhost allowed |

### `MynaAppTests/AppLifecycleTests.swift`

| Test | Assertion |
|---|---|
| `test_app_launches_without_dock_icon` | Info.plist has `LSUIElement = true` |
| `test_url_scheme_registered_in_info_plist` | `myna` scheme in `CFBundleURLTypes` |
| `test_min_macos_version_13_or_higher` | Info.plist `LSMinimumSystemVersion` >= 13.0 |
| `test_entitlements_have_apple_events` | `Myna.entitlements` includes `com.apple.security.automation.apple-events` |
| `test_entitlements_have_hardened_runtime_compatible_flags` | jit/unsigned-mem/disable-lib-val all false |

---

## 3. Lane C test files (Python, pytest)

Path: `daemon/tests/`

### `test_v2_synthesize.py` (NEW)

| Test | Assertion |
|---|---|
| `test_v2_synthesize_streams_one_part_per_chunk` | small text, monkeypatched chunker yields 3 chunks; response has 3 audio parts + final JSON |
| `test_v2_synthesize_part_headers_include_index_and_text` | each part has `X-Chunk-Index`, `X-Chunk-Total-Estimate`, `X-Chunk-Text` |
| `test_v2_synthesize_returns_wav_bytes` | each part's body matches fake synthesizer's `b"RIFFfake"` |
| `test_v2_synthesize_rejects_empty` | `{"text": ""}` → 400, `reason: empty` |
| `test_v2_synthesize_rejects_both_text_and_url` | both set → 400, `reason: both_text_and_url` |
| `test_v2_synthesize_rejects_neither` | neither → 400, `reason: neither_text_nor_url` |
| `test_v2_synthesize_engine_down_returns_502` | engine_up returns False → 502, `reason: engine_down` |
| `test_v2_synthesize_engine_error_returns_502` | synthesize throws → 502, `reason: engine_error` |
| `test_v2_synthesize_url_extracts_first` | url set; extract called; extracted text fed to chunker |
| `test_v2_synthesize_summary_mode_summarizes_first` | mode=summary; summarize called before chunk/synthesize |
| `test_v2_synthesize_respects_voice_override` | voice in request overrides config |
| `test_v2_synthesize_respects_speed_in_synthesize_call` | speed=1.5 passed to engine.synthesize |
| `test_v2_synthesize_does_not_touch_player` | app.state.player should not be called |

### `test_v2_status.py` (NEW)

| Test | Assertion |
|---|---|
| `test_v2_status_shape_matches_fixture` | response matches `fixtures/status-response.json` keys exactly |
| `test_v2_status_engine_up_reflects_engine_check` | engine_up=True → status.engine.status == "up" |
| `test_v2_status_engine_down_when_check_throws` | engine_up raises → status.engine.status == "down" |
| `test_v2_status_includes_uptime` | uptime_s monotonically increases |
| `test_v2_status_includes_daemon_version` | matches `myna.__version__` |
| `test_v2_status_includes_registry_items` | announce 2; status.registry.count == 2 |
| `test_v2_status_v1_player_state_diagnostic_only` | field present but Swift app should ignore |

### `test_v2_voices.py` (NEW)

| Test | Assertion |
|---|---|
| `test_v2_voices_queries_engine_on_first_call` | spies on httpx.get; first call hits Kokoro |
| `test_v2_voices_cached_for_5_minutes` | second call within TTL doesn't hit engine |
| `test_v2_voices_cache_expires` | mock clock past TTL; engine re-queried |
| `test_v2_voices_engine_down_returns_empty` | engine_up=False → `{"voices": [], "engine": "down"}` |
| `test_v2_voices_includes_default_voice_marker` | one voice has `default: true` matching config.voice |

### `test_v2_extract.py` (NEW)

| Test | Assertion |
|---|---|
| `test_v2_extract_returns_text` | extract returns "EXTRACTED"; response.ok && response.text == "EXTRACTED" |
| `test_v2_extract_failure_returns_not_ok` | extract returns None; response.ok == False |
| `test_v2_extract_url_validation_rejects_non_http` | "file://..." rejected with 400 |

### `test_v2_summarize.py` (NEW)

| Test | Assertion |
|---|---|
| `test_v2_summarize_returns_summary` | summarize returns "SHORT"; response.summary == "SHORT" |
| `test_v2_summarize_rejects_empty` | empty text rejected with 400 |
| `test_v2_summarize_passes_model_and_url_from_config` | summarize called with cfg.summary_model, cfg.ollama_url |

### `test_v2_health.py` (NEW)

| Test | Assertion |
|---|---|
| `test_v2_health_returns_ok` | response.ok == True |
| `test_v2_health_includes_version` | response.version matches package |
| `test_v2_health_engine_up_field` | engine_up reflected |
| `test_v2_health_fast_when_engine_cached` | doesn't hit engine if recent check < 1s ago |

### Existing tests — must still pass

All v1 tests in `daemon/tests/test_app.py`, `test_player.py`, etc. must remain green. Lane C may add but not remove or skip.

---

## 4. Lane B test files (CI workflow + scripts)

Path: `.github/workflows/` and `dist/`

### `.github/workflows/ci.yml`

Must:
- Run on every PR
- Job `swift-build` — XcodeGen, `xcodebuild -scheme Myna build`
- Job `swift-test` — `xcodebuild test -scheme Myna -destination 'platform=macOS'`
- Job `swift-lint` — `swiftlint --strict` + `swift-format lint --recursive --strict`
- Job `daemon-test` — `pip install -e daemon && pytest daemon/tests`
- All jobs green required before merge

### `.github/workflows/release.yml`

Must:
- Trigger on tag push `v*`
- Job `build-and-sign` — needs secrets (stubbed): imports cert, builds, signs, notarizes, staples
- Job `dmg` — builds DMG with `dist/dmg.sh`
- Job `release` — creates GH release, attaches DMG
- Job `appcast` — updates `appcast.xml` and pushes to `releases/download/appcast/`
- Job `tap-bump` — updates `tap/Casks/myna.rb` with new version + sha256

### `dist/` shell scripts

Each script must:
- Be executable, `set -euo pipefail`
- Have `--help`
- Be runnable locally (with env vars stubbed)
- Have a smoke-test in `dist/tests/` that runs with `--dry-run`

Files: `build.sh`, `sign.sh`, `notarize.sh`, `dmg.sh`, `appcast.sh`.

### Smoke tests `dist/tests/test_scripts.sh`

```bash
./dist/build.sh --dry-run && \
./dist/sign.sh --dry-run && \
./dist/notarize.sh --dry-run && \
./dist/dmg.sh --dry-run && \
./dist/appcast.sh --dry-run
```

All must exit 0 without real credentials.

---

## 5. Manual acceptance checklist (L0 auditor)

Auditor performs these steps on a real Mac (this machine) with real Kokoro running:

1. **Build:** `cd apps/macos && xcodegen && xcodebuild -scheme Myna build` → succeeds
2. **Run:** Open `.build/.../Myna.app` → menu bar bird appears, no Dock icon
3. **Daemon down:** daemon stopped → menu shows "Daemon: down"; speak hotkey shows alert
4. **Daemon up:** `launchctl load …myna.daemon.plist` → menu shows "Daemon: up", engine status visible
5. **Speak selection:** select text in any app; press default hotkey; audio plays
6. **Pause/resume:** press pause hotkey mid-speech; audio pauses; press again; resumes
7. **Speed up:** menu → Speed → 1.5×; audio audibly faster, voice not chipmunk-pitched
8. **Seek forward:** menu → Seek +15s; audio jumps ahead
9. **Seek backward:** menu → Seek -15s; audio jumps back
10. **Chrome article:** open an article in Chrome; press read-chrome hotkey; daemon extracts, audio plays
11. **Hotkey rebind:** menu → Customize Shortcuts → record new chord → assert new chord works
12. **URL scheme:** `open "myna://toggle-pause"` from Terminal → pauses
13. **URL scheme seek:** `open "myna://seek?delta=+15"` → seeks
14. **Settings → Voice:** voice picker populates; switching voice changes next speak
15. **Settings → Daemon:** restart daemon button works
16. **Logs:** menu → Open Logs → log file opens; lines appear during speak
17. **Quit:** menu → Quit; app exits cleanly; daemon and Kokoro keep running
18. **Relaunch:** open app again; settings preserved
19. **Accessibility prompt:** new install / TCC reset → first hotkey shows prompt
20. **Coexistence:** with v1 Hammerspoon also running, both work (last-registered hotkey wins)

Each item gets a ✅/❌/⚠️ in `AUDIT_REPORT.md` with notes.

---

## 6. CI gate summary

A lane cannot merge to `native-app-rebuild` until:

| Gate | Tool | Threshold |
|---|---|---|
| All XCTest unit + integration | `xcodebuild test` | 100% pass |
| All pytest | `pytest daemon/tests` | 100% pass (≥ 33 existing + new v2 tests) |
| SwiftLint | `swiftlint --strict` | 0 warnings |
| swift-format | `swift-format lint --strict` | 0 warnings |
| Smoke scripts | `dist/tests/test_scripts.sh` | exit 0 |
| Manual checklist | L0 auditor | items 1–11 must be ✅ for v0.1; 12–20 may be ⚠️ with notes |

---

## 7. Out of scope (for overnight)

- UI screenshot tests — too flaky overnight
- Performance benchmarks — establish baseline post-launch
- Localization — English only for v0.1
- Accessibility (a11y) audit — VoiceOver pass scheduled for v0.2
- Real Apple notarization run — needs secrets; CI workflow exists, real run is morning-after

These get tasks created in STATUS.md for follow-up.
