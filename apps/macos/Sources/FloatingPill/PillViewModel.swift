// PillViewModel.swift — the @MainActor ObservableObject that bridges
// AudioPlayer state to the SwiftUI pill.
//
// Owns the orthogonal *inputs* (player playing/paused, pre-audio loading,
// hover, pin, always-visible, and — from Step 8 — a pending Claude-output
// prompt) and derives a single `layout` from them via the pure resolver in
// PillState.swift. The view switches on `layout` instead of juggling a pile
// of booleans.
//
// Hover *debounce* lives in PillController (it owns the NSTrackingArea); this
// view-model just records the hover bool via `setHovering`. It does NOT own
// the NSPanel — that's PillController's job — which keeps it previewable.
import Combine
import Foundation
import SwiftUI

@MainActor
public final class PillViewModel: ObservableObject {
    // MARK: - upstream

    private let player: AudioPlayer
    private let settings: SettingsViewModel
    private let bridge: PillBridge
    /// MenuBarController supplies the recents ring + the replay hook. Weak —
    /// it's an app-lifetime singleton the pill doesn't own. Optional so tests
    /// and previews can construct the view-model without a menu bar.
    private weak var menuController: MenuBarController?

    // MARK: - inputs (each change recomputes `layout`)

    /// AudioPlayer.state is .playing or .paused (the pill should be visible).
    @Published public private(set) var isSpeaking: Bool = false
    /// Player is paused (drives the play/pause icon swap).
    @Published public private(set) var isPaused: Bool = false
    /// Pre-audio loading window (drives "Processing…"). Set by the dispatcher
    /// the instant a speak fires; cleared by AudioPlayer at first audio/stop.
    @Published public private(set) var isLoading: Bool = false
    /// "Always visible" setting — pill renders an idle chip when nothing plays.
    @Published public private(set) var isAlwaysVisible: Bool = false
    /// Cursor is over the pill (set by PillController from the NSTrackingArea,
    /// after the hover-out debounce).
    @Published public private(set) var isHovering: Bool = false
    /// User pinned the pill open (background tap).
    @Published public private(set) var isPinned: Bool = false
    /// A pending Claude-output prompt is awaiting the user (wired in Step 8).
    @Published public private(set) var hasPrompt: Bool = false

    // MARK: - derived

    /// The single layout the pill renders, recomputed from the inputs by the
    /// pure resolver whenever any input changes. PillView switches on this and
    /// PillController observes it to resize/animate the panel.
    @Published public private(set) var layout: PillLayout = .hidden

    // MARK: - playback progress (drives the expanded scrubber + speed)

    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var speed: Double = 1.0

    /// Last few reads (newest first), mirrored from MenuBarController. Shown
    /// in the expanded+pinned view; tap a row to re-speak it.
    @Published public private(set) var recents: [RecentItem] = []

    /// Pending Claude-output prompt to surface in-pill (the newest unhandled
    /// CC registry item). PillController owns the dedup/handled bookkeeping
    /// and pushes the current value here via setPrompt.
    @Published public private(set) var pendingPrompt: RegistryV2Item?

    /// Set by PillController so the prompt buttons route through its handled-id
    /// bookkeeping (and the in-process synth for Play).
    public var onPlayPrompt: ((RegistryV2Item) -> Void)?
    public var onDismissPrompt: ((RegistryV2Item) -> Void)?

    // MARK: - display data

    /// Headline / preview text the dispatcher asked Myna to speak. May be nil.
    public var previewText: String? { bridge.currentText }

    /// Voice label for the chip. Always non-nil.
    public var voiceLabel: String { bridge.currentVoice ?? settings.voice }

    // MARK: - init

    private var cancellables = Set<AnyCancellable>()

    public init(
        player: AudioPlayer,
        settings: SettingsViewModel,
        bridge: PillBridge = .shared,
        menuController: MenuBarController? = nil
    ) {
        self.player = player
        self.settings = settings
        self.bridge = bridge
        self.menuController = menuController

        #if DEBUG
        // In preview-only mode skip live subscriptions so the forced state in
        // #Previews isn't immediately overwritten by the real idle player.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            applyPlayerState(player.state)
            isLoading = player.isLoading
            refreshLayout()
            return
        }
        #endif

