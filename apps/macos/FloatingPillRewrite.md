# FloatingPill — Complete Rewrite (design + build log)

Branch: `feat/floating-pill`. Single branch, sequential steps, no worktrees.
Scope: rewrite `apps/macos/Sources/FloatingPill/**`. Do **not** touch `Sources/Audio/**`.
Add surgical plumbing in `AppDispatcher`, `MynaApp`, `AppDelegate`, `MenuBarController`.

**Core invariant (must survive):** the panel never becomes key/main and never steals
focus from the user's editor (`FloatingPillWindow.canBecomeKey/Main = false`).

## Resolved decisions (owner-confirmed 2026-06-14)
1. **Claude-output "Play"** → route in-process via `AppDispatcher.synthesizeAndPlay(text: item.title)`
   so the pill's transport controls it and audio comes from the same sink. The registry only
   stores `title` (daemon `app.py:849`), so this is the same content the top-right toast already
   spoke — no regression. Enriching the hook payload is a separate task.
2. **Top-right CCToast** → suppress the standalone toast window; render the prompt **in the pill**.
   Keep the existing dedupe + Focus-mode gating logic in `MenuBarController`.
3. **Transcripts** → show last 5 (`recents` ring) in the expanded+pinned view; tap a row → re-speak.
4. **Wiring** → extend `PillController.attach(player:settings:)` → `+ menuController:` (Option A).

## State model
Single FSM. `enum PillLayout { hidden, collapsedIdle, processing, collapsedPlaying, expanded, promptCTA }`.
Modifiers (orthogonal): `isHovering` (NSTrackingArea), `isPinned` (background tap), `alwaysVisible` (setting), `promptForcesExpand`.

Resolution precedence (highest first):
```
!enabled                         → hidden
hasPromptCTA                     → expanded + promptCTA overlay (auto-expand, doesn't set isPinned)
isPinned || isHovering           → expanded
isLoading                        → processing        (collapsed footprint)
playing || paused                → collapsedPlaying
alwaysVisible                    → collapsedIdle
else                             → hidden
```

Hover-out debounce: **600ms**, via NSTrackingArea (`.mouseEnteredAndExited, .inVisibleRect, .activeAlways`)
+ a cancellable `DispatchWorkItem` (NOT SwiftUI `.onHover` + Task.sleep — `.onHover` drops
`mouseExited` at high cursor velocity). Re-entry cancels the pending collapse. `isPinned` and a
pending `promptCTA` suppress the timer entirely.

## Window & rendering
Keep the NSPanel recipe in `FloatingPillWindow` **except**: drop `.hudWindow` from styleMask
(its system HUD vibrancy fights a custom material). Non-activation comes from `.nonactivatingPanel`
+ the `canBecomeKey/Main=false` overrides. Keep `.canJoinAllSpaces, .fullScreenAuxiliary,
.stationary, .ignoresCycle`. Show via `orderFrontRegardless()`, never `makeKeyAndOrderFront`.
SwiftUI in `NSHostingView<PillView>`; drive panel frame off `hostingView.fittingSize`.
Expand/collapse = SwiftUI `spring(response:0.30, dampingFraction:0.82)` + matched window-frame
`NSAnimationContext` duration **0.28** easeOut. Waveform via existing `CAReplicatorLayer` (NOT
`TimelineView` — prior 99.5% CPU bug). Processing = determinate CA shimmer.

## Positioning (fixes the off-screen strand)
Retire `setFrameAutosaveName` (persists absolute origin → stranded at -942,1144). Persist instead:
`displayID: CGDirectDisplayID` (from `screen.deviceDescription["NSScreenNumber"]`), `fx`, `fy`
(fractional offset within `visibleFrame`). Restore: find screen by displayID (fallback cursor
screen), `origin = (vf.minX + fx*vf.width, vf.minY + fy*vf.height)`, then **clamp to visibleFrame
on every setFrame**:
```
r.origin.x = min(max(r.minX, vf.minX+m), vf.maxX - r.width - m)   // m = 8
r.origin.y = min(max(r.minY, vf.minY+m), vf.maxY - r.height - m)
```
Keep `screenForCursor` (cursor-based, unit-tested). Keep `bottomCenterFrame`. Expand grows UPWARD:
hold `origin.y`, re-center X, one atomic clamped `setFrame`. Debounce
`didChangeScreenParametersNotification` 200ms (sleep/wake storms). Only persist when frame passes
`isFrameOnAnyScreen` (≥80%). `resetPosition()` clears BOTH legacy autosave keys AND new anchor keys.

