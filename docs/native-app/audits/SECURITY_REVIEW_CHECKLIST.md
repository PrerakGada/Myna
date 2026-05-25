# L0 Security Review Checklist

**Auditor scope:** Run AFTER all three lanes have merged. Auditor never sees code reviewer's output. Independent.

**Output:** Append `## Security Review — <date>` to `docs/native-app/audits/AUDIT_REPORT.md`.

---

## Threat model recap

Myna runs locally. It speaks selected text and reads Chrome articles. The daemon binds 127.0.0.1. Kokoro likewise. Threats we care about:

1. **Local privilege escalation via URL scheme.** Any local process can `open myna://...`. Inputs must be validated.
2. **Pasteboard leakage.** SelectionService temporarily owns the pasteboard; if it crashes mid-flow, the prior clipboard is lost. Worse: if it stashes the prior contents somewhere observable (logs, files), it leaks.
3. **AppleScript injection.** ChromeService runs an AppleScript. If we ever templated user input into it, that'd be RCE-class.
4. **Engine downstream.** Kokoro is third-party Python with a TTS engine. We HTTP it; we don't trust its output beyond "audio bytes."
5. **Sparkle update spoofing.** If the appcast feed URL is HTTPS but the public key is wrong/missing/swappable, an attacker on the network could push a malicious update.
6. **Code signing.** Without notarization, Gatekeeper warns and some macOS versions just refuse to launch.
7. **TCC (accessibility) trust.** Once granted, our process can simulate keystrokes anywhere. Compromise of the binary = full keyboard access. Code-sign integrity matters.

---

## Checklist

### URL scheme (`myna://`)

- [ ] All numeric params parsed with `Double(…)` / `Int(…)` (no `eval`, no shell-string interpolation)
- [ ] `speed` value/delta clamped to [0.5, 2.0]
- [ ] `seek` delta clamped to [-3600, 3600]
- [ ] No `myna://speak?text=...` or any route that takes arbitrary text from URL — Lane A spec says NO. Verify.
- [ ] No `myna://exec`, `myna://run`, `myna://shell`, or anything that runs a command
- [ ] Unknown actions logged (not silently ignored — we want to see if other apps are probing us) but don't crash
- [ ] URL parsing handles malformed input without crashing (`myna://?%FF`, `myna://`, `myna://?=`)

### Pasteboard

- [ ] `SelectionService` saves prior pasteboard before clearing
- [ ] `SelectionService` restores prior pasteboard in BOTH success and failure paths (use `defer`)
- [ ] Prior pasteboard contents NEVER logged or persisted
- [ ] Captured text NEVER logged at full length (truncate to 60 chars in logs, matching daemon's behavior)
- [ ] No leak of captured text to the disk except via the in-flight HTTP request to localhost daemon

### Chrome AppleScript

- [ ] Static AppleScript string — no user input interpolated
- [ ] Returned URL validated before being sent to daemon (http/https only)
- [ ] Failure modes don't crash the app
- [ ] AppleScript timeout (don't hang the menu bar if Chrome is wedged)

### Daemon HTTP

- [ ] Daemon URL validation in Settings rejects non-`127.0.0.1`/`localhost`
- [ ] Daemon client uses `URLSession` with reasonable timeout (default 30s; synthesize longer)
- [ ] No client-side construction of arbitrary URLs from user input (e.g., we don't `let url = URL(string: userText)` for the extract endpoint without validation)
- [ ] No credentials in URLs or logs
- [ ] Engine-down errors degrade gracefully (alert, not crash)

### Entitlements & sandboxing

- [ ] Hardened runtime ENABLED (`ENABLE_HARDENED_RUNTIME = YES`)
- [ ] `cs.allow-jit` = false
- [ ] `cs.allow-unsigned-executable-memory` = false
- [ ] `cs.disable-library-validation` = false
- [ ] `cs.disable-executable-page-protection` = false
- [ ] `automation.apple-events` = true (needed for Chrome)
- [ ] App is NOT sandboxed (correct — sandbox would block CGEvent.post; document this prominently in NATIVE_APP_PROPOSAL)
- [ ] `NSAppleEventsUsageDescription` set with a clear user-facing reason

### Sparkle

- [ ] `SUPublicEDKey` set to a REAL key (not the `REPLACE_WITH_...` placeholder)
- [ ] `SUFeedURL` is HTTPS
- [ ] Private EdDSA key NOT in any file under `git status` (check `git ls-files | xargs grep -l "BEGIN PRIVATE"` returns empty)
- [ ] `dist/sparkle_private_key.NEVER_COMMIT.txt` (or similar) is gitignored
- [ ] `RELEASE.md` documents storing private key in 1Password + GitHub Actions secret
- [ ] No `SUAllowsAutomaticUpdates` set to true without a signed appcast (Sparkle 2 defaults are safe but verify)

### Code signing & notarization (workflow review)

- [ ] `release.yml` signs with `--options runtime` (hardened runtime enforced)
- [ ] `release.yml` includes `--timestamp` (Apple requires)
- [ ] `release.yml` includes entitlements with `--entitlements`
- [ ] Notarize step waits for completion (`--wait`)
- [ ] Staple step runs after notarize succeeds
- [ ] DMG also signed
- [ ] Failure of any step exits the workflow (no silent partial release)

### Daemon side (review what Lane C did)

- [ ] Daemon still binds 127.0.0.1 only (not 0.0.0.0)
- [ ] `/v2/extract` URL validation rejects non-http/https (no `file://`)
- [ ] No new dependency introduced without consideration of its supply-chain risk
- [ ] No `eval` / `exec` / `os.system` introduced
- [ ] No SSRF risk added by extract endpoint (trafilatura is the existing path; same risk as v1)

### Logs

- [ ] Log file at `~/Library/Logs/Myna/myna.log` — sensible permissions (user-only)
- [ ] No secrets logged
- [ ] No full captured-text logged
- [ ] Log rotation works (no unbounded growth)

### Misc

- [ ] No telemetry endpoints (Myna is local-only)
- [ ] No analytics SDK
- [ ] No crash reporter SDK that uploads
- [ ] README/proposal clearly state "fully local, no network calls except localhost daemon and Sparkle update check"

---

## Severity rubric

- **🔴 Critical** — Local code exec, key leak, signature bypass.
- **🟠 High** — Pasteboard leak, AppleScript injection, missing URL validation in a way that's actually reachable.
- **🟡 Medium** — Missing-timeout class of issues, log content concerns, missing entitlement hardening.
- **🟢 Low** — Defense-in-depth nits.

---

## Auditor's output template

```markdown
## Security Review — <date>

### Summary
- Threat model coverage: …
- Critical findings: <count>
- High findings: <count>

### 🔴 Critical
1. …

### 🟠 High
1. …

### 🟡 Medium
1. …

### 🟢 Low
1. …

### Verdict
- [ ] APPROVED — ship v0.1 once high-and-above are addressed
- [ ] BLOCKED — critical/high findings outstanding
```
