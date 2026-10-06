// SelectionCaptureTests.swift — the AX-first capture chain, its time-box,
// the Services menu handler, and the "Selection capture" setting.
//
// No test here makes a real Accessibility call. The real reader would read
// whatever the developer has selected in their frontmost app, and could
// flip that app's AXManualAccessibility on. The chain is driven through
// FakeAXReader instead; the deadline helper is tested with a blocking
// closure; the real read was checked by hand against TextEdit.
import AppKit
import XCTest

@testable import Myna

@MainActor
final class SelectionCaptureTests: XCTestCase {
    // MARK: - fallback chain

    func test_ax_text_is_used_and_clipboard_is_never_touched() async {
        let rig = Rig(ax: .text("from ax"), copyText: "from copy")
        rig.pasteboard.seed(with: "user clipboard")
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured, CapturedSelection(text: "from ax", path: .ax))
        XCTAssertEqual(rig.copies.callCount, 0, "⌘C must not be posted when AX answered")
        XCTAssertEqual(rig.pasteboard.restoreCallCount, 0, "clipboard must not be snapshotted/restored")
        XCTAssertEqual(rig.pasteboard.pasteboardString, "user clipboard")
    }

    func test_ax_text_is_trimmed() async {
        let rig = Rig(ax: .text("\n  spoken  \t"), copyText: nil)
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured?.text, "spoken")
        XCTAssertEqual(captured?.path, .ax)
    }

    func test_ax_empty_falls_back_to_copy() async {
        let rig = Rig(ax: .text(""), copyText: "from copy")
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured, CapturedSelection(text: "from copy", path: .copy))
        XCTAssertEqual(rig.ax.callCount, 1)
        XCTAssertEqual(rig.copies.callCount, 1)
    }

    func test_ax_whitespace_only_falls_back_to_copy() async {
        let rig = Rig(ax: .text(" \n\t "), copyText: "from copy")
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured?.path, .copy)
        XCTAssertEqual(captured?.text, "from copy")
    }

    func test_ax_error_falls_back_to_copy() async {
        let rig = Rig(ax: .unavailable(reason: "no-focused-element(-25212)"), copyText: "from copy")
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured, CapturedSelection(text: "from copy", path: .copy))
    }

    func test_ax_timeout_falls_back_to_copy() async {
        let rig = Rig(ax: .timedOut, copyText: "from copy")
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured, CapturedSelection(text: "from copy", path: .copy))
    }

    func test_fallback_keeps_the_copy_path_intact() async {
        // The ⌘C path after an AX miss must behave exactly as before:
        // snapshot, copy, restore the user's clipboard.
        let rig = Rig(ax: .text(""), copyText: "selection")
        rig.pasteboard.seed(with: "user clipboard")
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured?.text, "selection")
        XCTAssertEqual(rig.pasteboard.restoreCallCount, 1)
        XCTAssertEqual(rig.pasteboard.pasteboardString, "user clipboard")
    }

    func test_fallback_still_waits_for_modifiers_to_lift() async {
        // synthetic-cmdc-modifier-race: the copy path's wait must survive
        // being reached through the AX fallback.
        let held = PollCounter(holdTimes: 3)
        let rig = Rig(ax: .unavailable(reason: "not-trusted"), copyText: "delayed", modifiersHeld: held)
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertEqual(captured?.text, "delayed")
        XCTAssertGreaterThan(held.callCount, 1)
    }

    func test_copy_only_never_asks_ax() async {
        let rig = Rig(ax: .text("from ax"), copyText: "from copy")
        let captured = await rig.service.capture(mode: .copyOnly)
        XCTAssertEqual(captured, CapturedSelection(text: "from copy", path: .copy))
        XCTAssertEqual(rig.ax.callCount, 0)
    }

    func test_nothing_anywhere_returns_nil() async {
        let rig = Rig(ax: .text(""), copyText: nil)
        let captured = await rig.service.capture(mode: .automatic)
        XCTAssertNil(captured)
        XCTAssertEqual(rig.copies.callCount, 1)
    }

    // MARK: - time-box

    func test_deadline_returns_timed_out_when_the_work_hangs() async {
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        let outcome = await AXSelectionReader.runWithDeadline(
            0.05, on: .global(), timedOut: AXSelectionOutcome.timedOut
        ) {
            // Stands in for an AX call stuck on a hung app.
            _ = release.wait(timeout: .now() + 5)
            return .text("too late")
        }
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0, "a hung read must not stall capture")
        release.signal()
    }

    func test_deadline_returns_the_result_when_work_is_fast() async {
        let outcome = await AXSelectionReader.runWithDeadline(
            2.0, on: .global(), timedOut: AXSelectionOutcome.timedOut
        ) {
            .text("quick")
        }
        XCTAssertEqual(outcome, .text("quick"))
    }

    // MARK: - Services menu

    func test_read_service_delivers_trimmed_text_in_full_mode() async {
        let received = expectation(description: "handler called")
        let box = Received()
        let provider = MynaServicesProvider { text, mode in
            box.text = text
            box.mode = mode
            received.fulfill()
        }
        let pboard = Self.servicePasteboard(with: "  Read this aloud.\n")
        var error: NSString?
        provider.readSelection(pboard, userData: nil, error: &error)
        await fulfillment(of: [received], timeout: 2)
        XCTAssertNil(error)
        XCTAssertEqual(box.text, "Read this aloud.")
        XCTAssertEqual(box.mode, .full)
        pboard.releaseGlobally()
    }

    func test_summarize_service_uses_summary_mode() async {
        let received = expectation(description: "handler called")
        let box = Received()
        let provider = MynaServicesProvider { text, mode in
            box.text = text
            box.mode = mode
            received.fulfill()
        }
        let pboard = Self.servicePasteboard(with: "A long article.")
        var error: NSString?
        provider.summarizeSelection(pboard, userData: nil, error: &error)
        await fulfillment(of: [received], timeout: 2)
        XCTAssertEqual(box.mode, .summary)
        pboard.releaseGlobally()
    }

    func test_service_with_no_text_reports_an_error_and_reads_nothing() async {
        let notCalled = expectation(description: "handler must not run")
        notCalled.isInverted = true
        let provider = MynaServicesProvider { _, _ in notCalled.fulfill() }
        let pboard = Self.servicePasteboard(with: "   ")
        var error: NSString?
        provider.readSelection(pboard, userData: nil, error: &error)
        await fulfillment(of: [notCalled], timeout: 0.3)
        XCTAssertNotNil(error)
        pboard.releaseGlobally()
    }

    /// The four keys that, when wrong, make a Service silently vanish.
    /// Reads the test host's Info.plist, i.e. the built Myna.app.
    func test_services_are_declared_so_macos_will_show_them() throws {
        let services = try XCTUnwrap(
            Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]],
            "NSServices missing — edit project.yml, not Info.plist (XcodeGen regenerates it)")
        let byMessage = Dictionary(
            uniqueKeysWithValues: services.compactMap { entry in
                (entry["NSMessage"] as? String).map { ($0, entry) }
            })
        XCTAssertEqual(Set(byMessage.keys), ["readSelection", "summarizeSelection"])
        for (message, entry) in byMessage {
            XCTAssertNotNil(
                entry["NSRequiredContext"] as? [String: Any],
                "\(message): without NSRequiredContext macOS registers the service but never shows it")
            XCTAssertEqual(entry["NSPortName"] as? String, "Myna", message)
            let sendTypes = entry["NSSendTypes"] as? [String] ?? []
            XCTAssertTrue(sendTypes.contains("public.utf8-plain-text"), message)
            let title = (entry["NSMenuItem"] as? [String: String])?["default"] ?? ""
            XCTAssertTrue(title.hasSuffix("with Myna"), message)
            XCTAssertTrue(
                MynaServicesProvider.instancesRespond(to: NSSelectorFromString("\(message):userData:error:")),
                "\(message): NSMessage has no matching method on MynaServicesProvider")
        }
    }

    // MARK: - setting

    func test_capture_setting_defaults_to_automatic_and_persists() {
        let suite = "dev.myna.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)

        let first = SettingsViewModel(store: store)
        XCTAssertEqual(first.selectionCaptureMode, .automatic)
        first.selectionCaptureMode = .copyOnly
        XCTAssertEqual(defaults.string(forKey: "dev.myna.app.selectionCapture"), "copy")
        XCTAssertEqual(SettingsViewModel(store: store).selectionCaptureMode, .copyOnly)

        defaults.set("from-a-newer-build", forKey: "dev.myna.app.selectionCapture")
        XCTAssertEqual(SettingsViewModel(store: store).selectionCaptureMode, .automatic)

        first.selectionCaptureMode = .copyOnly
        first.resetAll()
        XCTAssertEqual(first.selectionCaptureMode, .automatic)
    }

    // MARK: - helpers

    private static func servicePasteboard(with text: String) -> NSPasteboard {
        let pboard = NSPasteboard(name: NSPasteboard.Name("dev.myna.tests.service.\(UUID().uuidString)"))
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return pboard
    }
}

