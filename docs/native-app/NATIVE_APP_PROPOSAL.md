# Myna — Native macOS App Proposal

**Status:** Design RFC for the v2 rebuild
**Branch:** `native-app-rebuild`
**Authors:** Orchestrator (Opus) for Rashid
**Date:** 2026-05-25

---

## 1. Why rewrite Hammerspoon as a native Swift app

Myna v1 is a 322-line Hammerspoon Lua script + a ~400-line FastAPI Python daemon + an external Kokoro-82M TTS server. It works. But the v1 architecture has two hard ceilings that block the feature roadmap:

1. **Playback is shelled out to `afplay`.** `afplay` cannot seek, scrub, or change playback rate. Every "speed up / slow down / rewind / forward / scrubber UI" feature is unimplementable while playback lives in a Python subprocess wrapping `afplay`.
2. **Hammerspoon is the only macOS surface.** Auto-updates, code signing, Homebrew Cask distribution, an "official" GitHub release flow, App Store-grade trust dialogs, custom URL schemes for BetterTouchTool — none of these are first-class in Hammerspoon. The app in the user's Dock/⌘-Tab is technically Hammerspoon, not Myna.

A native Swift menu bar app solves both problems and unlocks the v2 roadmap (speed/seek/scrub, Sparkle auto-updates, Homebrew cask, BTT URL scheme, native settings UI, log viewer, multi-voice picker, etc.).

## 2. Non-goals

- **Not an App Store app.** Direct distribution via Developer ID + notarization. The App Store sandbox blocks the accessibility/AppleScript permissions Myna needs.
- **Not a rewrite of the TTS engine.** Kokoro-82M (mlx-audio) stays exactly as-is, running on `:8765`. The daemon stays the OpenAI-compatible client.
- **Not a rewrite of the daemon's brain.** Chunking, extract, summarize, registry all stay in Python. We strip only the `Player` class.
- **Not bundling Python inside the .app** in v2.0. The daemon ships as a Homebrew formula (`myna-daemon`); the app ships as a cask (`myna`). Bundling Python is a v3 nicety.

## 3. Three-process architecture (v2)

```
┌─────────────────────────────┐       ┌──────────────────────┐       ┌──────────────┐
│   Myna.app (Swift)          │ HTTP  │  myna-daemon (Py)    │ HTTP  │  Kokoro-82M  │
│   menu bar + audio playback │ ────▶ │  brain (no player)   │ ────▶ │  mlx-audio   │
│                             │       │                      │       │  :8765       │
│  Owns:                      │       │  Owns:               │       └──────────────┘
│  • MenuBarExtra UI          │       │  • /synthesize       │
│  • Global hotkeys           │       │  • /chunk            │
│  • Selected-text capture    │       │  • /extract          │
│  • Chrome URL capture       │       │  • /summarize        │
│  • AVAudioEngine playback   │       │  • /announce         │
│    (speed / seek / scrub)   │       │  • /registry         │
│  • Settings, Logs, Updates  │       │  • /play/{id}        │
│  • myna:// URL scheme       │       │  • /v2/status        │
└─────────────────────────────┘       └──────────────────────┘
        ▲
        │ user input (hotkey / trackpad / BTT URL)
```

**Critical move:** the Swift app owns playback via `AVAudioEngine`. The daemon's `Player` class is deprecated and eventually deleted. The daemon's job shrinks to "given text, return WAV bytes for each chunk."

### 3.1 Why three processes, not two

Could the Swift app talk to Kokoro directly? Yes, but:

- Chunking, extraction, summarization, and the Claude-Code announce registry are all in Python with a 33-test suite. Porting them to Swift adds weeks for zero user-visible benefit.
- The daemon is already an HTTP service users install separately; the contract is stable.
- Keeping the daemon as the brain means v1 Hammerspoon and v2 Swift can run side-by-side during the transition, talking to the same daemon. Zero breaking change for existing users.

A v3 cleanup may port the daemon to Swift. Not in scope here.

## 4. Repository layout