        player.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyPlayerState(state) }
            .store(in: &cancellables)

        player.$isLoading
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in
                self?.isLoading = loading
                self?.refreshLayout()
            }
            .store(in: &cancellables)

        // Playback progress for the scrubber. These don't affect `layout`,
        // so they don't call refreshLayout — they just refresh the slider.
        player.$position
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.position = p }
            .store(in: &cancellables)
        player.$duration
            .receive(on: RunLoop.main)
            .sink { [weak self] d in self?.duration = d }
            .store(in: &cancellables)
        player.$speed
            .receive(on: RunLoop.main)
            .sink { [weak self] s in self?.speed = s }
            .store(in: &cancellables)

        // Recents ring from the menu bar — drives the pinned transcript list.
        if let menuController {
            recents = menuController.recents
            menuController.$recents
                .receive(on: RunLoop.main)
                .sink { [weak self] r in self?.recents = r }
                .store(in: &cancellables)
        }

        // Republish when the bridge (preview text / voice) or the settings
        // voice changes while the pill is up.
        bridge.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.$voice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        applyPlayerState(player.state)
        isLoading = player.isLoading
        refreshLayout()
    }

    // MARK: - layout resolution

    private func refreshLayout() {
        let next = resolvePillLayout(PillInputs(
            enabled: true,            // PillController gates whether we're shown
            alwaysVisible: isAlwaysVisible,
            isLoading: isLoading,
            isPlaying: isSpeaking,
            isHovering: isHovering,
            isPinned: isPinned,
            hasPrompt: hasPrompt
        ))
        if next != layout { layout = next }
    }

    // MARK: - intents

    /// Push the always-visible flag from PillController.
    public func setAlwaysVisible(_ value: Bool) {
        guard isAlwaysVisible != value else { return }
        isAlwaysVisible = value
        refreshLayout()
    }

    /// Record hover state. PillController calls this from the NSTrackingArea,
    /// having already applied the 600ms hover-out debounce.
    public func setHovering(_ value: Bool) {
        guard isHovering != value else { return }
        isHovering = value
        refreshLayout()
    }

    /// Background tap → pin/unpin the expanded view.
    public func togglePin() {
        isPinned.toggle()
        refreshLayout()
    }

    /// Collapse the expanded pill back to the bar: clear BOTH the pin and the
    /// hover flag so `resolvePillLayout` falls through to a collapsed state.
    /// Shared by the close button and the hover-out auto-collapse — the latter
    /// relies on the pin being cleared here so a click-pinned pill still
    /// collapses when the cursor leaves, instead of staying stuck open until
    /// the user minimises it by hand.
    public func collapse() {
        isPinned = false
        isHovering = false
        refreshLayout()
    }

    /// Close button → collapse and unpin.
    public func dismiss() { collapse() }

    /// Re-speak a recent item (transcript-row tap). Routes through
    /// MenuBarController.replayRecent → .mynaReplayRecent → AppDispatcher,
    /// which re-synthesises through the in-process player.
    public func replay(_ item: RecentItem) {
        menuController?.replayRecent(item)
    }

    /// PillController pushes the current Claude-output prompt (or nil to clear).
    public func setPrompt(_ item: RegistryV2Item?) {
        guard pendingPrompt?.id != item?.id else { return }
        pendingPrompt = item
        hasPrompt = (item != nil)
        refreshLayout()
    }

    /// In-pill prompt buttons — defer to the controller's handlers.
    public func playPrompt() {
        guard let item = pendingPrompt else { return }
        onPlayPrompt?(item)
    }

    public func dismissPrompt() {
        guard let item = pendingPrompt else { return }
        onDismissPrompt?(item)
    }

    /// Play/Pause button.
    public func togglePlayPause() {
        switch player.state {
        case .playing: player.pause()
        case .paused: player.resume()
        case .idle: break
        }
    }

    /// Stop button — ends the session (player goes idle, pill collapses/hides).
    public func stop() {
        player.stop()
    }

    /// Seek to an absolute position in seconds (scrubber commit).
    public func seek(toSeconds seconds: TimeInterval) {
        player.seek(to: seconds)
    }

    /// Skip by a delta in seconds (the ±10s buttons). Positive = forward.
    public func seekBy(_ delta: TimeInterval) {
        player.seek(delta: delta)
    }

    /// Cycle through the playback-speed presets.
    public func cycleSpeed() {
        let idx = Self.speedSteps.firstIndex { abs($0 - speed) < 0.01 } ?? 0
        player.setSpeed(Self.speedSteps[(idx + 1) % Self.speedSteps.count])
    }

    /// Label for the current speed, e.g. "1×", "1.25×", "2×".
    public var speedLabel: String {
        String(format: "%g\u{00D7}", speed)
    }

    private static let speedSteps: [Double] = [1.0, 1.25, 1.5, 2.0]

    // MARK: - player → inputs

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
            // Stopping clears the user's pin/hover so the next session starts
            // collapsed; clear the bridge so stale preview text doesn't show.
            isPinned = false
            isHovering = false
            bridge.clear()
        }
        refreshLayout()
    }

    #if DEBUG
    // swiftlint:disable identifier_name
    /// Preview-only escape hatch. Forces the inputs so SwiftUI previews can
    /// render a specific layout without driving the real AudioPlayer.
    /// `isExpanded` maps to `isPinned` (pin forces the expanded layout).
    public func _previewForceState(
        isSpeaking: Bool,
        isExpanded: Bool,
        paused: Bool,
        alwaysVisible: Bool = false,
        loading: Bool = false
    ) {
        self.isSpeaking = isSpeaking
        self.isPaused = paused
        self.isAlwaysVisible = alwaysVisible
        self.isLoading = loading
        self.isPinned = isExpanded
        refreshLayout()
    }
    // swiftlint:enable identifier_name
    #endif
}
