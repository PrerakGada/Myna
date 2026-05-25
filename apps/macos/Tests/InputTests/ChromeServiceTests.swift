// ChromeServiceTests.swift — exercises ChromeService with a stubbed
// AppleScript runner so no real Chrome / Automation TCC needed.
import XCTest

@testable import Myna

final class ChromeServiceTests: XCTestCase {
    func test_chrome_url_returns_active_tab_url() {
        let runner = StubRunner(output: "https://example.com/article")
        let service = ChromeService(runner: runner)
        XCTAssertEqual(service.frontTabURL(), "https://example.com/article")
    }

    func test_chrome_not_running_returns_nil() {
        let runner = StubRunner(output: nil)  // simulates AppleScript error
        let service = ChromeService(runner: runner)
        XCTAssertNil(service.frontTabURL())
    }

    func test_url_validation_https_passes() {
        XCTAssertTrue(ChromeService.isValidHTTPURL("https://example.com"))
        XCTAssertTrue(ChromeService.isValidHTTPURL("http://example.com/path?x=1"))
    }

    func test_url_validation_file_scheme_rejected() {
        XCTAssertFalse(ChromeService.isValidHTTPURL("file:///etc/passwd"))
        XCTAssertFalse(ChromeService.isValidHTTPURL("javascript:alert(1)"))
        XCTAssertFalse(ChromeService.isValidHTTPURL("myna://speak-selection"))
        XCTAssertFalse(ChromeService.isValidHTTPURL(""))
        XCTAssertFalse(ChromeService.isValidHTTPURL("not-a-url"))
    }

    func test_non_http_chrome_url_returns_nil() {
        let runner = StubRunner(output: "file:///etc/passwd")
        let service = ChromeService(runner: runner)
        XCTAssertNil(service.frontTabURL())
    }
}

private struct StubRunner: AppleScriptRunnerProtocol {
    let output: String?
    func runReturningString(_ source: String) -> String? { output }
}
