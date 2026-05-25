// MockURLProtocol.swift — pure-Swift URLProtocol that intercepts every
// request made against a URLSession configured to use it. Tests register
// per-URL handlers that produce a canned response (headers + status +
// body) or simulate a transport error. No real sockets are opened.
import Foundation

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// Handler signature: given the inbound request, return (response, body)
    /// or throw to simulate transport failure.
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    /// Streaming variant for multipart: yields chunks of body bytes.
    typealias StreamHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, [Data])

    private static let lock = NSLock()
    nonisolated(unsafe) private static var oneShotHandlers: [Handler] = []
    nonisolated(unsafe) private static var streamHandlers: [StreamHandler] = []

    /// Push a single-response handler. Consumed by the next request.
    static func enqueue(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        oneShotHandlers.append(handler)
    }

    /// Push a streaming-response handler (for multipart). Consumed once.
    static func enqueueStream(_ handler: @escaping StreamHandler) {
        lock.lock()
        defer { lock.unlock() }
        streamHandlers.append(handler)
    }

    /// Drop all queued handlers. Call in tearDown.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        oneShotHandlers.removeAll()
        streamHandlers.removeAll()
    }

    /// Construct a URLSession that uses this protocol exclusively.
    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }

    // swiftlint:disable static_over_final_class
    // These are overrides of URLProtocol's `class` methods — `class`
    // cannot be replaced with `static` for overrides.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        MockURLProtocol.lock.lock()
        let streamHandler = MockURLProtocol.streamHandlers.isEmpty ? nil : MockURLProtocol.streamHandlers.removeFirst()
        let oneShot = MockURLProtocol.oneShotHandlers.isEmpty ? nil : MockURLProtocol.oneShotHandlers.removeFirst()
        MockURLProtocol.lock.unlock()

        guard let client else { return }
        do {
            if let streamHandler {
                let (response, parts) = try streamHandler(request)
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for part in parts {
                    client.urlProtocol(self, didLoad: part)
                }
                client.urlProtocolDidFinishLoading(self)
                return
            }
            if let oneShot {
                let (response, data) = try oneShot(request)
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: data)
                client.urlProtocolDidFinishLoading(self)
                return
            }
            // No handler queued — treat as connection refused.
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        } catch {
            client.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op; we don't have long-lived state.
    }
}

extension HTTPURLResponse {
    static func make(
        url: URL,
        status: Int,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        // swiftlint:disable:next force_unwrapping
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}
