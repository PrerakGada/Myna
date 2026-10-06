// RegistryHandsFreeClientTests.swift — the registry fields and endpoint
// Claude Code hands-free added: decoding attention / partly-heard entries
// (and entries from daemons that predate them), and the partly_heard call.
import XCTest

@testable import Myna

final class RegistryHandsFreeClientTests: XCTestCase {
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

    func test_decodes_attention_and_partly_heard_fields() throws {
        let json = Data(#"""
        {"pending": [
          {"id": "a_1", "source": "claude-code", "project_id": "myna",
           "title": "Claude needs your permission to use Bash", "text": "Claude needs your permission to use Bash",
           "announced_at_ms": 1, "ttl_s": 600, "played_at_ms": null, "dismissed_at_ms": null,
           "kind": "attention", "session_id": "s1", "notification_type": "permission_prompt",
           "host_bundle_id": "com.googlecode.iterm2", "partly_heard": false},
          {"id": "u_1-rest", "source": "claude-code", "project_id": "myna",
           "title": "Partly heard · Intro.", "text": "The rest.", "announced_at_ms": 2, "ttl_s": 600,
           "kind": "reply", "partly_heard": true}
        ], "played": []}
        """#.utf8)
        let list = try JSONDecoder().decode(RegistryListResponse.self, from: json)
        let alert = list.pending[0]
        XCTAssertTrue(alert.isAttention)
        XCTAssertEqual(alert.notificationType, "permission_prompt")
        XCTAssertEqual(alert.sessionId, "s1")
        XCTAssertEqual(alert.hostBundleId, "com.googlecode.iterm2")
        XCTAssertEqual(list.pending[1].partlyHeard, true)
        XCTAssertFalse(list.pending[1].isAttention)
    }

    func test_decodes_entries_from_older_daemons_as_plain_replies() throws {
        let json = Data(#"""
        {"pending": [{"id": "u_1", "source": "claude-code", "project_id": "p", "title": "t",
                      "announced_at_ms": 1, "ttl_s": 600}]}
        """#.utf8)
        let item = try JSONDecoder().decode(RegistryListResponse.self, from: json).pending[0]
        XCTAssertNil(item.kind)
        XCTAssertFalse(item.isAttention)
        XCTAssertNil(item.partlyHeard)
    }

    func test_partly_heard_posts_the_rest() async throws {
        let sentBox = SendableBox<Data?>(nil)
        MockURLProtocol.enqueue { req in
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.url?.path, "/v2/registry/partly_heard/u_1")
            sentBox.value = req.httpBody ?? req.httpBodyStream.map(Self.read)
            // swiftlint:disable:next force_unwrapping
            return (.make(url: req.url!, status: 200), Data(#"{"ok":true,"id":"u_1-rest"}"#.utf8))
        }
        let client = DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
        let resp = try await client.registryPartlyHeardV2(id: "u_1", text: "The rest.")
        XCTAssertEqual(resp, RegistryPartlyHeardResponse(ok: true, id: "u_1-rest"))
        let body = try JSONSerialization.jsonObject(with: sentBox.value ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["text"] as? String, "The rest.")
    }

    func test_partly_heard_not_pending_is_reported_not_thrown() async throws {
        MockURLProtocol.enqueue { req in
            // swiftlint:disable:next force_unwrapping
            (.make(url: req.url!, status: 200), Data(#"{"ok":false,"reason":"not_pending"}"#.utf8))
        }
        let client = DaemonClient(baseURL: baseURL, session: MockURLProtocol.session())
        let resp = try await client.registryPartlyHeardV2(id: "u_1", text: "x")
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.reason, "not_pending")
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
