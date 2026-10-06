// PronunciationClientTests.swift — /v2/pronunciations through
// PronunciationClient, stubbed with MockURLProtocol; plus the pane's filter
// and History's word picker.
import XCTest

@testable import Myna

final class PronunciationClientTests: XCTestCase {
    // swiftlint:disable:next force_unwrapping
    private let baseURL = URL(string: "http://127.0.0.1:8766")!

    private static let listJSON = #"""
        {"starter_enabled": true,
         "entries": [{"id": "p_1a2b3c4d", "word": "Anthropic", "say": "an throw pick", "enabled": true}],
         "starter": [{"id": "kubectl", "word": "kubectl", "say": "cube control", "heard": "kyoo-bect-l",
                      "enabled": true, "overridden": false},
                     {"id": "json", "word": "JSON", "say": "jay son", "heard": null,
                      "enabled": false, "overridden": true}]}
        """#

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> PronunciationClient {
        PronunciationClient(baseURL: baseURL, session: MockURLProtocol.session())
    }

    private static func body(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            data = collected
        }
        return (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
    }

    private struct Seen {
        let method: String
        let path: String
        let body: [String: Any]
    }

    /// Enqueue a 200 with the list, recording what was sent.
    private func expectList() -> SendableBox<[Seen]> {
        let seen = SendableBox<[Seen]>([])
        MockURLProtocol.enqueue { req in
            seen.value.append(Seen(method: req.httpMethod ?? "", path: req.url?.path ?? "", body: Self.body(of: req)))
            return (.make(url: req.url!, status: 200), Data(Self.listJSON.utf8))  // swiftlint:disable:this force_unwrapping
        }
        return seen
    }

    func test_list_decodes() async throws {
        _ = expectList()
        let list = try await client().list()
        XCTAssertTrue(list.starterEnabled)
        XCTAssertEqual(list.entries, [PronunciationEntry(id: "p_1a2b3c4d", word: "Anthropic", say: "an throw pick", enabled: true)])
        XCTAssertEqual(list.starter.first?.heard, "kyoo-bect-l")
        XCTAssertEqual(list.starter.last?.overridden, true)
        XCTAssertNil(list.starter.last?.heard)
    }

    func test_add_posts_word_and_say() async throws {
        let seen = expectList()
        _ = try await client().add(word: "kubectl", say: "cube control")
        XCTAssertEqual(seen.value.first?.method, "POST")
        XCTAssertEqual(seen.value.first?.path, "/v2/pronunciations")
        XCTAssertEqual(seen.value.first?.body["word"] as? String, "kubectl")
        XCTAssertEqual(seen.value.first?.body["say"] as? String, "cube control")
    }

    func test_edit_sends_only_what_changes() async throws {
        let seen = expectList()
        _ = try await client().edit(id: "p_1a2b3c4d", enabled: false)
        XCTAssertEqual(seen.value.first?.method, "PATCH")
        XCTAssertEqual(seen.value.first?.path, "/v2/pronunciations/p_1a2b3c4d")
        XCTAssertEqual(seen.value.first?.body["enabled"] as? Bool, false)
        XCTAssertNil(seen.value.first?.body["word"])
    }

    func test_delete_and_starter_switches() async throws {
        let seen = expectList()
        _ = try await client().delete(id: "p_1a2b3c4d")
        _ = expectList()
        _ = try await client().setStarter(enabled: false)
        _ = expectList()
        _ = try await client().setStarterEntry(id: "kubectl", enabled: true)
        XCTAssertEqual(seen.value.first?.method, "DELETE")
    }

    func test_starter_paths() async throws {
        let whole = expectList()
        _ = try await client().setStarter(enabled: false)
        XCTAssertEqual(whole.value.first?.path, "/v2/pronunciations/starter")
        XCTAssertEqual(whole.value.first?.body["enabled"] as? Bool, false)
        let one = expectList()
        _ = try await client().setStarterEntry(id: "kubectl", enabled: true)
        XCTAssertEqual(one.value.first?.path, "/v2/pronunciations/starter/kubectl")
    }

    func test_refusal_carries_the_daemons_sentence() async {
        MockURLProtocol.enqueue { req in
            let body = #"{"ok": false, "reason": "invalid_word", "detail": "Enter the word or phrase to change."}"#
            return (.make(url: req.url!, status: 400), Data(body.utf8))  // swiftlint:disable:this force_unwrapping
        }
        do {
            _ = try await client().add(word: " ", say: "x")
            XCTFail("expected a refusal")
        } catch let error as PronunciationError {
            XCTAssertEqual(error, .rejected(reason: "invalid_word", detail: "Enter the word or phrase to change."))
            XCTAssertEqual(error.message, "Enter the word or phrase to change.")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_no_daemon_is_a_transport_error() async {
        do {
            _ = try await client().list()
            XCTFail("expected transport error")
        } catch let error as PronunciationError {
            guard case .transport = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - the pane's filter

    @MainActor
    func test_filter_matches_word_or_respelling_and_sorts() throws {
        let list = try JSONDecoder().decode(PronunciationList.self, from: Data(Self.listJSON.utf8))
        let all = PronunciationModel.filter(list, query: "")
        XCTAssertEqual(all.starter.map(\.word), ["JSON", "kubectl"])
        let byRespelling = PronunciationModel.filter(list, query: "CUBE")
        XCTAssertEqual(byRespelling.starter.map(\.word), ["kubectl"])
        XCTAssertTrue(byRespelling.mine.isEmpty)
        XCTAssertEqual(PronunciationModel.filter(list, query: "anthro").mine.map(\.word), ["Anthropic"])
    }

    // MARK: - History's word picker

    func test_candidates_keep_tech_words_whole_and_dedupe() {
        let text = "Run kubectl, then kubectl again. Myna's JSON parser: Node.js, C++ and a11y (UI/UX)! I x"
        XCTAssertEqual(
            PronunciationWords.candidates(in: text),
            ["Run", "kubectl", "then", "again", "Myna", "JSON", "parser", "Node.js", "C++", "and", "a11y", "UI/UX"]
        )
    }

    func test_candidates_limit() {
        let text = (1...50).map { "word\($0)" }.joined(separator: " ")
        XCTAssertEqual(PronunciationWords.candidates(in: text, limit: 10).count, 10)
    }

    // MARK: - the pane is in the Voice group

    func test_pronunciation_pane_is_listed_and_parsed() {
        XCTAssertTrue(DashboardPane.Group.voice.panes.contains(.pronunciation))
        XCTAssertEqual(DashboardPane.parse("pronunciations"), .pronunciation)
        XCTAssertEqual(DashboardPane.parse("pronunciation"), .pronunciation)
    }
}
