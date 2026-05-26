// CCToastWindow.swift — borderless NSPanel showing the "audio ready"
// toast for a single Claude Code stop-hook event (S08).
//
// Per Sally's spec (03-ux-direction.md § 5):
//   • ~340×80, top-right of the active display (12px from edge,
//     8px below menu bar)
//   • NSPanel.nonactivatingPanel, becomesKeyOnlyIfNeeded=true, canBecomeKey=false
//   • Soft slide-in 220ms ease-out (when low-power isn't suppressing motion)
//   • Background `rgba(28,28,30,0.92)` + 1px `rgba(255,255,255,0.08)` stroke
//     (NOT frosted blur — per Caravaggio's veto in 04-visual-direction.md § 6)
//   • Project-colored dot via ProjectPalette
//   • Auto-dismiss to menu-bar submenu after 8s; hovering pauses the timer
//   • Up to 3 stacked vertically, 8px gap; CCToastController manages stack
//   • Respects DND/Focus mode (caller checks before constructing)
import AppKit
import SwiftUI

@MainActor
public final class CCToastWindow: NSPanel {
    /// Compile-time layout. Edits here require eyeball-check on a real bar.
    public static let toastWidth: CGFloat = 340
    public static let toastHeight: CGFloat = 80
    public static let margin: CGFloat = 12
    public static let menuBarOffset: CGFloat = 8
    /// 8px gap between stacked toasts, per Sally.
    public static let stackGap: CGFloat = 8

    public let item: RegistryV2Item

    /// Called when the user clicks Play. The controller swaps the toast
    /// out and posts the play call.
    public var onPlay: (() -> Void)?
    /// Called when the user clicks Later (or hits Esc). Removes the
    /// toast UI and keeps the item in the menu-bar submenu.
    public var onLater: (() -> Void)?
    /// Called when the user clicks ✕ Dismiss (or the toast auto-dismisses
    /// to the submenu after timeout). The controller routes this differently
    /// depending on whether the user explicitly discarded or the timer fired.
    public var onDismiss: ((DismissReason) -> Void)?

    public enum DismissReason: Sendable {
        case timeout  // moved to submenu; NOT discarded
        case userDiscard  // ✕ pressed; "Audio discarded · Undo" chip 4s
        case userLater  // Later / Esc
    }

    public init(item: RegistryV2Item) {
        self.item = item
        let frame = Self.targetFrame(on: NSScreen.main ?? NSScreen.screens.first, stackIndex: 0)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        installContentView()
    }

    /// Compute the top-right anchor for the i-th stacked toast on the
    /// given screen. The 0th toast is the newest; toast N sits
    /// `N * (toastHeight + stackGap)` below the 0th.
    public static func targetFrame(on screen: NSScreen?, stackIndex: Int) -> NSRect {
        guard let screen else {
            return NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight)
        }
        let visible = screen.visibleFrame
        let originX = visible.maxX - toastWidth - margin
        let topY = visible.maxY - menuBarOffset
        let yOffset = CGFloat(stackIndex) * (toastHeight + stackGap)
        let originY = topY - toastHeight - yOffset
        return NSRect(x: originX, y: originY, width: toastWidth, height: toastHeight)
    }

    /// Re-anchor to a new stack index without rebuilding the content view.
    public func updateStackIndex(_ index: Int, on screen: NSScreen?) {
        let target = Self.targetFrame(on: screen, stackIndex: index)
        animator().setFrame(target, display: true, animate: true)
    }

    /// Slide the window in from above its target position by `slideDistance`
    /// over `animationDuration` seconds. Pass `animated: false` to skip
    /// (used when PowerMonitor flags low-power mode).
    public func showAnimated(animated: Bool = true) {
        let target = frame
        if animated {
            // Start above the target by 24pt; animate to target.
            let startY = target.origin.y + 24
            self.setFrameOrigin(NSPoint(x: target.origin.x, y: startY))
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(target, display: true)
                self.animator().alphaValue = 1.0
            }
        } else {
            alphaValue = 1.0
            orderFrontRegardless()
        }
    }

    public func dismissAnimated() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.orderOut(nil)
            }
        }
    }

    // MARK: - private

    private func configurePanel() {
        isFloatingPanel = true
        level = .floating
        // No focus stealing. EVER. canBecomeKey is overridden below.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = NSColor.clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    private func installContentView() {
        let host = NSHostingView(
            rootView: CCToastContent(
                item: item,
                onPlay: { [weak self] in self?.onPlay?() },
                onLater: { [weak self] in self?.onLater?() },
                onDismiss: { [weak self] reason in self?.onDismiss?(reason) }
            ))
        host.frame = NSRect(origin: .zero, size: NSSize(width: Self.toastWidth, height: Self.toastHeight))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    // NSPanel override — never become key. This is the focus-stealing
    // guard called out in Sally's spec.
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// The SwiftUI body of a single toast. Pure-display; all callbacks
/// surface back into CCToastWindow/Controller.
struct CCToastContent: View {
    let item: RegistryV2Item
    let onPlay: () -> Void
    let onLater: () -> Void
    let onDismiss: (CCToastWindow.DismissReason) -> Void

    @State private var elapsed: TimeInterval = 0
    @State private var hovered: Bool = false
    /// 8.0 seconds total countdown per Sally; pauses on hover.
    private let totalDuration: TimeInterval = 8.0

    var body: some View {
        ZStack {
            background
            HStack(spacing: 10) {
                projectDot
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.projectId)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(item.ageSeconds() < 30 ? "Just now" : "\(item.ageSeconds())s")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            onDismiss(.userDiscard)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                    Text(item.preview())
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    HStack(spacing: 12) {
                        Button("▶ Play", action: onPlay)
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                            .font(.system(size: 11, weight: .semibold))
                        Button("Later", action: onLater)
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.85))
                            .font(.system(size: 11))
                        Button("Dismiss") { onDismiss(.userDiscard) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.7))
                            .font(.system(size: 11))
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            VStack {
                Spacer()
                progressBar
            }
        }
        .frame(width: CCToastWindow.toastWidth, height: CCToastWindow.toastHeight)
        .onHover { hovered = $0 }
        .onAppear { startTimer() }
        .onTapGesture { onPlay() }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 12)
            // rgba(28,28,30,0.92) per spec — solid + alpha, NOT frosted blur.
            .fill(Color(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0).opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var projectDot: some View {
        let palette = ProjectPalette.color(for: item.projectId)
        return ZStack {
            Circle()
                .fill(Color(palette: palette))
                .frame(width: 10, height: 10)
            Circle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: 8, height: 8)
        }
        .accessibilityLabel("Project \(item.projectId), color \(palette.name)")
    }

    private var progressBar: some View {
        GeometryReader { geom in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 2)
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: max(0, geom.size.width * (1 - elapsed / totalDuration)), height: 2)
            }
        }
        .frame(height: 2)
    }

    private func startTimer() {
        // We can't reach across the Timer's nonisolated callback into the
        // SwiftUI @State value directly under Swift 6 strict concurrency;
        // instead we use a recursive Task-sleep loop on @MainActor.
        Task { @MainActor in
            while elapsed < totalDuration {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if !hovered {
                    elapsed += 0.1
                }
            }
            onDismiss(.timeout)
        }
    }
}
