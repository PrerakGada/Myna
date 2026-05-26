# MynaKaraoke sidecar — release flow

> **Status:** v0.2 — Track C (karaoke ribbon). Builds on v0.1.0's release pipeline.
> Read alongside `RELEASE.md` (existing operator manual).

## What ships in v0.2

```
Myna.app/
└── Contents/
    ├── MacOS/Myna              # outer app — Track A
    ├── Frameworks/Sparkle.framework
    └── Resources/
        └── MynaKaraoke.app/    # sidecar — Track C (this doc)
            └── Contents/
                ├── MacOS/MynaKaraoke   (~386 KiB, arm64 thin)
                └── Info.plist
```

The sidecar is a separate, signed `.app` nested inside the outer Myna.app.
It runs as a child process of the daemon, NOT as a LaunchAgent. The DMG
and Homebrew cask install Myna.app; the sidecar comes along for free.

## The build/sign sequence (read this if anything breaks)

1. `dist/build.sh` runs `xcodebuild archive` → `dist/export/Myna.app` (no signing).
2. `dist/build.sh` then invokes `karaoke/build.sh`:
   - `swift build -c release --arch arm64`
   - Wraps binary in `karaoke/MynaKaraoke.app`
   - Signs sidecar with `DEVELOPER_ID_APPLICATION` + hardened runtime + entitlements
3. `dist/build.sh` `ditto`s the signed sidecar into `Myna.app/Contents/Resources/MynaKaraoke.app`.
   `ditto` (NOT `cp -R`) preserves xattrs and the codesign blob.
4. `dist/sign.sh` signs the outer Myna.app. Critical points:
   - Sparkle.framework gets its bespoke handling (existing v0.1 logic).
   - The nested `MynaKaraoke.app` is **excluded** from the generic re-sign loop —
     it arrived already signed and re-signing the same identity over a fresh
     bundle can desync signature blobs (lesson from v0.1.0 sign saga).
   - The outer Myna.app sign re-seals the sidecar's hash into Myna.app's
     CodeResources — that's the correct Apple-nested-bundle pattern.
5. `dist/notarize.sh` → `dist/dmg.sh` → `dist/sign.sh` again on the .dmg.
   Notarization sees the whole nested tree; both layers must be signed and
   hardened.

## Pre-release dry-run checklist

Before tagging v0.2.0, run these locally:

```bash
cd ~/Developer/myna

# 1. Sidecar standalone build + sign verify
DEVELOPER_ID_APPLICATION="$(security find-identity -v -p codesigning | \
  grep 'Developer ID Application' | head -1 | awk -F'"' '{print $2}')" \
  bash karaoke/build.sh

codesign --verify --strict --verbose=2 karaoke/MynaKaraoke.app
# expect: "valid on disk" + "satisfies its Designated Requirement"

# 2. Sidecar runtime smoke (no daemon needed)
rm -f /tmp/karaoke-smoke.sock
karaoke/MynaKaraoke.app/Contents/MacOS/MynaKaraoke --socket /tmp/karaoke-smoke.sock &
KPID=$!
sleep 0.5
printf '%s\n' \
  '{"v":1,"type":"start","id":"u_smoke","sentence":"Hello world","words":[{"i":0,"t":"Hello"},{"i":1,"t":"world"}],"estimatedDurationMs":500,"voice":"af_heart"}' \
  '{"v":1,"type":"word","id":"u_smoke","i":0,"tMs":0}' \
  '{"v":1,"type":"word","id":"u_smoke","i":1,"tMs":250}' \
  '{"v":1,"type":"stop","id":"u_smoke"}' \
  | nc -U /tmp/karaoke-smoke.sock
# expect: ribbon flashes briefly at the bottom of your main screen and fades out
kill $KPID
rm -f /tmp/karaoke-smoke.sock

# 3. Full pipeline dry-run
bash dist/build.sh --dry-run
DEVELOPER_ID_APPLICATION="Developer ID Application: Test (TEAMID)" \
  bash dist/sign.sh --dry-run
# both should print "ok" lines and exit 0

# 4. Smoke test suite
bash dist/tests/test_scripts.sh
# expect: 22 pass, 0 fail (was 16 in v0.1; +6 karaoke checks)

# 5. Full build with real signing (when you have certs)
bash dist/build.sh && bash dist/sign.sh
ls -la dist/export/Myna.app/Contents/Resources/MynaKaraoke.app
codesign --verify --deep --strict --verbose=2 dist/export/Myna.app
spctl --assess --type execute --verbose=2 dist/export/Myna.app
# expect: "accepted" + "source=Developer ID"
```

