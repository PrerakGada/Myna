// FeedbackClientTests.swift — FeedbackClient against MockURLProtocol. No
// request leaves the process.
import XCTest

@testable import Myna

final class FeedbackClientTests: XCTestCase {
    private let context = FeedbackContext(
        appVersion: "0.5.2",
        build: "20",
        osVersion: "26.0 (25A354)",
        deviceModel: "Mac16,5"
    )

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> FeedbackClient {
        FeedbackClient(session: MockURLProtocol.session())
    }

    private func draft(_ message: String = "The pill froze mid-sentence.", name: String = "", email: String = "") -> FeedbackDraft {
        FeedbackDraft(kind: .problem, message: message, name: name, email: email)
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

    private static func respond(_ status: Int, _ json: String) -> MockURLProtocol.Handler {
        { request in
            // swiftlint:disable:next force_unwrapping
            (.make(url: request.url!, status: status), Data(json.utf8))
        }
    }

    private func assertSendFails(
        with expected: FeedbackError,
        _ draft: FeedbackDraft? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await makeClient().send(draft ?? self.draft(), context: context)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as FeedbackError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected FeedbackError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - payload shape

    func test_send_posts_the_documented_payload_and_headers() async throws {
        let captured = SendableBox<URLRequest?>(nil)
        let body = SendableBox<Data?>(nil)
        MockURLProtocol.enqueue { request in
            captured.value = request
            body.value = Self.body(of: request)
            // swiftlint:disable:next force_unwrapping
            return (.make(url: request.url!, status: 201), Data(#"{"ok":true,"id":"fb_abc"}"#.utf8))
        }
        let sent = FeedbackDraft(
            kind: .idea,
            message: "  Let me pick a voice per app.\n",
            name: " Asha ",
            email: " Asha@Example.COM "
        )
        let id = try await makeClient().send(sent, context: context)
        XCTAssertEqual(id, "fb_abc")

        let request = try XCTUnwrap(captured.value)
        XCTAssertEqual(request.url, URL(string: "https://api.prerakgada.in/v1/p/myna/feedback"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Myna/0.5.2 (20; macOS 26.0 (25A354))")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body.value)) as? [String: String])
        XCTAssertEqual(json, [
            "kind": "idea",
            "message": "Let me pick a voice per app.",
            "name": "Asha",
            "email": "asha@example.com",
            "appVersion": "0.5.2",
            "build": "20",
            "platform": "macOS",
            "osVersion": "26.0 (25A354)",
            "deviceModel": "Mac16,5",
            "source": "app",
        ])
    }

    func test_payload_omits_blank_name_email_and_missing_model() throws {
        let bare = FeedbackContext(appVersion: "0.5.2", build: "20", osVersion: "26.0", deviceModel: nil)
        let request = try FeedbackClient.makeRequest(
            draft("It skipped a paragraph.", name: "   ", email: ""),
            context: bare,
            endpoint: FeedbackClient.endpoint
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(Set(json.keys), ["kind", "message", "appVersion", "build", "platform", "osVersion", "source"])
        XCTAssertEqual(json["kind"], "problem")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    // MARK: - validation (fails before any request)

    func test_short_message_is_refused_without_a_request() async {
        // No handler queued: a request would come back as .couldNotSend.
        await assertSendFails(with: .invalid("Write a few words about it first."), draft(" a b "))
    }

    func test_message_over_5000_characters_is_refused() async {
        await assertSendFails(
            with: .invalid("That message is too long (5,000 characters at most)."),
            draft(String(repeating: "x", count: 5_001))
        )
    }

    func test_invalid_email_is_refused() async {
        await assertSendFails(with: .invalid("Enter a valid email, or leave it blank."), draft(email: "asha@example"))
    }

    func test_overlong_name_is_refused() async {
        await assertSendFails(
            with: .invalid("Your name or email is too long."),
            draft(name: String(repeating: "n", count: 101))
        )
    }

    func test_send_needs_three_non_space_characters() {
        XCTAssertFalse(FeedbackDraft.hasEnoughText(""))
        XCTAssertFalse(FeedbackDraft.hasEnoughText("  a \n b  "))
        XCTAssertTrue(FeedbackDraft.hasEnoughText("a b c"))
        XCTAssertTrue(FeedbackDraft.hasEnoughText("Hey"))
    }

    // MARK: - responses

    func test_201_without_an_id_still_counts_as_sent() async throws {
        MockURLProtocol.enqueue(Self.respond(201, #"{"ok":true,"id":null}"#))
        let id = try await makeClient().send(draft(), context: context)
        XCTAssertNil(id)
    }

    func test_400_shows_the_servers_sentence() async {
        MockURLProtocol.enqueue(Self.respond(400, #"{"error":"Enter a valid email, or leave it blank."}"#))
        await assertSendFails(with: .rejected("Enter a valid email, or leave it blank."))
    }

    func test_429_shows_the_servers_sentence() async {
        let sentence = "That's a lot of messages in a short time. Please try again in a few minutes."
        MockURLProtocol.enqueue(Self.respond(429, #"{"error":"\#(sentence)"}"#))
        await assertSendFails(with: .rejected(sentence))
    }

    func test_400_without_a_sentence_is_a_generic_failure() async {
        MockURLProtocol.enqueue(Self.respond(400, "<html>Bad Request</html>"))
        await assertSendFails(with: .couldNotSend)
    }

    func test_500_is_a_generic_failure() async {
        MockURLProtocol.enqueue(Self.respond(500, #"{"error":"Internal Server Error"}"#))
        await assertSendFails(with: .couldNotSend)
    }

    func test_404_is_a_generic_failure() async {
        MockURLProtocol.enqueue(Self.respond(404, #"{"error":"Unknown product."}"#))
        await assertSendFails(with: .couldNotSend)
    }

    func test_timeout_is_a_generic_failure() async {
        MockURLProtocol.enqueue { _ in throw URLError(.timedOut) }
        await assertSendFails(with: .couldNotSend)
    }

    func test_no_network_is_a_generic_failure() async {
        MockURLProtocol.enqueue { _ in throw URLError(.notConnectedToInternet) }
        await assertSendFails(with: .couldNotSend)
    }

    func test_generic_failure_message_matches_the_spec() {
        XCTAssertEqual(FeedbackError.couldNotSend.message, "Couldn't send. Check your connection and try again.")
        XCTAssertEqual(FeedbackError.rejected("Nope.").message, "Nope.")
    }

    // MARK: - offline by default

    @MainActor
    func test_launcher_never_holds_the_real_sender_under_tests() {
        // AppDelegate.bootstrap() installs FeedbackClient; it is skipped under XCTest.
        XCTAssertTrue(FeedbackLauncher.shared.sender is OfflineFeedbackSender)
        XCTAssertFalse(FeedbackLauncher.shared.sender is FeedbackClient)
    }

    func test_offline_sender_fails_without_a_request() async {
        do {
            _ = try await OfflineFeedbackSender().send(draft(), context: context)
            XCTFail("expected couldNotSend")
        } catch {
            XCTAssertEqual(error as? FeedbackError, .couldNotSend)
        }
    }
}
