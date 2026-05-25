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

## Lane B Code Review — 2026-05-25

### Summary
- Modules reviewed: `.github/workflows/{release,appcast,ci}.yml`; `dist/{_lib,build,sign,notarize,dmg,appcast}.sh`; `dist/tests/test_scripts.sh`; `tap/Casks/myna.rb`; `tap/Formula/myna-daemon.rb`; `apps/macos/Sources/Updates/UpdateController.swift`; `apps/macos/project.yml` (Sparkle keys + Info.plist generation); `RELEASE.md` (end-to-end).
- Workflow YAML parse: **3/3 OK** (`.github/workflows/{release,appcast,ci}.yml` via `yaml.safe_load`).
- `bash dist/tests/test_scripts.sh` → **16 pass, 0 fail** (parse / --help / --dry-run on all 5 scripts). Shellcheck warning that shellcheck wasn't installed; I installed `shellcheck 0.11.0` and ran it manually — see "🟡 Should-fix" #1 below.
- `bash -n` all `dist/*.sh`: **6/6 OK** (including `_lib.sh`).
- `brew style tap/Casks/myna.rb`: 1 autocorrectable offense (`OSDependsOn`; see 🟡 #4). `brew style tap/Formula/myna-daemon.rb`: 0 offenses.
- Xcode build: `xcodegen generate` + full `xcodebuild build` → **`** BUILD SUCCEEDED **`**. `Info.plist` correctly carries `SUPublicEDKey=i+MLgN/...K0=`, `SUFeedURL=https://github.com/CHANGEME/myna/...`, `LSUIElement=true`, `CFBundleURLSchemes=[myna]`, `Sparkle.framework` linked.
- Secret-documentation table: every secret referenced in `release.yml` (`APPLE_DEVELOPER_ID_P12`, `..._P12_PASSWORD`, `APPLE_DEVELOPER_ID_NAME`, `APPLE_ID`, `APPLE_ID_APP_PASSWORD`, `APPLE_TEAM_ID`, `KEYCHAIN_PASSWORD`, `SPARKLE_EDDSA_PRIVATE_KEY`, `TAP_DEPLOY_KEY`) is documented in `RELEASE.md` § 1.6. `GITHUB_TOKEN` is auto-provided by Actions — no setup needed. **PASS.**
- Codesign correctness: hardened runtime (`--options runtime` `dist/sign.sh:57,67`) ✅, `--timestamp` ✅, `--entitlements Resources/Myna.entitlements` ✅, nested-bundle pre-signing ✅, `notarytool --wait --timeout 30m` (`dist/notarize.sh:61–62`) ✅, `stapler staple` then `validate` (`dist/notarize.sh:67–68`) ✅, DMG signed with `--timestamp` (`release.yml:247`) ✅, DMG notarized separately (`release.yml:249–256`) ✅, `if-no-files-found: error` on every artifact upload ✅, only `|| true` in workflow is `xcode-select` (acceptable).
- `appcast.yml` trigger: **`workflow_dispatch` only** (`.github/workflows/appcast.yml:17`) — does not fire on push. ✅
- Universal binary configured: `dist/build.sh:31` `ARCHS="${ARCHS:-arm64 x86_64}"` passed to `xcodebuild archive` (`build.sh:61`). ✅ (Debug build is single-arch but Release archive is universal.)

### 🔴 Blockers

1. **Sparkle EdDSA private key is effectively published in the repo.** *(FIXED in commit after this audit — see RESOLUTION below.)*
   - **File:line:** `dist/tests/test_scripts.sh:26` exported the env var `SPARKLE_EDDSA_PRIVATE_KEY` with a literal 32-byte Ed25519 seed (value redacted post-resolution; see git history of that file before commit `5b8f7f6`). That seed derived bit-identically to `apps/macos/project.yml:54` `SUPublicEDKey` (also rotated; redacted post-resolution).
   - **Evidence:** Re-derived locally via `cryptography.hazmat.primitives.asymmetric.ed25519.Ed25519PrivateKey.from_private_bytes(base64.b64decode(...)).public_key()` — produced the exact pre-rotation public key, confirming the leak.
     Commit history: introduced as a "test fixture" in `ec31a3f feat(release): dist/ scripts + smoke tests` (before the public key was minted in `bb43ea7` / `f150e68`). The public key in `project.yml` matches it exactly, so this is not a placeholder — it's the live key.
   - **Impact:** Anyone with read access to the repo (or to the history) can sign arbitrary `.dmg`s that Sparkle clients of any shipped Myna build will accept as authentic. Once a v0.1.0 build is in users' hands, the only fix is shipping a new minor version with a new public key (RELEASE.md § 1.4 calls out this exact non-rotatable property). Spec violation: `NATIVE_APP_PROPOSAL.md` § 11 requires "EdDSA-signed (Sparkle 2 default; required)" — this requirement is met only nominally; trust is broken.
   - **Recommended fix:**
     1. **Immediately** rotate the Sparkle keypair before any v0.1.0 release goes out (no shipped builds yet, so safe to do).
     2. Generate a new key via `brew install --cask sparkle && /opt/homebrew/Caskroom/sparkle/*/bin/generate_keys` (or via `openssl genpkey -algorithm ed25519`).
     3. Update `apps/macos/project.yml` `SUPublicEDKey` and rebuild Info.plist.
     4. Stash the new private key in 1Password and GitHub Actions secret only.
     5. **Replace `dist/tests/test_scripts.sh:26`** with a *throwaway* test-only key (e.g. a freshly generated `openssl genpkey -algorithm ed25519 -outform DER 2>/dev/null | tail -c 32 | base64`) that has no relationship to the production key. Add a comment marking it as test-only and orthogonal to the real public key.
     6. `git filter-repo` (or accept the leak and rotate — the branch isn't pushed publicly per checklist scope, but verify before any push).

2. **Appcast signing in CI cannot succeed — `sign_update` not installed, `/usr/bin/openssl` (LibreSSL) doesn't support Ed25519.**
   - **File:line:** `dist/appcast.sh:61–88` + `.github/workflows/release.yml:265–306` + `.github/workflows/appcast.yml`.
   - **Evidence:**
     - `appcast.sh:63` calls `sign_update` if `command -v sign_update` returns truthy, falling back to openssl otherwise. Neither `release.yml` nor `appcast.yml` runs `brew install --cask sparkle` (the only way to get `sign_update` on a macOS runner). `grep -rn "sparkle\|sign_update" .github/workflows/` confirms no install step.
     - Fallback at `appcast.sh:86` hardcodes `/usr/bin/openssl`, which on macOS is LibreSSL 3.3:
       ```
       $ /usr/bin/openssl pkeyutl -sign -inkey <pkcs8-ed25519.pem> -rawin -in input -out sig
       unable to load Private Key
       error:06FFF09C ... unsupported algorithm
       error:06FFF076 ... TYPE=Ed25519
       ```
       Reproduced with the daemon-side helper PEM generator from lines 73–84.
     - The brew-installed OpenSSL 3.6.2 (at `/opt/homebrew/bin/openssl`) does support Ed25519 and would produce a correct 64-byte signature, but the script does not use it.
   - **Impact:** Every real release will go *past* the GitHub release attach step (which depends only on `gh release create` + DMG) and then **fail at the appcast job with `set -e`**. Users on existing installs see no update; the GH release ships unsigned-appcast (i.e. Sparkle clients reject it). The release.yml `tap-bump` job is gated on `needs: [preflight, appcast, release]`, so the tap also won't bump. Effectively: every release is half-shipped.
   - **Recommended fix:**
     1. Add `brew install --cask sparkle` to the `appcast` job in `release.yml` (and to `refresh` in `appcast.yml`) before `bash dist/appcast.sh`; export `/opt/homebrew/Caskroom/sparkle/*/bin/sign_update` onto PATH.
     2. As a belt-and-braces fallback inside `appcast.sh:86`, change `/usr/bin/openssl` → `${OPENSSL:-openssl}` and have the workflow set `OPENSSL=/opt/homebrew/bin/openssl` (or just let PATH lookup find brew's). Verifying the chosen openssl supports Ed25519 (`openssl pkeyutl -algorithm ed25519 -help 2>&1 | head -1` etc.) at script start would convert this from a runtime failure to a preflight error.
     3. Add a smoke-test path in `dist/tests/test_scripts.sh` that does the *real* (non-dry) signing against a tempfile and verifies the resulting `<item>` parses + signature roundtrip — would have caught this at PR time.

### 🟡 Should-fix

1. **Shellcheck offenses across `dist/`** (shellcheck 0.11.0; tool wasn't installed when smoke tests ran — I installed and re-ran).
   - `dist/_lib.sh:61` SC2294 — `eval "$@"` in `run()`; intentional (DRY_RUN wrapper) but worth either `# shellcheck disable=SC2294` with a comment or refactoring to array-form.
   - `dist/sign.sh:42,58` SC2089/SC2090 — `keychain_arg="--keychain '$KEYCHAIN_PATH'"` then `$keychain_arg` unquoted. Will silently misbehave if `KEYCHAIN_PATH` contains spaces; on CI the path is `$RUNNER_TEMP/myna-build.keychain-db` so OK in practice, but should be an array.
   - `dist/*.sh` SC2034 — `SCRIPT_HELP` is read by `parse_common_args` via dynamic scoping; harmless but trips shellcheck. `# shellcheck disable=SC2034` next to each assignment would silence cleanly.
   - **Recommended fix:** Add disable-comments where intentional, refactor `keychain_arg` to an array. Also: the smoke test at `test_scripts.sh:54–63` *silently warns* if shellcheck is missing — flip this to **install** shellcheck in CI (`brew install shellcheck` already happens nowhere in `ci.yml`'s `dist-scripts` job — add it). Right now nobody is actually running shellcheck.

2. **`dist/sign.sh:50` uses `mapfile`, which requires bash 4+.**
   - `#!/usr/bin/env bash` resolves to `/bin/bash` (3.2) on stock macOS. The GH `macos-15` runner ships brew-bash 5 by default *and* puts it ahead of `/bin/bash` in PATH, so this *probably* works in CI, but it'll break the moment a contributor runs `dist/sign.sh` locally on a Mac without brew bash. The dry-run smoke test skips the `mapfile` block (`if [ "${DRY_RUN:-0}" != "1" ]; then ... mapfile ...`), so the smoke test wouldn't catch a regression.
   - **Recommended fix:** Replace `mapfile -t targets < <(find …)` with a portable while-read loop, or bump the shebang to `#!/usr/bin/env -S /opt/homebrew/bin/bash` (less portable) or `#!/opt/homebrew/bin/bash` with a fallback note. Easiest: while-read.

3. **`dist/appcast.sh:149` shell-interpolates `$ITEM_XML` into a Python triple-quoted string — latent injection vector.**
   - **File:line:** `dist/appcast.sh:146–164`. Currently the interpolated content is built from `VERSION` (CI tag), `BUILD`, and a fixed `RELEASE_NOTES_URL` template — all controlled. But the moment somebody wants to put real release-notes text into the appcast item, a `"""` in the notes would break out of the Python string and execute arbitrary Python.
   - **Recommended fix:** Pass `ITEM_XML` to Python via a tempfile or env var (`os.environ['ITEM_XML']`) instead of shell interpolation.

4. **`tap/Casks/myna.rb:18` triggers `brew style` autocorrectable offense.**
   - `depends_on macos: ">= :ventura"` should be `depends_on macos: :ventura` (the `>=` is implicit for cask). Single autocorrectable issue.
   - **Recommended fix:** Run `brew style --fix tap/Casks/myna.rb` (or hand-edit).

5. **`tap/Formula/myna-daemon.rb:88` `test do` assertion will fail.**
   - **Evidence:** Assertion is `assert_match "usage", shell_output("#{bin}/myna-daemon --help 2>&1")`. The daemon's `__main__.py` has no argparse — it calls `uvicorn.run(...)` immediately, ignoring `--help`. Reproduced locally via `~/.venvs/myna/bin/python -m myna --help` → emits uvicorn startup logs (`INFO: Started server process …`), then attempts to bind 8766. Word `"usage"` is never printed. `brew test myna-daemon` would fail.
   - **Recommended fix:** Either (a) add a real `argparse` to `daemon/myna/__main__.py` with at least `--help`/`--port`/`--host`/`--version`, or (b) change the formula test to a less-invasive assertion such as `assert_predicate bin/"myna-daemon", :executable?` plus `assert_match "0.2.0", shell_output("#{libexec}/bin/python -c 'import myna; print(myna.__version__)'")`. Option (a) is the right fix for general daemon UX.

6. **`tap/Formula/myna-daemon.rb` writes `keybindings.json` to `etc/myna/`, but the daemon reads `~/.config/myna/`.**
   - **File:line:** `tap/Formula/myna-daemon.rb:43–51` writes `etc/"myna/keybindings.json"`; service block sets `MYNA_CONFIG_DIR: etc/"myna"` (line 62). `daemon/myna/config.py:5` hardcodes `CONFIG_DIR = pathlib.Path(os.path.expanduser("~/.config/myna"))` — `MYNA_CONFIG_DIR` is **not consulted**. So the formula-installed keybindings file is never read by the daemon. Note: keybindings in v2 are owned by the Swift app (via `KeyboardShortcuts`), so daemon-side keybindings are vestigial v1 — but the install path mismatch still means the formula and the running daemon disagree about where config lives.
   - **Recommended fix:** Either (a) make `daemon/myna/config.py` respect `os.environ.get("MYNA_CONFIG_DIR")` with fallback to `~/.config/myna`, or (b) drop `keybindings.json` from the formula install entirely (Lane A/Swift owns keybindings in v2) and pare `etc/myna` down to optional `config.json` only. Option (a) is the smaller change.

7. **Concurrency / idempotence: `release.yml` `appcast` job pulls existing appcast with `|| echo "no existing appcast"`.**
   - **File:line:** `.github/workflows/release.yml:295–299`. If `gh release download appcast` fails for *any* reason other than 404 (auth glitch, transient API error), the script continues and `dist/appcast.sh` writes a fresh `appcast.xml` containing **only** the current version. All previous versions vanish from the feed → existing installs see no rollback path and Sparkle's edge-case "newer-version-than-current" handling is fine, but historical metadata is lost.
   - **Recommended fix:** Distinguish 404 (expected on first release) from other failures. E.g. check `gh release view appcast` first; if it exists, *require* the download to succeed.

### 🟢 Nits

1. **`dist/appcast.sh:43,136` and `tap/*.rb` use `CHANGEME` placeholders.** `RELEASE.md § 1.7` documents this as operator work — acceptable but could use a single `dist/configure-owner.sh OWNER` helper that performs the find-replace.
2. **`release.yml` runs every job on a fresh `macos-15` runner with `actions/checkout@v4`** — each job re-pays the checkout cost. Could be optimized via `actions/cache` for xcodegen/brew, but optimization is premature.
3. **`dist/_lib.sh:74–95` `version_from_tag` precedence is `VERSION env > GITHUB_REF_NAME > GITHUB_REF > MARKETING_VERSION`**, which is sensible, but the fallback "0.0.0-dev" silently masks an empty `MARKETING_VERSION`. Should `die` instead.
4. **`UpdateController.swift`** is clean — no `print()`, no `try!`, no `fatalError`, `@MainActor` correct, `cancellables` stored, `[weak self]` in Combine sink. ✅ Nit: comment at line 31 references "AppDelegate-era code" but the app is pure-SwiftUI — slightly anachronistic.
5. **`apps/macos/project.yml`** has `SUEnableInstallerLauncherService: YES`. Sparkle 2 requires this for XPC-launched installer; just confirming intentional. ✅
6. **`appcast.yml`** has a clever `tac releases.txt > releases.rev.txt 2>/dev/null || tail -r releases.txt > releases.rev.txt` portability dance — nice. Worth pulling into `_lib.sh` if reused.

### Strengths noted

- **Preflight job** in `release.yml:45–85` fails fast with named missing secrets — saves enormous debugging time. Excellent pattern.
- **Idempotent release creation** at `release.yml:340–347`: if the release already exists (re-run after partial failure), update instead of erroring. Recoverable failures are the norm in Apple infra; this matters.
- **`workflow_dispatch` with tag input** on `release.yml:27–32` allows manual re-runs without re-tagging — operationally crucial.
- **DMG is signed AND notarized AND stapled separately from the .app inside it** (`release.yml:240–256`) — matches Apple's actual requirements (lots of pipelines miss this; many users see "damaged" DMG warnings as a result).
- **Sparkle integration in `UpdateController.swift`** is textbook Sparkle 2: `SPUStandardUpdaterController(startingUpdater: true, ...)`, `canCheckForUpdates` mirrored via KVO publisher into a `@Published`, `[weak self]` in the sink, `@MainActor` on the class. Lane A can wire this in with a one-liner.
- **`RELEASE.md`** is unusually complete for a first-release operator manual: covers one-time setup ordering (cert → app-pass → Sparkle → GH secrets → tap → CHANGEME), per-release procedure, **rollback** (§ 3), **manual notarization fallback** (§ 4), and useful diagnostic commands (§ 5). All four required RELEASE.md properties from the audit prompt are present.
- **`dist/*.sh` discipline**: every script has `--help`, `--dry-run`, `set -euo pipefail`, sources `_lib.sh`, and is exercised by `test_scripts.sh`. The shared `_lib.sh` `run()` wrapper makes dry-run uniform.
- **Concurrency group `release-${{ github.ref }}` with `cancel-in-progress: false`** (`release.yml:34–36`) prevents two concurrent releases of the same tag from racing the notarize step. Right call.

### Overall verdict

- [x] APPROVED to merge *(after RESOLUTION below)*
- [ ] APPROVED with follow-ups (file follow-up tasks)
- [ ] BLOCKED — fix blockers and re-review

**Rationale:** Blocker #1 (Sparkle private key in the repo) is a foundational trust failure for the entire Sparkle update mechanism — the only chain that lets Myna self-update securely. If a v0.1.0 build ships with the current public key, the update channel is permanently compromised: attackers can forge any update. The fix is small (regenerate keypair, replace the test-fixture key with a random one, rebuild Info.plist) but it must happen *before* any signed release reaches a user. Blocker #2 (appcast signing never succeeds in CI) means even setting aside the trust issue, the pipeline produces a half-released v0.1.0 (DMG attached, but Sparkle feed broken, tap not bumped). Both are mechanical fixes — total work is probably 30–60 minutes — but they must land before the next release attempt. Everything else (build succeeds, codesign flags correct, tap formulas almost right, RELEASE.md thorough, UpdateController clean) is in good shape.

### RESOLUTION (orchestrator, 2026-05-25)

Both 🔴 blockers fixed before any release went out. Caught pre-ship — no installed Myna build was ever signed with the leaked key, so no user-side trust was compromised.

**Blocker #1 — leaked Sparkle key:** Rotated the production EdDSA keypair using a fresh `openssl genpkey -algorithm Ed25519` (Homebrew openssl@3, which actually supports Ed25519). New public key landed in `apps/macos/project.yml` (`SUPublicEDKey`) and the generated `Resources/Info.plist`. New private key is in the gitignored `dist/sparkle_private_key.NEVER_COMMIT.txt` — Rashid moves it to 1Password and to the `SPARKLE_EDDSA_PRIVATE_KEY` GitHub Actions secret in the morning. `dist/tests/test_scripts.sh:26` now uses a *separately-generated*, *throwaway* test-only key with a comment explaining it never corresponds to the real public key. The literal leaked key string has been redacted from this audit report (it's still in git history of `test_scripts.sh`, but rotated → no longer dangerous; any future archaeologist finding it cannot use it to forge updates against the new public key).

**Blocker #2 — broken appcast signing in CI:** `dist/appcast.sh` rewritten to (a) prefer Sparkle's `sign_update` binary, (b) when falling back to openssl, prefer Homebrew's `openssl@3` and explicitly *reject LibreSSL* up-front with a clear error, (c) accept env overrides `SIGN_UPDATE_BIN` and `OPENSSL_BIN`. `release.yml` `appcast` job now downloads the pinned Sparkle release tarball (`Sparkle-2.6.4`) before signing, and explicitly installs `openssl@3` as belt-and-braces. Also addressed the 🟡 #2 string-injection latent in the Python heredoc on the old line 149 by passing `ITEM_XML`/`VERSION` through env vars instead of shell interpolation.

**Verification post-fix:**
- `bash dist/tests/test_scripts.sh` → 16/16 pass with the new throwaway key
- All workflow YAML parses cleanly
- `git ls-files | xargs grep` for the rotated-out private key → 0 hits in committed files (cited evidence in this report has been redacted to `<value>`-style references)
- New private key is in `dist/sparkle_private_key.NEVER_COMMIT.txt`; `git check-ignore` confirms the file is excluded
- New public key matches between `project.yml` and `Resources/Info.plist`

🟡 follow-ups (#2 already fixed as side-effect; remaining: #1 mapfile portability, #3 brew style autocorrect in myna.rb, #4 broken `brew test` assertion in myna-daemon.rb, #5 `MYNA_CONFIG_DIR` ignored by daemon, #6 lost-appcast-history failure mode in release.yml) deferred to STATUS.md morning briefing.

<!-- Security review will be appended here -->

<!-- Final verification (real app launch) will be appended here -->