## Integration (verified file:line)
- Playback state: `AudioPlayer.$state`, `.$isLoading`, `.position`, `.duration`; transport
  `pause()/resume()/stop()/seek(to:)/seek(delta:)/setSpeed(_:)`.
- Processing: key off `player.isLoading` (set `AppDispatcher.swift:127` guarded by speakGeneration;
  cleared in `AudioPlayer.beginSession`). Do NOT invent a new flag.
- Now-playing text/voice: `PillBridge.shared.currentText/currentVoice` (pushed `AppDispatcher.swift:158`).
- Claude prompt: observe `MenuBarController.$ccPending: [RegistryV2Item]` (`:44`, fed by `/v2/registry/list`
  poll `:151`). Play → `synthesizeAndPlay(text: item.title)`. Dismiss → `MenuBarController.discard(item:)` (`:325`).
  Suppress top-right toast presentation. Auto-dismiss 8s.
- Transcripts: observe `MenuBarController.$recents: [RecentItem]` (`:52`, 5-item ring `RecentItem.swift`).
  Tap → re-speak: complete the DEAD `.mynaReplayRecent` wire (`MenuBarController.swift:274` posts it,
  nothing observes) — add observer in `AppDispatcher` → `synthesizeAndPlay(text:)`.
- DI: `attach(player:settings:menuController:)`; update both call sites `MynaApp.swift:97-98,154-155`;
  `MenuBarController` built `AppDelegate.swift:110`.
- Preserve: `resetPositionNotification` name (`:52`), settings keys `dev.myna.app.showFloatingPill`
  + `pillAlwaysVisible`, `PillController.init()/attach/start/stop` lifecycle shape (attach gains a param).

## File plan (`Sources/FloatingPill/`)
- REWRITE: `PillView.swift`, `PillViewModel.swift`.
- KEEP+edit: `FloatingPillWindow.swift` (drop .hudWindow, retire autosave, host NSTrackingArea),
  `PillController.swift` (anchor persistence, +menuController, screen debounce, animate expand).
- NEW: `PillState.swift` (FSM enum + pure resolver), `PillAnchorStore.swift` (anchor persist+clamp),
  `PillTrackingView.swift` (NSView owning NSTrackingArea → onHoverChange),
  `PillContent/` SwiftUI subviews (CollapsedChip, ExpandedPlayer, ProcessingChip, PromptCTA,
  TranscriptList, WaveformView).
- KEEP: `PillBridge.swift` (currentText/voice only).

## Visual spec
Collapsed: height 36, radius 18 capsule, `.ultraThinMaterial` + black 0.30 overlay, shadow r16 y6,
bird 24, text 13-15. idle=bird+"Myna"; processing=bird+"Processing…"+shimmer; playing=bird+status+waveform.
Expanded ~320-360 wide, grows upward: headline / voice chip + waveform / scrubber (mm:ss) / transport
(⏮10 ▶⏸ 10⏭ speed[1×/1.25×/1.5×/2×] ✕) / transcript list (pinned only, 5 rows `voice · age · "title…"`).
PromptCTA: accent dot + "New output — Play?" + preview + [▶ Play][Dismiss], auto-dismiss 8s, in-pill only.
macOS 26: gate `NSGlassEffectView` (Tinted) behind `if #available(macOS 26,*)`, else `.ultraThinMaterial`.

## Build order (each step compiles + is verifiable)
1. Drop `.hudWindow`; retire autosave. Pill shows bottom-center always; no off-screen strand. [foundation]
2. `PillAnchorStore` + clamp-on-restore + persist on drag-end. Drag→relaunch restores; unplug re-snaps.
3. `PillState` enum + pure resolver; VM exposes single `layout`. Unit-test resolver table.
4. NSTrackingArea hover + 600ms DispatchWorkItem debounce. No flicker on fast flick; pinned never collapses.
5. Rewrite collapsed+expanded SwiftUI + WaveformView; matched spring + NSAnimationContext expand-upward.
6. Scrubber + speed + honest ±10s seek; delete skipToNextChunk hack. Drives AudioPlayer.
7. Transcript list (pinned) from `$recents` + `.mynaReplayRecent` observer in AppDispatcher (live the dead wire).
8. In-pill CC prompt from `$ccPending`; Play→in-process; Dismiss→discard; 8s; suppress top-right toast.
9. Screen-change 200ms debounce; macOS 26 glass gate; resetPosition clears legacy+new keys.
10. Test sweep: keep FloatingPillWindowTrackTests/PillControllerScreenTests/PillSettingsTests + new anchor/resolver tests.
