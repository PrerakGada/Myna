// APIStubProtocol.swift — a URLProtocol that answers by method + path,
// for tests whose code under test fires several requests at once
// (APIPaneModel.refresh uses `async let`), where MockURLProtocol's single
// FIFO would hand responses to the wrong request.
//
// Each route holds a queue of responders; the last one is sticky, so a
// route polled repeatedly keeps answering. A responder returning nil
// simulates a daemon that isn't listening (connection refused).
import Foundation

final class APIStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        var headers: [String: String] = ["Content-Type": "application/json"]
    }

    typealias Responder = @Sendable (URLRequest) -> Reply?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: [Responder]] = [:]
    nonisolated(unsafe) private static var seen: [String] = []

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        routes.removeAll()
        seen.removeAll()
    }

    /// Add a responder for `METHOD /path` (query string ignored).
    static func on(_ method: String, _ path: String, _ responder: @escaping Responder) {
        lock.lock()
        defer { lock.unlock() }
        routes["\(method) \(path)", default: []].append(responder)
    }

    static func json(_ method: String, _ path: String, status: Int = 200, _ body: String) {
        on(method, path) { _ in Reply(status: status, body: Data(body.utf8)) }
    }

    /// Simulate the daemon being down for this route.
    static func refuse(_ method: String, _ path: String) {
        on(method, path) { _ in nil }
    }

    /// Every `METHOD /path` requested so far, in order.
    static var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [APIStubProtocol.self]
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 5
        return URLSession(configuration: cfg)
    }

    /// POST bodies arrive as a stream inside URLProtocol.
    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // swiftlint:disable static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path ?? "")"
        Self.lock.lock()
        Self.seen.append(key)
        var responder: Responder?
        if var queue = Self.routes[key], !queue.isEmpty {
            responder = queue.count > 1 ? queue.removeFirst() : queue[0]
            Self.routes[key] = queue
        }
        Self.lock.unlock()

        guard let client else { return }
        guard let responder, let reply = responder(request), let url = request.url,
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: reply.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
