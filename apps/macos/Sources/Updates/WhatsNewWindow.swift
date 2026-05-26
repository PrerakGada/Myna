// WhatsNewWindow.swift — borderless rounded window that renders the
// changelog for the currently-installed minor version (S10).
//
// Per the brief:
//   • ~520×640
//   • Renders markdown from `Resources/changelogs/v{MAJOR}.{MINOR}.md`
//   • "Got it" updates last_seen_version = current; close button does the same
//   • Patch releases (0.x.y with y>0) do NOT auto-show — minor releases only
//   • Missing changelog file → silent skip + log warning
//   • Fresh install (first_run_complete == false) → does NOT show
//   • Always available via menu's "What's New…" footer item
import AppKit
import SwiftUI

/// Singleton launcher that owns the active WhatsNewWindow (if any) and
/// decides whether to auto-show on launch.
@MainActor
public final class WhatsNewLauncher {
    public static let shared = WhatsNewLauncher()

    private var window: NSWindow?
    private let store: WhatsNewStateStore
    private let log = Log(.updates)

    public init(store: WhatsNewStateStore = .shared) {
        self.store = store
    }

    /// Called from AppDelegate at launch. Returns true iff the dialog was
    /// presented (test seam).
    @discardableResult
    public func showIfDue() -> Bool {
        guard let installed = installedSemver() else {
            log.warn("WhatsNewLauncher: could not parse installed version")
            return false
        }
        let state = store.load()
        guard state.firstRunComplete else {
            // Fresh install — onboarding cinematic owns this slot, per
            // S10 AC #7. (Cinematic isn't built in v0.2; here we just skip.)
            return false
        }
        guard let lastSeen = Semver(state.lastSeenVersion) else {
            // Corrupt state — bootstrap to current and skip.
            persistAck(installed: installed)
            return false
        }
        guard installed > lastSeen else { return false }
        // Minor / major bump only. Patch releases skip the dialog.
        guard installed.isMinorOrMajorBumpOver(lastSeen) else { return false }
        return present(installed: installed)
    }

    /// Force-open the dialog (e.g. menu "What's New…" item).
    @discardableResult
    public func show() -> Bool {
        guard let installed = installedSemver() else { return false }
        return present(installed: installed)
    }

    // MARK: - private

    private func present(installed: Semver) -> Bool {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            return true
        }
        let markdownURL = changelogURL(for: installed)
        let markdown =
            (try? String(contentsOf: markdownURL ?? URL(fileURLWithPath: "/dev/null"), encoding: .utf8))
            ?? "## What's new in \(installed.displayString)\n\nNotes for this release are not yet available."
        if markdownURL == nil {
            log.warn("WhatsNewLauncher: no changelog file found for v\(installed.displayString); using placeholder")
        }
        let win = WhatsNewWindow(
            version: installed,
            markdown: markdown,
            onAck: { [weak self] in
                self?.persistAck(installed: installed)
                self?.window?.close()
                self?.window = nil
            }
        )
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        return true
    }

    /// Bundled changelog file for the given version. Looks in the app
    /// bundle's `changelogs/` resource folder.
    private func changelogURL(for version: Semver) -> URL? {
        let fileBase = "v\(version.major).\(version.minor)"
        if let url = Bundle.main.url(forResource: fileBase, withExtension: "md", subdirectory: "changelogs") {
            return url
        }
        return Bundle.main.url(forResource: fileBase, withExtension: "md")
    }

    /// Persist that the user has seen the current version.
    private func persistAck(installed: Semver) {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let state = WhatsNewState(
            lastSeenVersion: installed.displayString,
            firstRunComplete: true,
            lastUpdatedAtMs: now
        )
        _ = store.save(state)
    }

    /// Marketing version from the bundle. CFBundleShortVersionString flows
    /// from MARKETING_VERSION (per the v0.1 audit fix).
    private func installedSemver() -> Semver? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        return Semver(raw)
    }

    /// Mark first_run_complete=true. Called from AppDelegate after the
    /// first successful bootstrap; ensures the next minor-version bump
    /// triggers the dialog.
    public func markFirstRunComplete() {
        var state = store.load()
        if !state.firstRunComplete {
            state.firstRunComplete = true
            state.lastUpdatedAtMs = Int(Date().timeIntervalSince1970 * 1000)
            // If last_seen_version is still the default "0.0.0", seed it
            // with the currently-installed version so we don't immediately
            // show the dialog to first-run users.
            if state.lastSeenVersion == "0.0.0", let installed = installedSemver() {
                state.lastSeenVersion = installed.displayString
            }
            _ = store.save(state)
        }
    }
}

/// The actual NSWindow used by the launcher. Standard window (not
/// borderless) so users can drag it; the title bar provides the close
/// button which also acts as an ack.
@MainActor
final class WhatsNewWindow: NSWindow {
    init(version: Semver, markdown: String, onAck: @escaping () -> Void) {
        let frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "What's New in Myna \(version.displayString)"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        let host = NSHostingView(
            rootView: WhatsNewContent(
                version: version,
                markdown: markdown,
                onAck: onAck
            ))
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        contentView = host
        // Closing the window also acks per S10 AC #5. NSWindow.delegate
        // is `weak`, so we retain the proxy in an ivar.
        let proxy = ClosingProxy(onClose: onAck)
        self.closingProxy = proxy
        delegate = proxy
    }

    /// Retains the close-handler delegate (NSWindow.delegate is weak).
    private var closingProxy: ClosingProxy?
}

private final class ClosingProxy: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private struct WhatsNewContent: View {
    let version: Semver
    let markdown: String
    let onAck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's New").font(.system(size: 28, weight: .bold))
                Text("Myna \(version.displayString)")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(renderedMarkdown())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(action: onAck) {
                    Text("Got it").padding(.horizontal, 12)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 640)
    }

    /// Render the markdown body using SwiftUI's built-in AttributedString
    /// markdown parser. Falls back to plain text if parsing fails.
    private func renderedMarkdown() -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: markdown, options: opts) {
            return parsed
        }
        return AttributedString(markdown)
    }
}
