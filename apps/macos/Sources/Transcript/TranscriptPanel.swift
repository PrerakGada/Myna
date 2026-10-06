// TranscriptPanel.swift — the floating window that shows the read's text.
//
// Why a panel of its own and not a bigger pill: the pill is a hover HUD. Its
// layout machine collapses it 600 ms after the cursor leaves, and it sits in
// a 340-point strip at the bottom of the screen, while a transcript is
// something you read for minutes, scroll, and resize. The pill (and the
// Dashboard's now-playing strip) get a button that opens this panel instead.
//
// Like the pill it is a non-activating NSPanel that never becomes key, so
// clicking a sentence plays from it without pulling focus from the app the
// user is reading in. Unlike the pill it has a title bar: it can be moved,
// resized and closed like any window, and AppKit remembers its frame.
import AppKit
import SwiftUI

/// Remembers when the user last scrolled the transcript by hand, so
/// auto-scroll can hold off. Plain class: views read it when the lit
/// sentence changes; nothing re-renders because of it.
@MainActor
final class TranscriptScrollState {
    /// How long auto-scroll waits after the user scrolls by hand.
    static let manualHold: TimeInterval = 4
    private(set) var lastManualScroll: Date = .distantPast

    func noteManualScroll(at date: Date = Date()) { lastManualScroll = date }

    func followsPlayback(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(lastManualScroll) >= Self.manualHold
    }
}

@MainActor
public final class TranscriptPanelController {
    public static let shared = TranscriptPanelController()

    static let frameAutosaveName = "dev.myna.app.transcriptPanel"
    static let defaultSize = NSSize(width: 420, height: 540)

    let store: TranscriptStore
    private let scrollState = TranscriptScrollState()
    private var panel: TranscriptPanel?

    init(store: TranscriptStore = .shared) {
        self.store = store
    }

    /// Called once from AppDelegate.bootstrap: follow the app's player and
    /// open by itself when the Reading pane says so.
    public func install(player: AudioPlayer) {
        store.attach(player: player)
        store.onAutoOpen = { [weak self] in self?.show() }
    }

    public var isOpen: Bool { panel?.isVisible ?? false }

    /// Show the panel without activating Myna. Does nothing when the
    /// Reading pane has the transcript off.
    public func show() {
        guard TranscriptVisibility.current() != .off else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.orderFrontRegardless()
    }

    public func toggle() {
        if isOpen { close() } else { show() }
    }

    public func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> TranscriptPanel {
        let root = TranscriptPanelView(store: store, scroll: scrollState)
        let panel = TranscriptPanel(root: root, size: Self.defaultSize)
        let state = scrollState
        panel.onManualScroll = { state.noteManualScroll() }
        let restored = panel.setFrameAutosaveName(Self.frameAutosaveName)
            && UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") != nil
        // A saved frame on a display that has since gone away would strand
        // the panel off-screen (the pill had exactly that bug), so only keep
        // one that is still on some screen.
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !restored || !onScreen {
            place(panel)
        }
        return panel
    }

    /// Top-right of the screen with the mouse: out of the way of the text
    /// being read, which is usually centred or on the left.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            panel.center()
            return
        }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24))
    }
}

/// The window. Never key, never main: see the file header.
final class TranscriptPanel: NSPanel {
    /// The user scrolled (wheel, trackpad or scroller drag).
    var onManualScroll: (@MainActor () -> Void)?

    init<Root: View>(root: Root, size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Transcript"
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        backgroundColor = NSColor(DashboardDesign.surface)
        isFloatingPanel = true
        level = .floating
        // NSPanel hides when its app deactivates, and Myna is almost never
        // the active app. Stay up.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // The controller keeps it and reuses it across close/open.
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 300, height: 260)
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Every event for this window passes here on the main thread, which
    /// is the one reliable place to see a hand scroll on macOS 13 (SwiftUI's
    /// scroll-phase APIs start at macOS 15).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel || event.type == .leftMouseDragged {
            onManualScroll?()
        }
        super.sendEvent(event)
    }
}
