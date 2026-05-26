// PanelController.swift — floating NSPanel + NSTextView ribbon.
//
// Renders the karaoke ribbon: 80% screen width, 56pt tall, 64pt from the
// bottom of NSScreen.main. Active word bold/white; surrounding sentence
// dim grey. Fades out 1s after stop or last word.
//
// All methods are main-thread-only (AppKit). SocketListener pushes work
// across the main queue before calling these.

#if canImport(AppKit)
import AppKit

@MainActor
public final class PanelController {
    public private(set) var panel: NSPanel?
    private var textView: NSTextView?
    private var fadeTimer: Timer?

    /// Currently rendering this utterance ID. Word events for any other ID
    /// are discarded as stale.
    public private(set) var currentUtteranceID: String?
    /// Words for the current utterance (from start), in order.
    private var currentWords: [String] = []
    /// Highlight index. -1 = nothing highlighted yet (just the dim sentence).
    private var activeIndex: Int = -1
    /// Paused state — purely cosmetic for now (no rendering change).
    private var paused = false

    /// Live configuration. Defaults from Tier 1 brief.
    public var config = RibbonConfig.default

    public init() {}

    /// Called from main.swift on app activation, OR lazily on first start
    /// message. Idempotent.
    public func ensurePanel() {
        if panel != nil { return }
        guard let screen = NSScreen.main else { return }

        let panelWidth = floor(screen.frame.width * 0.8)
        let panelHeight: CGFloat = 56
        let xOrigin = screen.frame.minX + (screen.frame.width - panelWidth) / 2
        let yOrigin = screen.frame.minY + 64
        let frame = NSRect(x: xOrigin, y: yOrigin, width: panelWidth, height: panelHeight)

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.alphaValue = 0.0

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(
            red: 20.0 / 255.0,
            green: 20.0 / 255.0,
            blue: 22.0 / 255.0,
            alpha: 0.94
        ).cgColor
        container.layer?.cornerRadius = 14
        container.layer?.masksToBounds = true

        let tv = NSTextView(frame: container.bounds.insetBy(dx: 24, dy: 12))
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = false
        tv.isSelectable = false
        tv.drawsBackground = false
        tv.textContainer?.lineBreakMode = .byTruncatingTail
        tv.textContainer?.maximumNumberOfLines = 1
        tv.alignment = .center

        container.addSubview(tv)
        p.contentView = container

        self.panel = p
        self.textView = tv
    }

    // MARK: - Public handlers (called from main, dispatched from socket thread)

    public func handle(_ message: IncomingMessage) {
        switch message {
        case .start(let start):  handleStart(start)
        case .word(let word):    handleWord(word)
        case .pause:             paused = true
        case .resume:            paused = false
        case .stop:              handleStop()
        case .config(let c):     applyConfig(c)
        case .unknown:           break    // intentionally ignored
        }
    }

    private func handleStart(_ start: StartMessage) {
        ensurePanel()
        cancelFade()
        currentUtteranceID = start.id
        currentWords = start.words.map(\.t)
        activeIndex = -1
        paused = false
        renderText()
        showPanel()
    }

    private func handleWord(_ word: WordMessage) {
        // Discard stale word events from earlier utterances.
        guard word.id == currentUtteranceID else { return }
        guard word.i >= 0 && word.i < currentWords.count else { return }
        activeIndex = word.i
        renderText()
    }

    private func handleStop() {
        scheduleFade()
    }

    private func applyConfig(_ c: ConfigMessage) {
        config = RibbonConfig(
            fontSize: CGFloat(c.fontSize),
            position: RibbonConfig.Position(rawValue: c.position) ?? config.position,
            theme: RibbonConfig.Theme(rawValue: c.theme) ?? config.theme,
            opacity: c.opacity
        )
        // For Tier 1 we don't actively re-layout. The config is captured so
        // the next ensurePanel/renderText picks it up. Live reload is Tier 1.5.
    }

    // MARK: - Rendering

    public func attributedSentence() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: config.fontSize, weight: .semibold)
        let dim = NSColor(white: 1.0, alpha: 0.55)
        let active = NSColor.white

        let result = NSMutableAttributedString()
        for (idx, word) in currentWords.enumerated() {
            if idx > 0 { result.append(NSAttributedString(string: " ")) }
            let color: NSColor = (idx == activeIndex) ? active : dim
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            result.append(NSAttributedString(string: word, attributes: attrs))
        }
        return result
    }

    private func renderText() {
        guard let textView else { return }
        textView.textStorage?.setAttributedString(attributedSentence())
    }

    // MARK: - Show / fade

    private func showPanel() {
        guard let panel else { return }
        cancelFade()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    private func scheduleFade() {
        cancelFade()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeOut() }
        }
    }

    private func cancelFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.orderOut(nil)
                self?.currentUtteranceID = nil
                self?.currentWords = []
                self?.activeIndex = -1
            }
        })
    }
}

public struct RibbonConfig: Equatable, Sendable {
    public var fontSize: CGFloat
    public var position: Position
    public var theme: Theme
    public var opacity: Double

    public enum Position: String, Sendable {
        case bottom, top, middle
    }

    public enum Theme: String, Sendable {
        case dark, light
    }

    public static let `default` = RibbonConfig(
        fontSize: 18,
        position: .bottom,
        theme: .dark,
        opacity: 0.94
    )
}

#else
// Non-AppKit shim — present so MynaKaraokeCore can compile on linux for tests
// IF tests ever run there. (They don't today; sidecar is macOS-only.)
import Foundation

public struct RibbonConfig: Equatable, Sendable {
    public var fontSize: Double
    public var position: Position
    public var theme: Theme
    public var opacity: Double

    public enum Position: String, Sendable { case bottom, top, middle }
    public enum Theme: String, Sendable { case dark, light }

    public static let `default` = RibbonConfig(
        fontSize: 18, position: .bottom, theme: .dark, opacity: 0.94
    )
}
#endif
