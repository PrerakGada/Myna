// NoticeToastWindow.swift — a transient, non-interactive toast explaining why
// an action did nothing. Today it has one job: tell you a gesture WAS captured
// but there was no selection to read.
//
// Why this exists separately from CCToastWindow: that panel is welded to a
// `RegistryV2Item` and carries Play / Later / Discard semantics plus its own
// hover-paused lifetime. A notice has no backing item and nothing to act on,
// so faking an item there would pollute the play/discard paths.
//
// Panel configuration deliberately mirrors CCToastWindow (nonactivating,
// never key, floating, all-spaces) — a toast that stole focus from the app you
// just gestured at would be worse than no toast.
import AppKit
import SwiftUI

@MainActor
public final class NoticeToastWindow: NSPanel {
    public static let toastWidth: CGFloat = 340
    public static let toastHeight: CGFloat = 72
    /// Seconds on screen before it fades itself out.
    public static let lifetime: TimeInterval = 5

    private var dismissTask: Task<Void, Never>?
    /// Invoked once the toast has removed itself, so the owner can drop it.
    public var onDismiss: (() -> Void)?

    public init(title: String, hint: String, stackIndex: Int = 0) {
        let frame = Self.targetFrame(
            on: NSScreen.main ?? NSScreen.screens.first, stackIndex: stackIndex)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: NoticeToastContent(title: title, hint: hint))
        host.frame = NSRect(origin: .zero, size: NSSize(width: Self.toastWidth, height: Self.toastHeight))
        host.autoresizingMask = [.width, .height]
        contentView = host
    }

    /// Top-right anchor, matching the CC toast stack so a notice appearing
    /// alongside real toasts lines up instead of overlapping them.
    public static func targetFrame(on screen: NSScreen?, stackIndex: Int) -> NSRect {
        guard let screen else {
            return NSRect(x: 0, y: 0, width: toastWidth, height: toastHeight)
        }
        let visible = screen.visibleFrame
        let originX = visible.maxX - toastWidth - CCToastWindow.margin
        let topY = visible.maxY - CCToastWindow.menuBarOffset
        let yOffset = CGFloat(stackIndex) * (CCToastWindow.toastHeight + CCToastWindow.stackGap)
        return NSRect(x: originX, y: topY - toastHeight - yOffset, width: toastWidth, height: toastHeight)
    }

    public func showAnimated(animated: Bool = true) {
        let target = frame
        if animated {
            setFrameOrigin(NSPoint(x: target.origin.x, y: target.origin.y + 24))
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
        restartLifetime()
    }

    /// Reset the auto-dismiss countdown. Called when the same notice is
    /// re-raised (repeated gestures re-arm the timer rather than stacking
    /// duplicate panels on top of each other).
    public func restartLifetime() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismissAnimated()
        }
    }

    public func dismissAnimated() {
        dismissTask?.cancel()
        dismissTask = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.orderOut(nil)
                self?.onDismiss?()
            }
        }
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

/// Pure-display body. No buttons — a notice is informational, and adding an
/// action would tempt the panel into wanting focus.
struct NoticeToastContent: View {
    let title: String
    let hint: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.cursor")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(
            width: NoticeToastWindow.toastWidth,
            height: NoticeToastWindow.toastHeight,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
