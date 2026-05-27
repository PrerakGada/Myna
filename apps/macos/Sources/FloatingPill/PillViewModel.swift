// PillViewModel.swift — the @MainActor ObservableObject that bridges
// AudioPlayer state and the SwiftUI pill view.
//
// Owns:
//   - derived `isSpeaking` (folds AudioPlayer's playing/paused into a
//     single "the pill should be visible" boolean)
//   - expand/collapse + pin state (hover, click-to-pin, dismiss)
//   - "voice label" (sourced from PillBridge first, then SettingsViewModel)
//   - "preview text" (sourced from PillBridge; nil otherwise)
//
// Does NOT own the NSPanel — that's PillController's job. The split
// keeps the view model trivially previewable in SwiftUI (no AppKit
// dependency in this file beyond `import AppKit` for nothing).
import Combine
import Foundation
import SwiftUI

@MainActor
public final class PillViewModel: ObservableObject {
    // MARK: - upstream sources

    private let player: AudioPlayer
    private let settings: SettingsViewModel
    private let bridge: PillBridge

    // MARK: - published UI state

    /// True when AudioPlayer.state is .playing or .paused. Pill is
    /// visible iff this OR `isLoading` is true (and the user has not
    /// turned the feature off in Settings). Pause keeps the pill on
    /// screen so the user can hit play again — disappearing on pause
    /// would be confusing.
    @Published public private(set) var isSpeaking: Bool = false

    /// True when the underlying player is paused (vs actively playing).
    /// Drives the play/pause icon swap in the expanded view.
    @Published public private(set) var isPaused: Bool = false

    /// True from the moment AppDispatcher fires a speak request until
    /// the first audio chunk lands (or the request fails). The pill
    /// shows a tiny "Processing…" affordance with an indeterminate
    /// spinner during this window so the user sees immediate feedback
    /// — without it, the pill only appears 200-300ms after the hotkey,
    /// which reads as "did the gesture register?"
    @Published public private(set) var isLoading: Bool = false

    /// Convenience: pill should be on-screen when either we're loading
    /// or we're actively speaking. Pulled out so PillController can
    /// observe one flag instead of two.
    public var shouldBeVisible: Bool { isLoading || isSpeaking }

    /// True when the pill should render its expanded mini-player.
    /// Driven by hover OR explicit pin (whichever is more permissive).
    @Published public private(set) var isExpanded: Bool = false

    /// User clicked the pill to keep it expanded. Cleared by the close
    /// button or on stop.
    @Published public var isPinned: Bool = false {
        didSet { recomputeExpanded() }
    }

    /// Cursor is currently over the pill. Driven by SwiftUI .onHover.
    @Published public var isHovering: Bool = false {
        didSet { handleHoverChange() }
    }

    /// True when the pill is in "always visible" mode (user toggled
    /// on in Settings). Surfaced so the view can render an idle
    /// state (bird + "Myna" label, no waveform) when nothing is
    /// playing but the pill is still on screen. Set by
    /// PillController.syncVisibility — view-model does not read
    /// UserDefaults directly to keep this file dependency-light.
    @Published public private(set) var isAlwaysVisible: Bool = false

    // MARK: - derived display data

    /// What to show in the pill. May be nil — view falls back to
    /// "Speaking…".
    public var previewText: String? {
        bridge.currentText
    }

    /// Voice label for the chip in expanded mode. Always non-nil.
    public var voiceLabel: String {
        bridge.currentVoice ?? settings.voice
    }

    // MARK: - internals

    private var hoverCollapseTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Hover-out grace period. Wispr Flow uses ~500ms; 600ms feels
    /// forgiving on a small target without making the pill feel sticky.
    private static let hoverCollapseDelay: TimeInterval = 0.6

    public init(player: AudioPlayer, settings: SettingsViewModel, bridge: PillBridge = .shared) {
        self.player = player
        self.settings = settings
        self.bridge = bridge

        #if DEBUG
        // Skip the live subscriptions in preview-only mode so the
        // forced state in #Previews isn't immediately overwritten by
        // the real player's idle state.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            applyPlayerState(player.state)
            isLoading = player.isLoading
            return
        }
        #endif

