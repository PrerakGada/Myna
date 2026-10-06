// SpeakableTypesTests.swift — the text-prep fields on the wire, and
// POST /v2/speakable through DaemonClient. Stubbed with MockURLProtocol.
import XCTest

@testable import Myna

final class SpeakableTypesTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8766")!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - POST /v2/speakable

    func test_speakable_posts_text_source_and_prep() async throws {
        let sent = SendableBox<Data?>(nil)
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/speakable")
            XCTAssertEqual(req.httpMethod, "POST")
            sent.value = Self.body(of: req)
            let body = #"{"ok":true,"text":"Done.\n\nFixed app.py line 42.","changed":true,"preset":"claude_code"}"#
            return (.make(url: req.url!, status: 200), Data(body.utf8))  // swiftlint:disable:this force_unwrapping
        }
        let client = DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
        let resp = try await client.speakable(
            SpeakableRequest(text: "## Done\n\nFixed `/x/app.py:42`.", source: "claude_code", prep: .auto))
        XCTAssertEqual(resp, SpeakableResponse(text: "Done.\n\nFixed app.py line 42.", changed: true, preset: "claude_code"))
        let payload = try JSONSerialization.jsonObject(with: sent.value ?? Data()) as? [String: Any] ?? [:]
        XCTAssertEqual(payload["text"] as? String, "## Done\n\nFixed `/x/app.py:42`.")
        XCTAssertEqual(payload["source"] as? String, "claude_code")
        XCTAssertEqual(payload["prep"] as? String, "auto")
        XCTAssertNil(payload["source_kind"])
    }

    func test_speakable_blank_text_throws_without_a_request() async {
        let client = DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
        do {
            _ = try await client.speakable(SpeakableRequest(text: "  \n"))
            XCTFail("expected .empty")
        } catch {
            XCTAssertEqual(error as? DaemonError, .empty)
        }
    }

    func test_speakable_request_encodes_source_kind() throws {
        let body = try json(SpeakableRequest(text: "x", source: "studio", prep: .literal, sourceKind: "pdf"))
        XCTAssertEqual(body["source_kind"] as? String, "pdf")
        XCTAssertEqual(body["prep"] as? String, "literal")
    }

    func test_text_prep_decodes_unknown_values_as_auto() throws {
        let decoded = try JSONDecoder().decode([TextPrep].self, from: Data(#"["literal","auto","future"]"#.utf8))
        XCTAssertEqual(decoded, [.literal, .auto, .auto])
    }

    // MARK: - SynthesizeRequest

    func test_synthesize_request_sends_source_and_prep() throws {
        let body = try json(SynthesizeRequest(text: "hi", source: ReadSource.claudeCode.rawValue, prep: .literal))
        XCTAssertEqual(body["source"] as? String, "claude_code")
        XCTAssertEqual(body["prep"] as? String, "literal")
    }

    func test_synthesize_request_omits_them_when_unset() throws {
        let body = try json(SynthesizeRequest(text: "hi"))
        XCTAssertNil(body["source"])
        XCTAssertNil(body["prep"])
    }

    func test_synthesize_request_fixture_decodes() throws {
        let req = try JSONDecoder().decode(SynthesizeRequest.self, from: FixtureLoader.data("synthesize-request.json"))
        XCTAssertEqual(req.source, "selection")
        XCTAssertEqual(req.prep, .auto)
    }

    // MARK: - render API additions

    func test_speech_request_myna_prep() throws {
        XCTAssertEqual(try json(SpeechRequest(input: "x", mynaPrep: .literal))["myna_prep"] as? String, "literal")
        XCTAssertNil(try json(SpeechRequest(input: "x"))["myna_prep"])
    }

    func test_render_request_prep_and_source_kind() throws {
        let body = try json(RenderRequest(text: "x", prep: .auto, sourceKind: "epub"))
        XCTAssertEqual(body["prep"] as? String, "auto")
        XCTAssertEqual(body["source_kind"] as? String, "epub")
        let bare = try json(RenderRequest(text: "x"))
        XCTAssertNil(bare["prep"])
        XCTAssertNil(bare["source_kind"])
    }
}
