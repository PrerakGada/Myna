// DaemonClientTests.swift — XCTest coverage for DaemonClient. Network is
// stubbed via MockURLProtocol — no real sockets opened.
import XCTest

@testable import Myna

final class DaemonClientTests: XCTestCase {
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

    private func makeClient() -> DaemonClient {
        DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
    }

    // MARK: health

    func test_health_returns_health_when_daemon_up() async throws {
        let data = try FixtureLoader.data("health-response.json")
        MockURLProtocol.enqueue { request in
            XCTAssertEqual(request.url?.path, "/v2/health")
            XCTAssertEqual(request.httpMethod, "GET")
            return (.make(url: request.url!, status: 200), data)  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let health = try await client.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.version, "0.2.0")
        XCTAssertTrue(health.engineUp)
    }

    func test_health_throws_transport_when_connection_refused() async {
        // No handler enqueued — protocol simulates cannot-connect.
        let client = makeClient()
        do {
            _ = try await client.health()
            XCTFail("expected transport error")
        } catch let err as DaemonError {
            if case .transport = err { return }
            XCTFail("expected .transport, got \(err)")
        } catch {
            XCTFail("expected DaemonError, got \(error)")
        }
    }

    // MARK: status

    func test_status_decodes_full_v2_status_fixture() async throws {
        let data = try FixtureLoader.data("status-response.json")
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 200), data)  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let status = try await client.status()
        XCTAssertEqual(status.engine.status, "up")
        XCTAssertEqual(status.daemon.version, "0.2.0")
        XCTAssertEqual(status.config.voice, "af_heart")
        XCTAssertEqual(status.registry.count, 1)
        XCTAssertEqual(status.registry.items.first?.id, "abcd1234")
    }

    // MARK: voices

    func test_voices_returns_empty_when_engine_down() async throws {
        let body = Data(#"{"voices": [], "engine": "down"}"#.utf8)
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 200), body)  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let voices = try await client.voices(forceRefresh: true)
        XCTAssertEqual(voices, [])
    }

    func test_voices_decodes_full_voices_fixture() async throws {
        let data = try FixtureLoader.data("voices-response.json")
        MockURLProtocol.enqueue { req in
            (.make(url: req.url!, status: 200), data)  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let voices = try await client.voices(forceRefresh: true)
        XCTAssertEqual(voices.count, 4)
        XCTAssertEqual(voices.first?.id, "af_heart")
        XCTAssertTrue(voices.first?.isDefault ?? false)
    }

    // MARK: synthesize

    func test_synthesize_streams_chunks_in_order() async throws {
        let stream = makeMultipartResponse(chunkCount: 3)
        MockURLProtocol.enqueueStream { req in
            let resp = HTTPURLResponse.make(
                url: req.url!,  // swiftlint:disable:this force_unwrapping
                status: 200,
                headers: ["Content-Type": "multipart/mixed; boundary=mynachunk"]
            )
            return (resp, stream)
        }
        let client = makeClient()
        var indices: [Int] = []
        for try await chunk in client.synthesize(SynthesizeRequest(text: "hello", speed: 1.0, mode: .full)) {
            indices.append(chunk.index)
        }
        XCTAssertEqual(indices, [0, 1, 2])
    }

    func test_synthesize_handles_partial_chunk_boundary() async throws {
        // Take a multipart response, then shred it into 1-byte fragments
        // so the parser has to reassemble across every boundary byte.
        let oneChunk = makeMultipartResponse(chunkCount: 2).reduce(Data(), +)
        let shredded = oneChunk.map { Data([$0]) }
        MockURLProtocol.enqueueStream { req in
            let resp = HTTPURLResponse.make(
                url: req.url!,  // swiftlint:disable:this force_unwrapping
                status: 200,
                headers: ["Content-Type": "multipart/mixed; boundary=mynachunk"]
            )
            return (resp, shredded)
        }
        let client = makeClient()
        var seen: [SynthesizedChunk] = []
        for try await chunk in client.synthesize(SynthesizeRequest(text: "hi", speed: 1.0, mode: .full)) {
            seen.append(chunk)
        }
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(seen.map(\.index), [0, 1])
        XCTAssertEqual(seen.first?.wavData, Data("WAV0".utf8))
        XCTAssertEqual(seen.last?.wavData, Data("WAV1".utf8))
    }

    func test_synthesize_propagates_502_engine_down() async {
        MockURLProtocol.enqueueStream { req in
            let resp = HTTPURLResponse.make(
                url: req.url!,  // swiftlint:disable:this force_unwrapping
                status: 502,
                headers: ["Content-Type": "application/json"]
            )
            return (resp, [Data(#"{"ok":false,"reason":"engine_down"}"#.utf8)])
        }
        let client = makeClient()
        do {
            for try await _ in client.synthesize(SynthesizeRequest(text: "x", speed: 1.0, mode: .full)) {}
            XCTFail("expected engineDown")
        } catch let err as DaemonError {
            XCTAssertEqual(err, .engineDown)
        } catch {
            XCTFail("expected DaemonError, got \(error)")
        }
    }

    func test_synthesize_validates_empty_text_locally() async {
        let client = makeClient()
        do {
            for try await _ in client.synthesize(SynthesizeRequest(text: "   ", speed: 1.0, mode: .full)) {}
            XCTFail("expected empty")
        } catch let err as DaemonError {
            XCTAssertEqual(err, .empty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: extract

    func test_extract_url_returns_text() async throws {
        let data = try FixtureLoader.data("extract-response.json")
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/v2/extract")
            return (.make(url: req.url!, status: 200), data)  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let resp = try await client.extract(url: "https://example.com")
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.title, "Lorem Ipsum: The Article")
    }

    func test_extract_failure_returns_extract_failed() async {
        let body = Data(#"{"ok":false,"reason":"extract_failed"}"#.utf8)
        MockURLProtocol.enqueue { req in
            // swiftlint:disable:next force_unwrapping
            (.make(url: req.url!, status: 200), body)
        }
        let client = makeClient()
        do {
            _ = try await client.extract(url: "https://example.com")
            XCTFail("expected extractFailed")
        } catch let err as DaemonError {
            XCTAssertEqual(err, .extractFailed)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: summarize

    func test_summarize_returns_summary() async throws {
        let body = Data(#"{"ok":true,"summary":"SHORT"}"#.utf8)
        MockURLProtocol.enqueue { req in
            // swiftlint:disable:next force_unwrapping
            (.make(url: req.url!, status: 200), body)
        }
        let client = makeClient()
        let resp = try await client.summarize(text: "long text")
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.summary, "SHORT")
    }

    // MARK: announce

    func test_announce_post_serializes_correctly() async throws {
        let sentBox = SendableBox<Data?>(nil)
        MockURLProtocol.enqueue { req in
            // URLProtocol can't see streamed bodies directly; we rely on
            // httpBody being set (our client encodes via Data not stream).
            sentBox.value = req.httpBody ?? (req.httpBodyStream.flatMap { DaemonClientTests.readStream($0) })
            // swiftlint:disable:next force_unwrapping
            return (.make(url: req.url!, status: 200), Data(#"{"ok":true,"id":"abc12345"}"#.utf8))
        }
        let client = makeClient()
        let resp = try await client.announce(sessionId: "sess1", label: "ECS", text: "hello")
        XCTAssertEqual(resp.id, "abc12345")
        let sent = sentBox.value
        XCTAssertNotNil(sent)
        let json = try JSONSerialization.jsonObject(with: sent ?? Data()) as? [String: Any] ?? [:]
        XCTAssertEqual(json["session_id"] as? String, "sess1")
        XCTAssertEqual(json["label"] as? String, "ECS")
        XCTAssertEqual(json["text"] as? String, "hello")
    }

    // MARK: registry

    func test_registry_decodes_items() async throws {
        let body = Data(
            #"""
            {"items":[
              {"id":"aa","label":"A","age_s":1,"preview":"p1"},
              {"id":"bb","label":"B","age_s":2,"preview":"p2"}
            ]}
            """#.utf8)
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/registry")
            return (.make(url: req.url!, status: 200), body)  // swiftlint:disable:this force_unwrapping
        }
        let client = makeClient()
        let info = try await client.registry()
        XCTAssertEqual(info.count, 2)
        XCTAssertEqual(info.items.map(\.id), ["aa", "bb"])
    }

    // MARK: play

    func test_play_item_pops_registry() async throws {
        let body = Data(#"{"ok":true}"#.utf8)
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.url?.path, "/play/abc12345")
            XCTAssertEqual(req.url?.query, "mode=full")
            XCTAssertEqual(req.httpMethod, "POST")
            // swiftlint:disable:next force_unwrapping
            return (.make(url: req.url!, status: 200), body)
        }
        let client = makeClient()
        let resp = try await client.playItem(id: "abc12345", mode: .full)
        XCTAssertTrue(resp.ok)
    }

    // MARK: URL validation

    func test_url_validation_rejects_non_http() {
        XCTAssertThrowsError(try DaemonClient.validateHTTPURL("file:///etc/passwd"))
        XCTAssertThrowsError(try DaemonClient.validateHTTPURL("myna://speak-selection"))
        XCTAssertThrowsError(try DaemonClient.validateHTTPURL(""))
        XCTAssertNoThrow(try DaemonClient.validateHTTPURL("http://example.com"))
        XCTAssertNoThrow(try DaemonClient.validateHTTPURL("https://example.com"))
    }

    // MARK: timeout config

    func test_timeout_default_30s() {
        XCTAssertEqual(DaemonClient.defaultRequestTimeout, 30, accuracy: 0.001)
        XCTAssertGreaterThan(DaemonClient.synthesizeTimeout, DaemonClient.defaultRequestTimeout)
    }

    // MARK: helpers

    /// Build a list of byte chunks (one per "network read") that, when
    /// concatenated, form a complete `multipart/mixed; boundary=mynachunk`
    /// response with `chunkCount` audio parts plus the JSON trailer.
    private func makeMultipartResponse(chunkCount: Int) -> [Data] {
        var parts: [Data] = []
        for index in 0..<chunkCount {
            var part = Data()
            part.append(Data("--mynachunk\r\n".utf8))
            part.append(Data("Content-Type: audio/wav\r\n".utf8))
            part.append(Data("X-Chunk-Index: \(index)\r\n".utf8))
            part.append(Data("X-Chunk-Total-Estimate: \(chunkCount)\r\n".utf8))
            part.append(Data("X-Chunk-Text: chunk%20\(index)\r\n".utf8))
            part.append(Data("\r\n".utf8))
            part.append(Data("WAV\(index)".utf8))
            part.append(Data("\r\n".utf8))
            parts.append(part)
        }
        var trailer = Data()
        trailer.append(Data("--mynachunk\r\n".utf8))
        trailer.append(Data("Content-Type: application/json\r\n".utf8))
        trailer.append(Data("\r\n".utf8))
        trailer.append(Data(#"{"ok":true,"chunks":\#(chunkCount)}"#.utf8))
        trailer.append(Data("\r\n".utf8))
        trailer.append(Data("--mynachunk--\r\n".utf8))
        parts.append(trailer)
        return parts
    }

    fileprivate static func readStream(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
