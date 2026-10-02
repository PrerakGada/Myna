# Myna — Deployment Guide

> Focused operator manual for shipping a release. **Complements** the long-form `RELEASE.md` (one-time Apple Developer setup, secrets table, manual fallback) — read that first for the initial machine + GitHub setup. This file is the day-to-day per-release operator's reference.

---

## 1. TL;DR — per-release commands

```bash
# 1. Bump the version in apps/macos/project.yml
#    Find: MARKETING_VERSION: "0.1.0"  →  bump to "0.1.1"
$EDITOR apps/macos/project.yml

# 2. Commit the bump
git commit -am "release: v0.1.1"

# 3. Tag and push (this is what triggers .github/workflows/release.yml)
git tag v0.1.1 && git push origin main --tags
```

That's it. Releases are tag-driven. The workflow takes ~10–20 minutes end-to-end (notary wait is the slow part — Apple's queue varies wildly).

---

## 2. What runs in CI on tag

`.github/workflows/release.yml` is triggered by `push: tags: [v*]`. Nine sequential jobs run on `macos-15` runners. Cite `architecture-ops.md §3` for the full job graph; here's the operator-perspective walk-through.

1. **`preflight`** (~30s) — verifies all 8 mandatory secrets are present, detects optional `TAP_DEPLOY_KEY`, resolves the version from the tag.
2. **`build-universal`** (~3–5 min) — xcodegen → xcodebuild archive (universal arm64 + x86_64). Tarballs `Myna.app` into `myna-app-unsigned.tar`.
3. **`sign`** (~1–2 min) — imports Developer ID p12 into a temp keychain, runs `dist/sign.sh` (Sparkle bottom-up signing + generic deep-first signing). Tarballs into `myna-app-signed.tar`.
4. **`notarize`** (~3–10 min, **highly variable** — Apple's queue) — ditto-zips the .app, submits to `xcrun notarytool` with 30m timeout, staples the ticket back. Tarballs into `myna-app-stapled.tar`.
5. **`dmg`** (~1 min) — `brew install create-dmg`, runs `dist/dmg.sh`. Outputs `dist/out/Myna-$VERSION.dmg`.
6. **`sign-dmg`** (~3–10 min) — codesign the DMG with `--timestamp`, notarize+staple the DMG with the same script as step 4 but `TARGET_SET=1`.
7. **`appcast`** (~30s) — downloads existing `appcast.xml` from the dedicated `appcast` GH release (404 tolerated on first ever release), installs Sparkle 2.6.4's `sign_update` + Homebrew `openssl@3`, runs `dist/appcast.sh` to prepend a new `<item>` signed with the EdDSA private key. Exposes `outputs.sha256` of the DMG for `tap-bump`.
8. **`release`** (~10s) — idempotent `gh release create`/`upload --clobber` for `v$VERSION`; same for the permanent `appcast` release.
9. **`tap-bump`** (~1 min, gated on `has_tap_key == 'true'`) — checks out `${vars.HOMEBREW_TAP_REPO}` (default `<owner>/homebrew-tap`) using `TAP_DEPLOY_KEY`, sed-updates the cask `version` + `sha256`, sed-updates the formula `url` + `sha256` (curl-retries up to 5× for the GitHub-generated source tarball), commits + pushes.

Total wall-clock budget: **10–20 minutes**, dominated by notarize × 2.

---

## 3. Watching a release

```bash
# Stream-watch the in-flight run
gh run watch

# Or list the most recent run for release.yml
gh run list --workflow release.yml --limit 1

# Tail the failing job's logs after the fact
gh run view <run-id> --log-failed

# Tail one specific job's full log (find <job-id> in `gh run view <run-id>`)
gh run view --job <job-id> --log

# All artifacts produced by the run (helpful for downloading the DMG locally
# if release/appcast publication failed partway through)
gh run download <run-id> --dir /tmp/myna-run
```

Common spots to look:

- `preflight` failing → an Actions secret is missing (`gh secret list --repo PrerakGada/myna`).
- `notarize` failing → run `xcrun notarytool log <submission-id> --apple-id $APPLE_ID --team-id RC63N3VU27 --password $APPLE_ID_APP_PASSWORD`. The submission ID is printed in the failing job log. (This dance is the gap `HANDOFF.md:76` documents — `dist/notarize.sh` should auto-fetch this log; see `development-guide-ops.md §5`.)
- `appcast` failing with `signing produced an empty signature` → `sign_update` install step earlier in the same job failed or LibreSSL slipped in. Check the `openssl@3` install line.
- `tap-bump` failing on `curl … 404` → GitHub hadn't finished generating the source tarball yet; the 5-attempt retry should mask this but bursty failures happen. Re-run the workflow.

---

## 4. Verifying a release

Run these against a freshly-installed `/Applications/Myna.app` (or a downloaded DMG):

```bash
# Gatekeeper assessment (must say "accepted")
spctl --assess --type execute --verbose=2 /Applications/Myna.app

# Codesign deep-strict verification (no output = success)
codesign --verify --deep --strict --verbose=2 /Applications/Myna.app

# Confirm the offline notarization ticket is stapled (no network, no Apple round-trip)
stapler validate /Applications/Myna.app

# Verify the Sparkle EdDSA signature against the public key
# (requires Sparkle's sign_update -v; install via the Sparkle.app cask
#  or the Sparkle releases tarball at github.com/sparkle-project/Sparkle)
SPARKLE_PUB="lEoEYOBRVnzZC9bysaAYSRpEuXSDmd/FagSmzv2ozHg="  # from project.yml:60
sign_update -v -p "$SPARKLE_PUB" -s "<edSignature from appcast.xml>" \
            -f <(echo "$SPARKLE_EDDSA_PRIVATE_KEY") \
            /path/to/Myna-0.1.1.dmg

# Confirm the appcast lists the new version
curl -fsSL "https://github.com/PrerakGada/myna/releases/download/appcast/appcast.xml" \
  | grep -A1 'sparkle:shortVersionString'

# Confirm the cask was bumped
brew tap PrerakGada/tap && brew info --cask myna
```

End-to-end install smoke test on a clean Mac:

```bash
brew uninstall --cask --zap myna 2>/dev/null || true
brew uninstall myna-daemon 2>/dev/null || true
brew install --cask myna
open /Applications/Myna.app
```

---

## 5. Hotfix flow

For a patch on top of `main` (no branch dance — `main` is the release branch):

```bash
git checkout main && git pull
# … edit the fix …
git commit -am "fix: <one-line>"
# Bump patch version in apps/macos/project.yml
$EDITOR apps/macos/project.yml
git commit -am "release: v0.1.2"
git tag v0.1.2 && git push origin main --tags
```

Same pipeline. Same 10–20 min budget. Same verification steps.

If you've already pushed the bad release and need to skip a number (e.g. `v0.1.1` shipped broken and you want `v0.1.3` to land), just bump straight there — version numbers don't have to be contiguous; Sparkle compares lexicographically with version semantics.

---

## 6. Rollback

A bad release happens. Full recovery procedure (extends `RELEASE.md:181`–`205`):

```bash
# 1. Delete the bad GH release and its tag.
BAD=v0.1.1
gh release delete "$BAD" --yes --repo PrerakGada/myna
git push --delete origin "$BAD"
git tag -d "$BAD"

# 2. Revert the tap commit so unattended `brew upgrade` doesn't pull the bad build.
cd ~/Developer/homebrew-myna  # or wherever your tap is checked out locally
git log --oneline -5
git revert <bad-sha>
git push

# 3. Regenerate the appcast.xml from the surviving good releases.
#    This fully rebuilds rather than incrementally appending — workflow_dispatch.
gh workflow run appcast.yml --field count=20 --repo PrerakGada/myna
# Wait for it to finish:
gh run watch
# Confirm the bad version is gone from the published appcast asset:
curl -fsSL "https://github.com/PrerakGada/myna/releases/download/appcast/appcast.xml" \
  | grep "$BAD" || echo "good — $BAD not in appcast"
```

**The hard part:** Sparkle clients that already pulled the bad update can't be "un-updated" remotely. They'll see the next good release as a regular update and pull it normally — so the practical fix is to ship a `v0.1.3` good version on top of the bad `v0.1.1` ASAP and let Sparkle resolve forward. Note this in release notes.

---

## 7. Manual fallback

If `.github/workflows/release.yml` is broken (Apple changes the notarytool API, GitHub Actions outage on macOS runners, etc.), the entire pipeline can be run locally. See `RELEASE.md §4` (lines 209–260) for the 9-step manual command list — it's intentionally not duplicated here because it's long and lives next to the operator setup it depends on. Every script also supports `--dry-run` to walk through without hitting Apple.

The local prerequisites are: Developer ID identity in your login keychain, `xcrun notarytool` (ships with Xcode), `brew install create-dmg openssl@3`, and the Sparkle private key from 1Password.

---

## 8. End-user install paths

### Homebrew (recommended)

```bash
brew tap PrerakGada/tap
brew install --cask myna
brew services start myna-daemon
```

**First install on a clean Mac takes ~20–30 minutes** because Homebrew's `--no-binary :all:` policy means every Python dep is compiled from sdist, including the Rust extensions in `pydantic_core` and `watchfiles`. Subsequent installs are bottle-cached and quick. Document this in any external launch comms — users will think the install hung otherwise. (`HANDOFF.md:18`)

The cask installs `Myna.app` to `/Applications/`. The formula installs the daemon as a Homebrew service (`brew services start myna-daemon` → LaunchAgent owned by Homebrew, logs at `$(brew --prefix)/var/log/myna-daemon.log`).

### DMG drag-install (manual)

1. Download `Myna-X.Y.Z.dmg` from the GitHub Releases page.
2. Open it — drag `Myna.app` to the `Applications` folder shortcut.
3. Eject the DMG.
4. Launch from `/Applications`. macOS prompts for Accessibility + (optionally) Automation permissions on first hotkey use.

Manual install does **not** install the Python daemon — that's a separate `brew install myna-daemon`, or the dev `install.sh` from the repo for a non-brew install.

### Dev install (from a git clone)

```bash
git clone https://github.com/PrerakGada/myna ~/Developer/myna
cd ~/Developer/myna
./install.sh
```

See `architecture-ops.md §8` for what `install.sh` actually does. This path installs the legacy Hammerspoon module too — if you also have the Swift app running, **last hotkey registration wins** (see `architecture-ops.md §10`).

---

## 9. Sparkle upgrade UX

**Automatic:** the .app polls `https://github.com/PrerakGada/myna/releases/download/appcast/appcast.xml` on a Sparkle-default interval (24h) and offers updates in a modal when the appcast advertises a newer `sparkle:shortVersionString`. The update flow downloads the DMG, verifies the EdDSA signature against the baked-in `SUPublicEDKey`, verifies the Developer ID + notarization staple, and installs in place — no user shell command needed.

**Manual check:** **Myna menu → Check for Updates…** triggers `SUUpdater.checkForUpdates`. Useful for verifying the appcast is reachable.

**Disabling auto-updates:** Settings → Advanced → unchecks "Automatically check for updates". Users who do this should be reminded via release notes that they're now on the hook for `brew upgrade --cask myna` manually.

**Cask vs Sparkle interaction:** the cask carries `auto_updates true` (`tap/Casks/myna.rb:17`). This tells Homebrew **not** to replace the .app on unattended `brew upgrade` — Sparkle owns the upgrade. `brew upgrade --cask myna` still works for users who explicitly invoke it; that path is the escape valve when Sparkle is mid-download or the user has disabled it.

---

## 10. Telemetry

**None.**

Myna is a local-only app. No analytics SDKs, no crash reporters that phone home, no usage pings. The only outbound network connections any installed copy makes are:

- First-launch setup downloads: uv and Python (GitHub), the engine packages (PyPI) and the Kokoro model (Hugging Face).
- Feedback, and only when the user presses **Send** in **Report a Problem…** / **Send Feedback…**: one HTTPS `POST https://api.prerakgada.in/v1/p/myna/feedback` carrying the typed message, optional name and email, app version, build, platform, macOS version and Mac model (`hw.model`). No retries, no queue, no background sending. `AppDelegate.bootstrap()` installs the real `FeedbackClient`; tests and every pre-bootstrap path keep `OfflineFeedbackSender`, which never touches the network. Spec: `work/company/infra/product-feedback.md`.
- The Sparkle update check (HTTPS GET of `appcast.xml` from GitHub Releases) — Apple's own SUUpdater code.
- Daemon HTTP calls between `Myna.app`, `myna-daemon` (`:8766`), and the local Kokoro/mlx-audio engine (`:8765`) — all on `127.0.0.1`.
- `trafilatura`'s URL fetch when the user hits the "Read Chrome article" hotkey (HTTPS GET of the URL the user just opened in Chrome).

This is stated in `SECURITY.md:3`. If you ever consider adding telemetry, it must be opt-in, document the exact payload, and survive a privacy-conscious user reading `SECURITY.md` and feeling lied to.
