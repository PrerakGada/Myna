# L0 Code Review Checklist

**Auditor scope:** Run AFTER a lane merges to `native-app-rebuild`. Auditor never sees other auditors' output. Independent.

**Output:** Append a section to `docs/native-app/audits/AUDIT_REPORT.md` per lane reviewed.

---

## Universal checklist (every lane)

### Build & test
- [ ] `xcodebuild build` succeeds (Lane A, Lane B for Updates module)
- [ ] `xcodebuild test` 100% pass (Lane A)
- [ ] `pytest daemon/tests` 100% pass (Lane C; ≥ 33 existing + new)
- [ ] `swiftlint --strict` 0 warnings
- [ ] `swift-format lint --strict` 0 warnings
- [ ] `bash dist/tests/test_scripts.sh` exits 0 (Lane B)
- [ ] All workflow YAML parses

### Spec conformance
- [ ] Public types match API_CONTRACT.md § 4–5 exactly (field names, JSON keys, nullability)
- [ ] No deviations from NATIVE_APP_PROPOSAL.md without a documented "open question for orchestrator"
- [ ] Fixture-loading tests pass (Lane A and Lane C both load same fixtures)

### Correctness
- [ ] No `fatalError` / `try!` in production code paths (force-unwrap is opt-in tracked by SwiftLint)
- [ ] No `print()` — use `Log.swift`
- [ ] Concurrency: `@MainActor` annotations correct; no data races (Swift 6 strict concurrency on)
- [ ] Error paths actually return errors, not silently swallowed
- [ ] Numeric inputs clamped where spec says (speed 0.5–2.0, seek ±3600)

### Resource safety
- [ ] All `URLSession` calls have timeouts
- [ ] All file handles closed (use `defer` or scoped APIs)
- [ ] No leaked observers (Combine cancellables stored)
- [ ] No retain cycles (closures capturing `self` use `[weak self]` where appropriate)

### Tests
- [ ] No real-network calls in unit tests
- [ ] No real-daemon dependency in unit tests
- [ ] No real-FS writes outside `FileManager.default.temporaryDirectory`
- [ ] Tests run < 30s total (Lane A); < 10s (Lane C)
- [ ] No flaky `sleep()` in tests — use expectations or async-await

### Documentation
- [ ] Every public type/function has a doc comment if non-obvious
- [ ] `// NOTE for orchestrator:` markers all addressed or escalated

---

## Lane A specifics

- [ ] `AudioPlayer` graph correct: `AVAudioPlayerNode` → `AVAudioUnitTimePitch` → mainMixer
- [ ] Speed change uses `.rate` on `AVAudioUnitTimePitch`, NOT `AVAudioPlayer.rate` (pitch must stay 0)
- [ ] `SelectionService` restores prior pasteboard
- [ ] `ChromeService` URL validation rejects non-http/https
- [ ] `URLSchemeHandler` rejects unknown actions cleanly (no crash, logs)
- [ ] `URLSchemeHandler` has NO route that accepts arbitrary text-to-speak from URL params (per spec § 8 security note)
- [ ] All 5 default hotkeys match v1 keybindings.json exactly
- [ ] MenuBar polls `/v2/status` (not `/status`)
- [ ] Settings → Daemon: URL field validation rejects non-localhost
- [ ] `LSUIElement` still true; no Dock icon
- [ ] `myna://` registered in Info.plist (test from SkeletonTests.swift still passes)

## Lane B specifics

- [ ] Every CI secret referenced in workflow YAML is documented in `RELEASE.md`
- [ ] Every `dist/*.sh` script has `--help` and `--dry-run`
- [ ] Sparkle private key NOT in any committed file; gitignored
- [ ] Sparkle EdDSA public key in `project.yml` is real (not placeholder)
- [ ] Tap formula matches what `install.sh` does for the daemon
- [ ] Cask `auto_updates true` (so brew doesn't fight Sparkle)
- [ ] `release.yml` produces a single .dmg artifact attached to release
- [ ] `appcast.yml` doesn't accidentally update appcast on every push
- [ ] Universal binary (arm64 + x86_64) configured

## Lane C specifics

- [ ] `/v2/synthesize` does NOT call `app.state.player` (Swift owns playback)
- [ ] Multipart boundary is exactly `mynachunk`
- [ ] Headers per part match spec exactly (`X-Chunk-Index`, etc.)
- [ ] Final JSON part present, with `{"ok": true, "chunks": N, "session_id": "..."}`
- [ ] All v1 tests still pass
- [ ] `/v2/status` response key set EXACTLY matches `fixtures/status-response.json`
- [ ] `/v2/voices` cache TTL ≈ 5 min; respected
- [ ] `__version__` = `"0.2.0"` in `daemon/myna/__init__.py`
- [ ] `pyproject.toml` version bumped to `0.2.0`
- [ ] No new pip dependencies (or each new one justified in commit body)

---

## Severity rubric

- **🔴 Blocker** — must fix before integration. Spec violation, test failure, security flaw, leak.
- **🟡 Should-fix** — addressable in v0.2. Code smell, missing test, suboptimal pattern.
- **🟢 Nit** — style/clarity. Optional.

Auditor produces a list of findings with severity, file:line, evidence (test output or code snippet), and recommended fix.

---

## Auditor's output template

```markdown
## Lane <X> Code Review — <date>

### Summary
- Modules reviewed: …
- Build status: …
- Test status: …
- Lint status: …

### 🔴 Blockers
1. …

### 🟡 Should-fix
1. …

### 🟢 Nits
1. …

### Strengths noted
- …

### Overall verdict
- [ ] APPROVED to merge
- [ ] APPROVED with follow-ups (file follow-up tasks)
- [ ] BLOCKED — fix blockers and re-review
```
