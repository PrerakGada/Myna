// ReadingFeed.swift — reads on the daemon's own player, followed word by
// word through GET /reading/events (Server-Sent Events, myna/reading.py).
//
// The daemon's player is what Claude Code's Myna controls and the CLI play
// through (POST /speak), so the app's AudioPlayer never sees those reads.
// This is how the pill still shows them: the feed says what is being read
// and which word, and LiveCaptions turns that into a caption.
//
// One long-lived request for the app's life. When the daemon is down or
// restarts the stream ends; the feed forgets the read and tries again,
// backing off to half a minute.
import Foundation

/// A read on the daemon's player, as the feed last described it.
public struct DaemonReading: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case preparing, playing, paused
    }

    public let id: String
    /// What is being read, after the daemon's cleanup.
    public let spoken: String
    public var state: State
    private var wordSpan: [Int] = []  // [location, length]: see TimedWord

    /// The word now, in `spoken` (UTF-16). Nil before the first.
    public var word: NSRange? {
        get { wordSpan.count == 2 ? NSRange(location: wordSpan[0], length: wordSpan[1]) : nil }
        set { wordSpan = newValue.map { [$0.location, $0.length] } ?? [] }
    }

    public init(id: String, spoken: String, state: State, word: NSRange? = nil) {
        self.id = id
        self.spoken = spoken
        self.state = state
        self.word = word
    }
}

/// The feed's events, applied to the read they describe. Pure, for tests.
public enum ReadingEvents {
    private struct Word: Decodable {
        let at: [Int]?
    }

    private struct Reading: Decodable {
        let id: String?
        let spoken: String?
        let state: String?
        let word: Word?
    }

    private struct Payload: Decodable {
        let id: String?
        let spoken: String?
        let at: [Int]?
        let reading: Reading?
    }

    /// The read after `event` (its JSON `data`); nil once it has ended.
    public static func apply(event: String, data: Data, to current: DaemonReading?) -> DaemonReading? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return current }
        let mine = current != nil && payload.id == current?.id
        switch event {
        case "snapshot":
            guard let r = payload.reading, let id = r.id, let spoken = r.spoken,
                  let state = r.state.flatMap(DaemonReading.State.init(rawValue:))
            else { return nil }  // none, or "ended"
            return DaemonReading(id: id, spoken: spoken, state: state, word: range(r.word?.at))
        case "start":
            guard let id = payload.id else { return current }
            return DaemonReading(id: id, spoken: payload.spoken ?? "", state: .preparing)
        case "chunk", "resume":
            guard mine, var next = current else { return current }
            next.state = .playing
            return next
        case "word":
            guard mine, var next = current else { return current }
            next.state = .playing
            next.word = range(payload.at) ?? next.word
            return next
        case "pause":
            guard mine, var next = current else { return current }
            next.state = .paused
            return next
        case "end":
            return mine ? nil : current
        default:
            return current
        }
    }

    private static func range(_ pair: [Int]?) -> NSRange? {
        guard let pair, pair.count == 2, pair[0] >= 0, pair[1] > pair[0] else { return nil }
        return NSRange(location: pair[0], length: pair[1] - pair[0])
    }
}

@MainActor
public final class ReadingFeed: ObservableObject {
    public static let shared = ReadingFeed()

    /// The daemon's read now, or nil when it isn't reading.
    @Published public private(set) var reading: DaemonReading?

    public enum Control: String {
        case pause, resume, stop
    }

    private let baseURL: URL
    private let session: URLSession
    private var task: Task<Void, Never>?
    private let log = Log(.app)

    public init(baseURL: URL = DaemonClient.defaultBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        // The daemon writes a comment line every ~15 s while quiet.
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        self.session = URLSession(configuration: config)
    }

    /// Start following the daemon. Idempotent.
    public func start() {
        guard task == nil else { return }
        task = Task { await self.follow() }
    }

    /// Pause, resume or stop the daemon's player (the pill's buttons for a
    /// read it didn't start). The feed reports the change back.
    public func control(_ action: Control) {
        var request = URLRequest(url: baseURL.appendingPathComponent(action.rawValue))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let session = self.session
        Task { _ = try? await session.data(for: request) }
    }

    private func follow() async {
        var backoff: Duration = .seconds(2)
        var request = URLRequest(url: baseURL.appendingPathComponent("reading/events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        while !Task.isCancelled {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                log.info("reading feed: following the daemon's reads")
                backoff = .seconds(2)
                var event = "message"
                // One `data:` line per event, so each is applied as it
                // comes, without waiting on the blank line after it.
                for try await line in bytes.lines {
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let data = Data(line.dropFirst(5).utf8)
                        let next = ReadingEvents.apply(event: event, data: data, to: reading)
                        if next != reading { reading = next }
                        event = "message"
                    }
                }
            } catch {
                // Down, restarting, or not yet up: same as not reading.
            }
            if reading != nil { reading = nil }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(30))
        }
    }
}
