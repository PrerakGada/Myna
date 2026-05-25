// URLSchemeHandlerTests.swift — verifies route parsing, parameter
// validation, clamping, and the security guarantee that arbitrary
// text-to-speech via URL is not exposed.
import XCTest

@testable import Myna

@MainActor
final class URLSchemeHandlerTests: XCTestCase {
    private func makeURL(_ raw: String) -> URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: raw)!
    }

    // MARK: routes

    func test_speak_selection_routes_to_selection_service() {
        let recorder = RecordingDispatcher()
        let handler = URLSchemeHandler(dispatcher: recorder)
        handler.handle(makeURL("myna://speak-selection"))
        XCTAssertEqual(recorder.calls, [.speakSelection(.full)])
    }

    func test_speak_selection_summary_mode_parsed() {
        let recorder = RecordingDispatcher()
        let handler = URLSchemeHandler(dispatcher: recorder)
        handler.handle(makeURL("myna://speak-selection?mode=summary"))
        XCTAssertEqual(recorder.calls, [.speakSelection(.summary)])
    }

    func test_toggle_pause_routes() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://toggle-pause"))
        XCTAssertEqual(recorder.calls, [.togglePause])
    }

    func test_read_chrome_routes() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://read-chrome"))
        XCTAssertEqual(recorder.calls, [.readChrome])
    }

    func test_stop_routes() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://stop"))
        XCTAssertEqual(recorder.calls, [.stop])
    }

    // MARK: seek

    func test_seek_delta_parsed_positive() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://seek?delta=%2B15"))
        XCTAssertEqual(recorder.calls, [.seek(15)])
    }

    func test_seek_delta_parsed_negative() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://seek?delta=-15"))
        XCTAssertEqual(recorder.calls, [.seek(-15)])
    }

    func test_seek_delta_clamped() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://seek?delta=99999"))
        XCTAssertEqual(recorder.calls, [.seek(3600)])
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://seek?delta=-99999"))
        XCTAssertEqual(recorder.calls.last, .seek(-3600))
    }

    func test_seek_missing_delta_ignored() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://seek"))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // MARK: speed

    func test_speed_value_parsed() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://speed?value=1.25"))
        XCTAssertEqual(recorder.calls, [.setSpeed(1.25)])
    }

    func test_speed_delta_parsed() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://speed?delta=%2B0.25"))
        XCTAssertEqual(recorder.calls, [.bumpSpeed(0.25)])
    }

    func test_speed_value_clamped_low() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://speed?value=0.1"))
        XCTAssertEqual(recorder.calls, [.setSpeed(0.5)])
    }

    func test_speed_value_clamped_high() {
        let recorder = RecordingDispatcher()
        URLSchemeHandler(dispatcher: recorder).handle(makeURL("myna://speed?value=10.0"))
        XCTAssertEqual(recorder.calls, [.setSpeed(2.0)])
    }

    // MARK: error paths

    func test_unknown_action_logged_no_crash() {
        let recorder = RecordingDispatcher()
        let logged = SendableBox<[String]>([])
        let handler = URLSchemeHandler(dispatcher: recorder) { msg in
            logged.value += [msg]
        }
        handler.handle(makeURL("myna://nonsense"))
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(logged.value.count, 1)
    }

    func test_malformed_url_handled() {
        let recorder = RecordingDispatcher()
        let handler = URLSchemeHandler(dispatcher: recorder)
        // Construct a URL with empty action portion; should not crash.
        handler.handle(makeURL("myna://"))
        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func test_wrong_scheme_ignored() {
        XCTAssertNil(URLSchemeHandler.parse(makeURL("http://speak-selection")))
        XCTAssertNil(URLSchemeHandler.parse(makeURL("file:///etc/passwd")))
    }

    // MARK: SECURITY — no arbitrary text-to-speech

    func test_no_arbitrary_text_speak() {
        // Even if a malicious local process opens this URL, the handler
        // MUST drop it — we never speak text given to us by a URL.
        let recorder = RecordingDispatcher()
        let handler = URLSchemeHandler(dispatcher: recorder)
        handler.handle(makeURL("myna://speak?text=hello"))
        handler.handle(makeURL("myna://say?text=password"))
        handler.handle(makeURL("myna://announce?text=oops"))
        XCTAssertTrue(recorder.calls.isEmpty, "URL-supplied text must never reach the dispatcher")
    }
}

// MARK: - recording dispatcher

private enum RecordedCall: Equatable, Sendable {
    case speakSelection(SynthesizeMode)
    case readChrome
    case togglePause
    case stop
    case seek(TimeInterval)
    case setSpeed(Double)
    case bumpSpeed(Double)
}

@MainActor
private final class RecordingDispatcher: URLSchemeDispatching {
    var calls: [RecordedCall] = []
    func speakSelection(mode: SynthesizeMode) { calls.append(.speakSelection(mode)) }
    func readChrome() { calls.append(.readChrome) }
    func togglePause() { calls.append(.togglePause) }
    func stop() { calls.append(.stop) }
    func seek(delta: TimeInterval) { calls.append(.seek(delta)) }
    func setSpeed(_ value: Double) { calls.append(.setSpeed(value)) }
    func bumpSpeed(_ delta: Double) { calls.append(.bumpSpeed(delta)) }
}
