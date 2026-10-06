// EngineTypesTests.swift — the /v2/engines contract and engine error text.
// The fixture is generated from the daemon (docs/native-app/fixtures/
// engines-response.json), so drift on either side fails here.
import XCTest

@testable import Myna

final class EngineTypesTests: XCTestCase {
    func test_engines_fixture_decodes_every_state() throws {
        let data = try FixtureLoader.data("engines-response.json")
        let response = try JSONDecoder().decode(EnginesResponse.self, from: data)
        XCTAssertEqual(response.active, "kokoro")
        XCTAssertEqual(response.engines.map(\.id), ["kokoro", "soprano", "pocket", "chatterbox"])
        XCTAssertEqual(response.engines.map(\.state), [.installed, .downloading, .notInstalled, .failed])

        let kokoro = response.engines[0]
        XCTAssertTrue(kokoro.active)
        XCTAssertTrue(kokoro.nativeSpeed)
        XCTAssertEqual(kokoro.stats.firstWordS, 0.10, accuracy: 0.001)

        let soprano = response.engines[1]
        XCTAssertEqual(soprano.progress ?? 0, 0.42, accuracy: 0.001)
        XCTAssertNil(soprano.stats.streamFirstS)

        let pocket = response.engines[2]
        XCTAssertEqual(pocket.voices.first?.id, "alba")
        XCTAssertNotNil(pocket.credit)
        XCTAssertEqual(pocket.stats.streamFirstS ?? 0, 0.02, accuracy: 0.001)

        XCTAssertEqual(response.engines[3].error, "Download failed: connection reset")
    }

    func test_engine_error_reads_fastapi_nested_detail() {
        let body = Data(#"{"detail":{"ok":false,"reason":"not_installed"}}"#.utf8)
        let error = EngineActionError.from(status: 409, body: body)
        XCTAssertEqual(error.reason, "not_installed")
        XCTAssertEqual(error.message, "Download this engine before switching to it.")
    }

    func test_engine_error_passes_through_daemon_detail() {
        let body = Data(#"{"detail":{"ok":false,"reason":"engine_error","detail":"model load failed"}}"#.utf8)
        XCTAssertEqual(EngineActionError.from(status: 502, body: body).message, "model load failed")
    }

    func test_engine_error_survives_a_non_json_body() {
        let error = EngineActionError.from(status: 500, body: Data("oops".utf8))
        XCTAssertEqual(error.reason, "http_500")
    }
}