```
myna/
├── apps/
│   └── macos/                          # NEW — Swift app lives here
│       ├── project.yml                 # XcodeGen spec (committed)
│       ├── Myna.xcodeproj/             # generated, gitignored
│       ├── Sources/
│       │   ├── MynaApp/                # @main entry, AppDelegate
│       │   │   ├── MynaApp.swift
│       │   │   └── AppDelegate.swift
│       │   ├── MenuBar/                # MenuBarExtra UI
│       │   │   ├── MenuBarController.swift
│       │   │   ├── MenuBarView.swift
│       │   │   └── BirdIcon.swift
│       │   ├── Audio/                  # AVAudioEngine player
│       │   │   ├── AudioPlayer.swift
│       │   │   ├── TimePitchUnit.swift
│       │   │   └── PlaybackQueue.swift
│       │   ├── Network/                # DaemonClient over URLSession
│       │   │   ├── DaemonClient.swift
│       │   │   ├── DaemonTypes.swift
│       │   │   └── SynthesizeStream.swift
│       │   ├── Input/                  # hotkeys + selection capture
│       │   │   ├── HotkeyManager.swift
│       │   │   ├── SelectionService.swift
│       │   │   └── ChromeService.swift
│       │   ├── URLScheme/              # myna:// handler
│       │   │   └── URLSchemeHandler.swift
│       │   ├── Settings/               # SwiftUI settings UI
│       │   │   ├── SettingsView.swift
│       │   │   ├── HotkeysTab.swift
│       │   │   ├── VoiceTab.swift
│       │   │   ├── DaemonTab.swift
│       │   │   └── AdvancedTab.swift
│       │   ├── Logging/                # OSLog + file logs
│       │   │   ├── Log.swift
│       │   │   └── LogViewerView.swift
│       │   └── Updates/                # Sparkle integration
│       │       └── UpdateController.swift
│       ├── Tests/
│       │   ├── MynaAppTests/
│       │   ├── AudioTests/
│       │   ├── NetworkTests/
│       │   ├── InputTests/
│       │   ├── URLSchemeTests/
│       │   └── SettingsTests/
│       ├── Resources/
│       │   ├── Assets.xcassets/        # app icon, status bar icon
│       │   ├── Info.plist
│       │   └── Myna.entitlements
│       └── README.md
│
├── daemon/                             # EXISTING — refactored
│   └── myna/
│       ├── app.py                      # + /synthesize, + /v2/status
│       └── player.py                   # DEPRECATED (still works for v1)
│
├── hammerspoon/                        # EXISTING — kept for v1 users
├── cli/                                # EXISTING
├── launchagents/                       # EXISTING
├── tap/                                # NEW — Homebrew tap source
│   ├── Casks/myna.rb                   # cask formula
│   └── Formula/myna-daemon.rb          # daemon formula
├── .github/
│   └── workflows/
│       ├── ci.yml                      # tests on every PR
│       ├── release.yml                 # tag → signed .dmg → GH release
│       └── appcast.yml                 # update Sparkle appcast on release
├── dist/                               # NEW — build/sign/notarize/dmg scripts
│   ├── build.sh
│   ├── sign.sh
│   ├── notarize.sh
│   ├── dmg.sh
│   ├── appcast.sh
│   ├── dmg-background.png
│   └── README.md
└── docs/
    └── native-app/                     # this proposal lives here
        ├── NATIVE_APP_PROPOSAL.md      # ← this file
        ├── API_CONTRACT.md
        └── TEST_PLAN.md
```

**File-touching rules (the parallelization-safe contract):**

| Lane | May write under | May NOT touch |
|---|---|---|
| A: App Core | `apps/macos/Sources/**`, `apps/macos/Tests/**`, `apps/macos/Resources/**`, `apps/macos/project.yml`, `apps/macos/README.md` | anything else |
| B: Release Pipeline | `.github/workflows/**`, `dist/**`, `tap/**`, `apps/macos/Sources/Updates/**` (Sparkle wiring only) | daemon, hammerspoon, cli |
| C: Daemon Refactor | `daemon/**` | apps, .github, dist, tap, hammerspoon |

Zero file overlap. Pure parallelism.

## 5. Tech choices (locked)