// MARK: - test doubles

/// A SelectionService wired to fakes: an AX reader with a fixed answer, and
/// a ⌘C poster that "copies" `copyText` (nil = the app copied nothing).
@MainActor
private struct Rig {
    let ax: FakeAXReader
    let pasteboard = FakePasteboard()
    let copies = PollCounter(holdTimes: 0)
    let service: SelectionService

    init(ax outcome: AXSelectionOutcome, copyText: String?, modifiersHeld: PollCounter? = nil) {
        let ax = FakeAXReader(outcome)
        let pasteboard = self.pasteboard
        let copies = self.copies
        self.ax = ax
        self.service = SelectionService(
            axReader: ax,
            pasteboard: pasteboard,
            keyPoster: FakeKeyPoster(onPost: {
                _ = copies.poll()
                if let copyText { pasteboard.simulateAppPlacingOnClipboard(copyText) }
            }),
            copyWaitNanos: 1_000_000,
            modifiersHeld: { modifiersHeld?.poll() ?? false }
        )
    }
}

private final class FakeAXReader: SelectionTextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let outcome: AXSelectionOutcome

    init(_ outcome: AXSelectionOutcome) { self.outcome = outcome }

    func readSelectedText() async -> AXSelectionOutcome {
        recordCall()
        return outcome
    }

    /// Synchronous: NSLock is unavailable directly in async code.
    private func recordCall() {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Counts polls; reports true for the first `holdTimes`. Used both as a
/// "modifiers held" source and as a plain call counter (holdTimes 0).
private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let holdTimes: Int

    init(holdTimes: Int) { self.holdTimes = holdTimes }

    func poll() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        return calls <= holdTimes
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@MainActor
private final class Received {
    var text: String?
    var mode: SynthesizeMode?
}