        // Mirror AudioPlayer.state into our two simpler booleans.
        player.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.applyPlayerState(state)
            }
            .store(in: &cancellables)

        // Mirror the pre-audio loading flag — the dispatcher flips it
        // true the instant a speak request fires (well before any
        // chunk arrives), so this is how the pill achieves the ~50ms
        // visibility budget the spec calls for.
        player.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in
                self?.applyLoading(loading)
            }
            .store(in: &cancellables)

        // Bridge republishes (currentText / voice changing while the
        // pill is up should refresh the view).
        bridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Settings.voice changing while speaking should also refresh
        // the voice label fallback.
        settings.$voice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        applyPlayerState(player.state)
        applyLoading(player.isLoading)
    }

    private func applyLoading(_ loading: Bool) {
        isLoading = loading
    }

    /// True when the pill is on screen but the player is idle. Drives
    /// the "Myna" idle chip layout (no waveform, no Stop button).
    public var isIdle: Bool {
        !isSpeaking
    }

    // MARK: - intents

    /// Push the always-visible flag from PillController. Idempotent;
    /// the @Published wrapper handles change notification.
    public func setAlwaysVisible(_ value: Bool) {
        if isAlwaysVisible != value {
            isAlwaysVisible = value
        }
    }

    /// User clicked Play/Pause in the expanded view.
    public func togglePlayPause() {
        switch player.state {
        case .playing: player.pause()
        case .paused: player.resume()
        case .idle: break
        }
    }

    /// User clicked the Skip button. Advances to the next chunk by
    /// seeking past the current chunk's duration. Best-effort — if
    /// there's no further chunk, seeking past end is harmless
    /// (AudioPlayer clamps).
    public func skipToNextChunk() {
        // The simplest "skip chunk" we can express with the public
        // AudioPlayer surface is to seek forward by the average chunk
        // length. The audio engine schedules chunks contiguously, so
        // jumping ~10s ahead almost always lands in (or past) the
        // next chunk. Tuning this requires AudioPlayer to expose
        // per-chunk durations, which is out of scope here.
        player.seek(delta: 10)
    }

    /// User clicked the × button. Force-collapse and unpin.
    public func dismiss() {
        isPinned = false
        isHovering = false
        recomputeExpanded()
    }

    /// User clicked the pill body to pin/unpin.
    public func togglePin() {
        isPinned.toggle()
    }

    // MARK: - state plumbing

    private func applyPlayerState(_ state: AudioPlayer.State) {
        switch state {
        case .playing:
            isSpeaking = true
            isPaused = false
        case .paused:
            isSpeaking = true
            isPaused = true
        case .idle:
            isSpeaking = false
            isPaused = false
            // Stopping clears pinned & hovering when the pill is
            // going away. In always-visible mode the pill stays on
            // screen, so keeping the user's pin choice would be
            // surprising on the *next* speech session — clear it
            // either way and let hover re-expand if the user wants.
            isPinned = false
            isHovering = false
            recomputeExpanded()
            // Clear the bridge so the next session starts fresh.
            bridge.clear()
        }
    }

    private func handleHoverChange() {
        if isHovering {
            hoverCollapseTask?.cancel()
            hoverCollapseTask = nil
            recomputeExpanded()
        } else {
            // Defer collapse so a fast cursor wiggle doesn't flash
            // the pill collapsed-then-expanded.
            hoverCollapseTask?.cancel()
            hoverCollapseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.hoverCollapseDelay * 1_000_000_000))
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    if !self.isHovering {
                        self.recomputeExpanded()
                    }
                }
            }
        }
    }

    private func recomputeExpanded() {
        let target = isPinned || isHovering
        if target != isExpanded {
            isExpanded = target
        }
    }

    #if DEBUG
    /// Preview-only escape hatch. Not for production code paths.
    /// Forces published booleans so SwiftUI previews can render a
    /// specific visual state without driving the real AudioPlayer.
    public func _previewForceState(
        isSpeaking: Bool,
        isExpanded: Bool,
        paused: Bool,
        alwaysVisible: Bool = false,
        loading: Bool = false
    ) {
        self.isSpeaking = isSpeaking
        self.isExpanded = isExpanded
        self.isPaused = paused
        self.isAlwaysVisible = alwaysVisible
        self.isLoading = loading
    }
    #endif
}