## Manual sanity after install

After the user double-clicks the .dmg and drags Myna.app to Applications:

```bash
# 1. Bundle structure
ls -la /Applications/Myna.app/Contents/Resources/MynaKaraoke.app/Contents/MacOS/
# expect: MynaKaraoke (executable)

# 2. Signature
codesign --verify --deep --strict --verbose=2 /Applications/Myna.app
spctl --assess --type execute /Applications/Myna.app
# expect: "accepted, source=Notarized Developer ID"

# 3. Sidecar launches and binds (smoke)
/Applications/Myna.app/Contents/Resources/MynaKaraoke.app/Contents/MacOS/MynaKaraoke \
  --socket /tmp/karaoke-install-smoke.sock > /tmp/karaoke-install-smoke.log 2>&1 &
sleep 0.5
ls -la /tmp/karaoke-install-smoke.sock
# expect: srw------- (0600 perms, socket file present)
cat /tmp/karaoke-install-smoke.log
# expect: "karaoke: listening at /tmp/karaoke-install-smoke.sock"
pkill -f MynaKaraoke
rm -f /tmp/karaoke-install-smoke.sock /tmp/karaoke-install-smoke.log

# 4. End-to-end: with the daemon running and Track B's karaoke client wired,
#    invoking /v2/synthesize should auto-spawn the sidecar. Check:
pgrep -f MynaKaraoke
# expect: a PID after the first karaoke utterance
```

## Sparkle / appcast notes

The sidecar has **no Sparkle integration of its own.** It ships and updates as
a nested resource of the outer Myna.app. When Sparkle delivers a new Myna.app
to the user, it replaces the whole bundle — sidecar and all — atomically.

Implications:
- No separate appcast entry for MynaKaraoke.
- The sidecar's `CFBundleShortVersionString` follows the outer app's MARKETING_VERSION.
  Currently hardcoded to `0.2.0` in `karaoke/Resources/Info.plist`; bump in lock-step
  when the outer app version bumps.
- If a Sparkle delta update is used (file-level diff), the sidecar's binary
  diff is included like any other bundle resource. No special handling.

## Troubleshooting

**Sign saga prevention checklist:**

| Symptom | Cause | Fix |
|---|---|---|
| `bundle format is ambiguous` | re-signing nested .app with `--deep` | Don't `--deep` on outer. Sign nested separately, ditto, then sign outer once. |
| `unsealed contents present` after sidecar ditto | `cp -R` instead of `ditto` | Use `ditto` (always, everywhere, no exceptions). |
| `code object is not signed at all` on Resources/MynaKaraoke.app | Sidecar built without `DEVELOPER_ID_APPLICATION` | Set the env var before `karaoke/build.sh`, OR let `dist/build.sh` propagate it. |
| Notarization rejects nested bundle | Sidecar missing hardened runtime | `karaoke/build.sh` ALWAYS passes `--options runtime`. Confirm via `codesign -dvvv karaoke/MynaKaraoke.app | grep flags=` → expect `flags=0x10000(runtime)`. |
| `<defunct>` MynaKaraoke in Activity Monitor | Daemon (Track B) not reaping child | Use `asyncio.create_subprocess_exec` or call `os.waitpid(pid, os.WNOHANG)` periodically. |

**Tar-between-CI-jobs reminder** (from `MEMORY.md`):
- `actions/upload-artifact` flattens macOS bundles (destroys symlinks + xattrs).
- After any job that produces a built `Myna.app`, `tar czf myna-app.tgz Myna.app`
  before uploading; `tar xzf` in the next job.
- This applies to the OUTER bundle. The nested `MynaKaraoke.app` rides inside
  Myna.app, so the same tar-extract cycle preserves it. No second tar needed
  for the sidecar specifically.

## What's NOT in this doc (yet)

- Live config reload (Tier 1.5 — sidecar currently ignores `config` messages
  for layout changes; the type captures into `RibbonConfig` but no live re-layout).
- Multi-display ribbon positioning (uses `NSScreen.main` only).
- Better timing via mlx-audio measurement (Track B's daemon emits Option B
  char-weighted estimates; Tier 1.5 may upgrade to phoneme-level).
