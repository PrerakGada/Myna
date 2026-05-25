// AuditSecurityURLSchemeTests.swift — adversarial inputs from the L0
// security audit (2026-05-25). DO NOT delete; this is the canonical
// regression suite for the URL-scheme attack surface.
//
// Each case asserts one of:
//   - the URL is parsed to a *safe* defined action (not arbitrary speak,
//     not exec, not crash), OR
//   - the URL is dropped (parse returns nil / dispatcher receives nothing).
import XCTest

@testable import Myna

@MainActor
final class AuditSecurityURLSchemeTests: XCTestCase {
    private func makeURL(_ str: String) -> URL? { URL(string: str) }

    func test_audit_2026_05_25_adversarial_inputs() {
        // Each line: input → expected behaviour.
        // .none means parse must return nil and dispatcher receives nothing.
        // .safe(action) means parse must return exactly that action.
        struct Case {
            let raw: String
            let expectation: Expectation
        }
        enum Expectation {
            case none
            case safe(URLSchemeAction)
        }

        let cases: [Case] = [
            Case(raw: "myna://", expectation: .none),
            Case(raw: "myna://?%FF", expectation: .none),
            Case(raw: "myna://speak?text=hello", expectation: .none),
            Case(raw: "myna://exec?cmd=ls", expectation: .none),
            Case(raw: "myna://run?path=/bin/sh", expectation: .none),
            Case(raw: "myna://shell", expectation: .none),
            Case(raw: "myna://speed?value=999", expectation: .safe(.setSpeed(2.0))),
            Case(raw: "myna://speed?value=-100", expectation: .safe(.setSpeed(0.5))),
            Case(raw: "myna://seek?delta=-99999999", expectation: .safe(.seekDelta(-3600))),
            Case(raw: "myna://seek?delta=99999999", expectation: .safe(.seekDelta(3600))),
            Case(raw: "myna://nonsense", expectation: .none),
        ]

        for tc in cases {
            guard let url = makeURL(tc.raw) else {
                // Foundation refused to even build the URL — that's a "safe drop" too.
                if case .none = tc.expectation { continue }
                XCTFail("Foundation rejected \(tc.raw) but audit expected an action")
                continue
            }
            let parsed = URLSchemeHandler.parse(url)
            switch tc.expectation {
            case .none:
                XCTAssertNil(
                    parsed,
                    "audit: \(tc.raw) MUST NOT parse to any action (got \(String(describing: parsed)))"
                )
            case .safe(let expected):
                XCTAssertEqual(
                    parsed, expected,
                    "audit: \(tc.raw) expected \(expected), got \(String(describing: parsed))"
                )
            }

            // Belt-and-braces: route the URL through a real handler and
            // confirm nothing dangerous gets dispatched.
            let recorder = AuditRecorder()
            let handler = URLSchemeHandler(dispatcher: recorder, logUnknown: { _ in })
            handler.handle(url)
            switch tc.expectation {
            case .none:
                XCTAssertTrue(
                    recorder.calls.isEmpty,
                    "audit: \(tc.raw) reached dispatcher: \(recorder.calls)"
                )
            case .safe:
                XCTAssertEqual(recorder.calls.count, 1, "audit: \(tc.raw) expected exactly one dispatch")
            }
        }
    }
}

@MainActor
private final class AuditRecorder: URLSchemeDispatching {
    enum Call: Equatable {
        case speakSelection(SynthesizeMode)
        case readChrome
        case togglePause
        case stop
        case seek(TimeInterval)
        case setSpeed(Double)
        case bumpSpeed(Double)
    }
    var calls: [Call] = []
    func speakSelection(mode: SynthesizeMode) { calls.append(.speakSelection(mode)) }
    func readChrome() { calls.append(.readChrome) }
    func togglePause() { calls.append(.togglePause) }
    func stop() { calls.append(.stop) }
    func seek(delta: TimeInterval) { calls.append(.seek(delta)) }
    func setSpeed(_ value: Double) { calls.append(.setSpeed(value)) }
    func bumpSpeed(_ delta: Double) { calls.append(.bumpSpeed(delta)) }
}