| Concern | Choice | Version | Rationale |
|---|---|---|---|
| Language | Swift | 6.x | Modern concurrency, strict typing, what Xcode 26 ships |
| Min macOS | 13.0 Ventura | — | `MenuBarExtra` requires 13+; Apple Silicon era anyway |
| UI | SwiftUI | — | `MenuBarExtra(_:isInserted:)` + `Settings { ... }` are first-class |
| Project | XcodeGen | 2.43+ | `project.yml` in git, `.xcodeproj` generated. Avoids merge hell. |
| Hotkeys + rebind UI | [`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) | 2.x | Sindre Sorhus, used by Plash/Dato/dozens. Recording UI built-in. |
| Audio playback | `AVAudioEngine` + `AVAudioUnitTimePitch` | system | Speed change without pitch shift; seek; pause/resume; sample-accurate |
| HTTP client | `URLSession` | system | No dependency for this |
| JSON | `Codable` | system | — |
| Logging | `OSLog` (Console.app) + file at `~/Library/Logs/Myna/myna.log` | system | Mirror to file for the in-app log viewer |
| Settings persistence | `@AppStorage` / `UserDefaults` | system | Standard |
| Auto-updates | [`Sparkle 2`](https://github.com/sparkle-project/Sparkle) | 2.6+ | Industry standard. EdDSA-signed appcast. |
| Linting | SwiftLint + swift-format | latest | Run in CI |
| Distribution | Developer ID + `notarytool` + Homebrew Cask | — | Direct distribution; cask is correct for menu-bar apps |
| Test framework | XCTest | system | Avoid Swift Testing until tooling settles |

### 5.1 Library install path

XcodeGen pulls SPM dependencies declaratively from `project.yml`:

```yaml
packages:
  KeyboardShortcuts:
    url: https://github.com/sindresorhus/KeyboardShortcuts
    from: 2.0.0
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
```

No `Package.swift` for the app target — XcodeGen handles it. Workers must not add Swift Packages by Xcode UI; only by editing `project.yml`.

## 6. Audio architecture (the unlock)

This is the section most worth getting right because it's the feature unlock.

### 6.1 Playback graph

```
AVAudioEngine
  ├─ AVAudioPlayerNode  ── connect ─▶  AVAudioUnitTimePitch  ── connect ─▶  mainMixerNode → output
  │
  └─ scheduleBuffer(buffer)         rate: 0.5–2.0  (no pitch shift)
     scheduleSegment(file, ...)     pitch: 0       (unchanged)
```

### 6.2 Why `AVAudioUnitTimePitch` and not `AVAudioPlayer.rate`

`AVAudioPlayer.rate` works but ties pitch to rate (chipmunk voice at 2×). `AVAudioUnitTimePitch` uses a phase vocoder to change rate **without** changing pitch, which is what you actually want for a TTS speed-up. Same approach Overcast and Apple Books use.

### 6.3 Chunk pipeline (replaces daemon Player)

```
1. Hotkey fires → DaemonClient.synthesizeStream(text, voice, speed)
2. Daemon returns chunks of WAV bytes (multipart or NDJSON of base64)
3. Each WAV chunk → AVAudioFile (written to /tmp) → AVAudioFile.read(into: buffer)
4. AudioPlayer.enqueue(buffer) → scheduleBuffer on playerNode
5. Buffer completion callback → dequeue next
6. UI subscribes to AudioPlayer.publisher for state, position, duration
```

### 6.4 Seek / scrub / rewind / forward semantics

Within a chunk, seek is exact (`scheduleSegment(at:)`). Across chunks, we maintain a virtual timeline: `globalPosition = sum(playedChunkDurations) + currentChunkPosition`. Rewind 15s walks backwards across chunk boundaries. Same for forward.

**Edge case:** seeking past the buffered-but-not-played boundary should NOT trigger re-synthesis if the chunk is already on disk. We keep WAV files for the duration of the current speak session in `~/Library/Caches/Myna/session-{uuid}/`, deleted when playback stops or session is replaced.

### 6.5 Pause/resume

`AVAudioPlayerNode.pause()` is sample-accurate. No SIGSTOP nonsense.

## 7. Input architecture

### 7.1 Selected-text capture

Same trick as v1: simulate `Cmd+C`, sleep ~120ms, read `NSPasteboard`. The 120ms is empirical (apps' copy handlers vary). We save the prior pasteboard contents and restore them after, so the user doesn't lose what was on their clipboard.

```swift
final class SelectionService {
    static func captureSelectedText() async -> String? {
        let pb = NSPasteboard.general
        let savedItems = pb.pasteboardItems?.map { $0.copy() } as? [NSPasteboardItem]
        pb.clearContents()
        // simulate Cmd+C
        let src = CGEventSource(stateID: .combinedSessionState)
        let kC: CGKeyCode = 0x08
        let down = CGEvent(keyboardEventSource: src, virtualKey: kC, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: kC, keyDown: false)
        up?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let text = pb.string(forType: .string)
        // restore prior clipboard
        if let saved = savedItems {
            pb.clearContents()
            pb.writeObjects(saved)
        }
        return text
    }
}
```

**Permissions:** Accessibility is required for `CGEvent.post`. App requests it on first hotkey use; falls back to instructing the user.

### 7.2 Chrome URL capture

`NSAppleScript` + the Scripting Bridge for Chrome. Same script as v1:

```applescript
tell application "Google Chrome" to return URL of active tab of front window
```

**Permissions:** Automation (AppleEvents) — Chrome must be added to the app's automation entitlement on first use.

### 7.3 Hotkeys

`KeyboardShortcuts` library. Five default actions matching v1:

```swift
extension KeyboardShortcuts.Name {
    static let speakSelectionFull    = Self("speakSelectionFull",    default: .init(.s, modifiers: [.command, .option, .shift]))
    static let speakSelectionSummary = Self("speakSelectionSummary", default: .init(.a, modifiers: [.command, .option, .shift]))
    static let readChromeArticle     = Self("readChromeArticle",     default: .init(.r, modifiers: [.command, .option, .shift]))
    static let pauseResume           = Self("pauseResume",           default: .init(.space, modifiers: [.command, .option, .shift]))
    static let stop                  = Self("stop",                  default: .init(.period, modifiers: [.command, .option, .shift]))
}
```

The library ships a `KeyboardShortcuts.Recorder(for:)` SwiftUI view that gives us the "Customize Shortcuts…" recorder for free.

## 8. URL scheme — `myna://`

Registered in `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>dev.myna.urlscheme</string>
    <key>CFBundleURLSchemes</key>
    <array><string>myna</string></array>
  </dict>
</array>
```

| URL | Action |
|---|---|
| `myna://speak-selection` | grab selection → speak full |
| `myna://speak-selection?mode=summary` | grab selection → summarize → speak |
| `myna://read-chrome` | grab Chrome URL → extract → speak |
| `myna://toggle-pause` | pause if playing, resume if paused |
| `myna://stop` | stop |
| `myna://seek?delta=+15` | forward 15s |
| `myna://seek?delta=-15` | rewind 15s |
| `myna://speed?value=1.25` | set speed |
| `myna://speed?delta=+0.25` | bump speed |

This is the BetterTouchTool integration surface. Every action a hotkey does is also a URL. BTT trigger → `open myna://…` → no keystroke simulation, no shortcut collision.

**Security:** URL handlers can be triggered by any local process. Inputs must be validated (clamp `speed` to [0.5, 2.0], `delta` to [-3600, 3600]). No file paths, no arbitrary text-from-URL speech (we read from selection/clipboard, never from URL params), no shell command execution.

## 9. Settings UI

SwiftUI `Settings { TabView { ... } }`. Four tabs:

1. **Hotkeys** — `KeyboardShortcuts.Recorder` for each of the 5 actions
2. **Voice** — voice picker (queries daemon `/voices` — TBD), default speed slider, summary mode toggle
3. **Daemon** — daemon URL + port, engine URL + port, "Restart Daemon" button (launchctl), health indicator
4. **Advanced** — log level, log file path, "Open Logs Folder" button, clear cache, reset all settings

All settings persist via `@AppStorage` keyed under `dev.myna.app.<key>`.

## 10. Logging

Two-layer:

1. **`OSLog`** — structured, viewable in Console.app under subsystem `dev.myna.app`
2. **File mirror** — append to `~/Library/Logs/Myna/myna.log`, rotated at 5MB, 5 files kept

In-app log viewer (`LogViewerView`) is a SwiftUI `ScrollView` + `Text` that tails the file. Filter by level, copy-to-clipboard, "Reveal in Finder" button.

## 11. Sparkle auto-updates

```swift
import Sparkle

@main
struct MynaApp: App {
    private let updater = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    var body: some Scene { ... }
}
```

- Appcast URL: `https://github.com/<owner>/myna/releases/download/appcast/appcast.xml` (or GitHub Pages)
- EdDSA-signed (Sparkle 2 default; required)
- Updates download silently, install on next launch
- "Check for Updates…" menu item exposed in MenuBarExtra

## 12. Distribution

### 12.1 Code signing & notarization

Required for Gatekeeper to not warn users. Inputs (stored as GitHub Actions secrets):

| Secret | What it is | Where to get |
|---|---|---|
| `APPLE_DEVELOPER_ID_P12` | Base64 of `Developer ID Application: <Name> (TEAMID).p12` | developer.apple.com → Certificates |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | password for the p12 | you set when exporting |
| `APPLE_ID` | your Apple ID email | — |
| `APPLE_ID_APP_PASSWORD` | app-specific password | appleid.apple.com → Sign-In Security |
| `APPLE_TEAM_ID` | 10-char team ID | developer.apple.com → Membership |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Sparkle's `generate_keys` output | run `Sparkle/bin/generate_keys` once |

CI workflow imports the cert into a temp keychain, signs with `codesign --options runtime --timestamp`, then `xcrun notarytool submit --wait`, then `xcrun stapler staple`.

### 12.2 Homebrew Cask

`tap/Casks/myna.rb`:

```ruby
cask "myna" do
  version "0.1.0"
  sha256 "..." # set by release.yml

  url "https://github.com/#{user}/myna/releases/download/v#{version}/Myna-#{version}.dmg"
  name "Myna"
  desc "Always-on local TTS companion for macOS"
  homepage "https://github.com/#{user}/myna"

  auto_updates true   # defer to Sparkle, don't fight it

  depends_on macos: ">= :ventura"
  depends_on formula: "myna-daemon"

  app "Myna.app"

  zap trash: [
    "~/Library/Application Support/Myna",
    "~/Library/Caches/Myna",
    "~/Library/Logs/Myna",
    "~/Library/Preferences/dev.myna.app.plist",
  ]
end
```

`tap/Formula/myna-daemon.rb` — installs the Python daemon + LaunchAgent. Existing `install.sh` logic ported into a brew formula.

Users: `brew tap <owner>/myna && brew install --cask myna`. Daemon comes along as a dependency.

### 12.3 GitHub release flow

```
git tag v0.1.0
git push --tags
  ↓ triggers .github/workflows/release.yml:
    - build universal binary (arm64 + x86_64)
    - sign with Developer ID
    - notarize via notarytool
    - staple
    - build .dmg with background image
    - sign .dmg
    - sparkle sign_update → appcast entry
    - create GH release, attach .dmg
    - update appcast.xml in releases/download/appcast/
    - bump cask sha256, commit to tap/
```

One tag → fully distributed release. No human in the loop after secrets are set.

## 13. Permissions model

| Permission | Why | Prompt timing | Failure mode |
|---|---|---|---|
| Accessibility | `CGEvent.post` for Cmd+C simulation; hotkeys also benefit | First hotkey use | Alert + "Open System Settings" button |
| Automation (Chrome) | AppleScript URL grab | First `read-chrome` use | Alert + "Open System Settings" button |
| Notifications | Optional, for "speech complete" / "engine down" toasts | Settings → enable | Silent fallback |
| Microphone | NOT NEEDED | — | — |
| Camera | NOT NEEDED | — | — |
| Network | local-only; no entitlement needed for outgoing localhost | — | — |

App is **not** sandboxed (App Store sandbox would block CGEvent.post). Hardened runtime is enabled (required for notarization) with these entitlements:

```xml
<key>com.apple.security.cs.allow-jit</key>                <false/>
<key>com.apple.security.cs.allow-unsigned-executable-memory</key> <false/>
<key>com.apple.security.cs.disable-library-validation</key>      <false/>
<key>com.apple.security.cs.disable-executable-page-protection</key> <false/>
<key>com.apple.security.automation.apple-events</key>            <true/>
```

Accessibility is not an entitlement — it's a TCC permission requested at runtime via `AXIsProcessTrustedWithOptions`.

## 14. Migration & coexistence with v1

For the duration of v0.x:

- v1 Hammerspoon script keeps working.
- v2 Myna.app talks to the same daemon on the same port (8766).
- Both can run simultaneously. They'll both register hotkeys — second registration wins; user picks one or the other in practice.
- The daemon's `Player` is **kept** (not deleted) until v1 users have migrated. New `/synthesize` endpoint is purely additive.
- README adds a "v1 (Hammerspoon) vs v2 (Native)" section guiding users which to install.

v1 deprecation timeline: 6 months after v2.0 ships, the Hammerspoon script + daemon's `Player` move to `legacy/`.

## 15. Risks & honest tradeoffs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| First-time notarization fails (cert/keychain dance) | High | Blocks release | Document the manual one-time setup; have the CI workflow log clearly |
| Accessibility prompt confuses users | Medium | Bad first-run UX | Onboarding sheet on first launch explains; "Open System Settings" deep link |
| `AVAudioUnitTimePitch` artifacts at high rates | Low | Cosmetic | Cap at 2.0× (matches Overcast, Books) |
| Sparkle EdDSA key lost | Low if backed up | Users can never auto-update again | Store in 1Password + GH Actions secret; document |
| Apple changes notarization API | Low | CI breaks | Pin `notarytool` version; release.yml has manual fallback path |
| Homebrew cask + Sparkle update collision | Medium | User confusion | `auto_updates true` in cask defers to Sparkle |
| Daemon down → app hangs on first speak | Medium | Bad UX | DaemonClient has 2s health check before speak; toast on failure |
| Kokoro down → daemon returns 502 | Medium | Same | DaemonClient surfaces engine status from `/v2/status` to the menu |

## 16. Phased roadmap (build order)

**Phase 0 — Spec & skeleton** *(orchestrator, sequential)*
- This doc, API_CONTRACT.md, TEST_PLAN.md
- XcodeGen project.yml + Info.plist + entitlements + minimal "Hello, MenuBar" build

**Phase 1 — Three parallel lanes, against locked spec** *(opus leads + sonnet workers)*
- Lane A: App Core implementation
- Lane B: Release pipeline scaffolding
- Lane C: Daemon `/synthesize` + `/v2/status`

**Phase 2 — Audit gates** *(independent opus auditors)*
- Code review (every lane)
- Security review
- Verification (real app launch, real speak, real seek)

**Phase 3 — Integration + STATUS.md morning briefing**

**Future (post-overnight):**
- v0.2: Settings UI polish, voice picker queries daemon, in-app log viewer
- v0.3: BTT integration docs + ready-made BTT preset file
- v0.4: First real release: notarization secrets, cask published, Sparkle live
- v1.0: Public launch (HN, r/macapps, Product Hunt)
- v2.0: Port daemon to Swift; ship single-binary .app; deprecate Python dependency

## 17. Success criteria for v0.1 (overnight target)

A v0.1 ships if all true:

- [ ] Myna.app builds from `apps/macos/project.yml` with one command
- [ ] Menu bar icon renders; menu opens; daemon status shows
- [ ] Five default hotkeys registered; recorder works
- [ ] `speak_selection_full` works end-to-end with real Kokoro daemon
- [ ] Playback supports pause/resume/stop, speed change (no pitch shift), seek ±15s
- [ ] `myna://` URL scheme handles `speak-selection`, `toggle-pause`, `seek`, `speed`
- [ ] Sparkle integration code present (appcast URL placeholder)
- [ ] GitHub Actions workflows present (build/test green; sign/notarize stubs with TODO for secrets)
- [ ] Homebrew cask template present in `tap/`
- [ ] Daemon `/synthesize` returns raw WAV; all v1 tests still pass; new tests for new endpoint pass
- [ ] All Swift code passes SwiftLint
- [ ] STATUS.md morning briefing exists, listing what's done, what's stubbed, what needs Rashid's input
