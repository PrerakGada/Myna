// ServicesProvider.swift — "Read with Myna" and "Summarize with Myna" in
// every app's Services menu (right-click ▸ Services, or App menu ▸ Services).
//
// Why: the read shortcut needs the Accessibility permission, and some apps
// defeat both the AX read and the synthetic ⌘C. A Service needs no
// permission at all. The requesting app writes the selection to a private
// pasteboard and AppKit calls us with it, so there is nothing to capture,
// no clipboard to restore and no modifier race. It lands in the same
// synth+play pipeline as the hotkey (AppDispatcher.speakServiceText).
//
// Declared under NSServices in project.yml, which XcodeGen writes into
// Resources/Info.plist. Edit project.yml, not the plist, or the next
// `xcodegen generate` drops it. Each entry needs:
//   - NSMessage: the selector prefix below (`readSelection` →
//     `readSelection:userData:error:`). A typo fails silently.
//   - NSPortName "Myna": the app name.
//   - NSSendTypes: plain text only, so the item shows only when text is
//     selected.
//   - NSRequiredContext: an EMPTY dict. Without the key macOS registers
//     the service but never shows it in the menu (Apple's Services
//     Properties doc; an A/B on macOS 27 reported the same).
// SelectionCaptureTests checks all four against the built Info.plist.
//
// How it reaches a user's Services menu. The first four points were
// measured on macOS 27 (29 Sep 2026) with a throwaway LSUIElement probe
// app carrying this exact NSServices shape, invoked via NSPerformService:
//   - macOS's pasteboard server (`pbs`) builds the Services menu from the
//     apps Launch Services knows. Launching Myna once registers it, and
//     AppDelegate's NSUpdateDynamicServices() makes pbs rescan: the entry
//     was in the registry right after the first launch, with no logout.
//   - Picking the item while Myna isn't running makes macOS launch it and
//     deliver the text (0.1 s for the probe). The request waits up to
//     NSTimeout (30 s default) for this provider to register, which
//     happens right after bootstrap in applicationDidFinishLaunching.
//   - AppKit delivered the call on the main thread. The methods below stay
//     nonisolated anyway, so a future change there can't crash us.
//   - Two copies with one bundle id (the dev build and /Applications/Myna.app
//     are both `dev.myna.app`): the registry lists the service once, pinned
//     to the copy Launch Services registered FIRST; launching the other
//     copy doesn't move it. A running copy gets the request (with both
//     running, the one launched first). With neither running, macOS
//     launches the pinned copy, which may not be the one you meant. So to
//     test the dev build's service, have it running. To re-pin, unregister
//     the other copy (`lsregister -u <path>`) and run `pbs -update`.
//   - If the item doesn't show: `/System/Library/CoreServices/pbs -update`,
//     or log out and back in. Users can switch it off in System Settings ▸
//     Keyboard ▸ Keyboard Shortcuts ▸ Services ▸ Text.
//   - Myna is LSUIElement (no Dock icon, no main menu), so it has no
//     Services menu of its own. That doesn't matter: the item appears in
//     *other* apps' menus. (The probe was LSUIElement too.)
import AppKit
import Foundation

public final class MynaServicesProvider: NSObject {
    /// Called on the main actor with the trimmed text and which mode the
    /// user picked.
    public typealias Handler = @MainActor @Sendable (String, SynthesizeMode) -> Void

    private let handler: Handler
    private let log = Log(.app)

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    // AppKit calls these on the thread it chooses. They are deliberately
    // nonisolated (this class is not @MainActor): each reads the private
    // service pasteboard synchronously, which is only valid during the
    // call, then hops to the main actor with a plain String. A @MainActor
    // method here would trap on entry if AppKit ever called it off-main
    // (see memory `macos26-mainactor-callback-trap`).

    /// NSMessage `readSelection` — "Read with Myna".
    @objc(readSelection:userData:error:)
    public func readSelection(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        deliver(pboard, mode: .full, error: error)
    }

    /// NSMessage `summarizeSelection` — "Summarize with Myna".
    @objc(summarizeSelection:userData:error:)
    public func summarizeSelection(
        _ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        deliver(pboard, mode: .summary, error: error)
    }

    private func deliver(
        _ pboard: NSPasteboard, mode: SynthesizeMode, error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = Self.text(from: pboard) else {
            log.warn("capture: path=service mode=\(mode.rawValue) — no text on the service pasteboard")
            error.pointee = "Myna didn't receive any text. Select some text and try again." as NSString
            return
        }
        log.info("capture: path=\(SelectionCapturePath.service.rawValue) chars=\(text.count) mode=\(mode.rawValue)")
        let handler = self.handler
        Task { @MainActor in handler(text, mode) }
    }

    /// The service pasteboard's plain text, trimmed; nil when empty.
    static func text(from pboard: NSPasteboard) -> String? {
        guard let raw = pboard.string(forType: .string), !raw.isBlank else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
