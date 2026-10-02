// FeedbackClient.swift — sends "Report a Problem…" / "Send Feedback…" to
// Prerak's own server. The one network call Myna makes with something the
// user typed, and only when they press Send.
//
// Contract (shared by every Engaze app, see work/company/infra/product-feedback.md):
//
//   POST https://api.prerakgada.in/v1/p/myna/feedback
//   201 {"ok":true,"id":"fb_…"}       → sent (any 2xx counts)
//   400 / 429 {"error":"<sentence>"}  → show that sentence
//   anything else, no network, 15 s   → "Couldn't send. Check your connection…"
//
// No retries, no queue, no background sending. The payload is what the user
// typed plus the five fields `FeedbackContext` lists in the form — never IDs,
// logs, history or anything read from the Mac.
//
// AppDelegate installs this sender only for an interactive launch; under
// XCTest the launcher keeps `OfflineFeedbackSender`, so no test can reach
// the network.
import Foundation

public enum FeedbackKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case problem
    case idea
    case feedback

    public var id: String { rawValue }

    /// Segmented-picker label.
    public var title: String {
        switch self {
        case .problem: return "Problem"
        case .idea: return "Idea"
        case .feedback: return "Other feedback"
        }
    }

    /// Message placeholder for this kind.
    public var placeholder: String {
        switch self {
        case .problem: return "What happened, and what did you expect to happen?"
        case .idea: return "What would make Myna better for you?"
        case .feedback: return "Anything you'd like to tell me."
        }
    }
}

/// What the user typed. Name and email are optional and never persisted.
public struct FeedbackDraft: Sendable, Equatable {
    public var kind: FeedbackKind
    public var message: String
    public var name: String
    public var email: String

    public init(kind: FeedbackKind, message: String, name: String = "", email: String = "") {
        self.kind = kind
        self.message = message
        self.name = name
        self.email = email
    }

    /// Send stays disabled until the message has three non-space characters.
    public static func hasEnoughText(_ message: String) -> Bool {
        message.lazy.filter { !$0.isWhitespace }.count >= 3
    }
}

public enum FeedbackError: Error, Sendable, Equatable {
    /// Caught before sending; the text matches the server's own.
    case invalid(String)
    /// The server's 400/429 sentence.
    case rejected(String)
    /// Any other status, no network, or the 15 s timeout.
    case couldNotSend

    public static let couldNotSendMessage = "Couldn't send. Check your connection and try again."

    /// The sentence the form shows.
    public var message: String {
        switch self {
        case .invalid(let text), .rejected(let text): return text
        case .couldNotSend: return Self.couldNotSendMessage
        }
    }
}

/// Seam between the form and the network.
public protocol FeedbackSending: Sendable {
    /// Returns the server's id (`fb_…`, or nil) once a 2xx comes back.
    func send(_ draft: FeedbackDraft, context: FeedbackContext) async throws -> String?
}

/// The sender in every non-interactive context (tests, before bootstrap).
/// It never touches the network and always reports a failure.
public struct OfflineFeedbackSender: FeedbackSending {
    public init() {}
    public func send(_ draft: FeedbackDraft, context: FeedbackContext) async throws -> String? {
        throw FeedbackError.couldNotSend
    }
}

public actor FeedbackClient: FeedbackSending {
    public static let endpoint: URL = {
        // swiftlint:disable:next force_unwrapping
        URL(string: "https://api.prerakgada.in/v1/p/myna/feedback")!
    }()
    public static let timeout: TimeInterval = 15

    /// The server's limits (backend `products-public.ts`).
    static let messageLimit = 5_000
    static let nameLimit = 100
    static let emailLimit = 254
    /// Same pattern the server uses (`EMAIL_PATTERN` in `lib/validation.ts`).
    static let emailPattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = FeedbackClient.endpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        if let session {
            self.session = session
        } else {
            // Ephemeral: no cookies, no cache, nothing written to disk.
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = FeedbackClient.timeout
            cfg.timeoutIntervalForResource = FeedbackClient.timeout
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    public func send(_ draft: FeedbackDraft, context: FeedbackContext) async throws -> String? {
        let request = try Self.makeRequest(draft, context: context, endpoint: endpoint)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeedbackError.couldNotSend
        }
        guard let http = response as? HTTPURLResponse else { throw FeedbackError.couldNotSend }
        switch http.statusCode {
        case 200..<300:
            return (try? JSONDecoder().decode(SentResponse.self, from: data))?.id
        case 400, 429:
            let sentence = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sentence, !sentence.isEmpty else { throw FeedbackError.couldNotSend }
            throw FeedbackError.rejected(sentence)
        default:
            throw FeedbackError.couldNotSend
        }
    }

    // MARK: - request building (pure, tested directly)

    /// Validates the draft and builds the POST. Throws `.invalid` before any
    /// network use when the server would refuse it anyway.
    static func makeRequest(_ draft: FeedbackDraft, context: FeedbackContext, endpoint: URL) throws -> URLRequest {
        let payload = try payload(for: draft, context: context)
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(context.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    static func payload(for draft: FeedbackDraft, context: FeedbackContext) throws -> Payload {
        let message = draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = draft.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard FeedbackDraft.hasEnoughText(message) else {
            throw FeedbackError.invalid("Write a few words about it first.")
        }
        // The server counts UTF-16 code units (JavaScript string length).
        guard message.utf16.count <= messageLimit else {
            throw FeedbackError.invalid("That message is too long (5,000 characters at most).")
        }
        guard name.utf16.count <= nameLimit, email.utf16.count <= emailLimit else {
            throw FeedbackError.invalid("Your name or email is too long.")
        }
        if !email.isEmpty, email.range(of: emailPattern, options: .regularExpression) == nil {
            throw FeedbackError.invalid("Enter a valid email, or leave it blank.")
        }
        return Payload(
            kind: draft.kind.rawValue,
            message: message,
            name: name.isEmpty ? nil : name,
            email: email.isEmpty ? nil : email,
            appVersion: context.appVersion,
            build: context.build,
            platform: FeedbackContext.platform,
            osVersion: context.osVersion,
            deviceModel: context.deviceModel,
            source: "app"
        )
    }

    /// The exact JSON body. Optional fields are omitted when nil.
    struct Payload: Encodable, Equatable {
        let kind: String
        let message: String
        let name: String?
        let email: String?
        let appVersion: String
        let build: String
        let platform: String
        let osVersion: String
        let deviceModel: String?
        let source: String
    }

    private struct SentResponse: Decodable {
        let id: String?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }
}
