// Protocol.swift — Codable message types for the karaoke IPC.
//
// Wire format: newline-delimited JSON (NDJSON) over Unix domain socket
// at ~/.myna/karaoke.sock. Track B's daemon writes these; this sidecar
// reads them.
//
// LOCKED — any change to these types is a breaking protocol change.
// See docs/v0.2-plan/02-karaoke-architecture.md § 2.

import Foundation

// MARK: - Daemon → Sidecar

public struct StartMessage: Codable, Equatable, Sendable {
    public let v: Int                   // = 1
    public let type: String             // = "start"
    public let id: String               // utterance UUID
    public let sentence: String
    public let words: [Word]
    public let estimatedDurationMs: Int
    public let voice: String

    public struct Word: Codable, Equatable, Sendable {
        public let i: Int               // word index
        public let t: String            // word text

        public init(i: Int, t: String) {
            self.i = i
            self.t = t
        }
    }

    public init(
        v: Int = 1,
        type: String = "start",
        id: String,
        sentence: String,
        words: [Word],
        estimatedDurationMs: Int,
        voice: String
    ) {
        self.v = v
        self.type = type
        self.id = id
        self.sentence = sentence
        self.words = words
        self.estimatedDurationMs = estimatedDurationMs
        self.voice = voice
    }
}

public struct WordMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "word"
    public let id: String
    public let i: Int                   // word index
    public let tMs: Int                 // ms relative to utterance start

    public init(v: Int = 1, type: String = "word", id: String, i: Int, tMs: Int) {
        self.v = v
        self.type = type
        self.id = id
        self.i = i
        self.tMs = tMs
    }
}

public struct PauseMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "pause"
    public let id: String

    public init(v: Int = 1, type: String = "pause", id: String) {
        self.v = v
        self.type = type
        self.id = id
    }
}

public struct ResumeMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "resume"
    public let id: String
    public let tMs: Int

    public init(v: Int = 1, type: String = "resume", id: String, tMs: Int) {
        self.v = v
        self.type = type
        self.id = id
        self.tMs = tMs
    }
}

public struct StopMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "stop"
    public let id: String

    public init(v: Int = 1, type: String = "stop", id: String) {
        self.v = v
        self.type = type
        self.id = id
    }
}

public struct ConfigMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "config"
    public let fontSize: Int
    public let position: String         // "bottom" | "top" | "middle"
    public let theme: String            // "dark" | "light"
    public let opacity: Double

    public init(
        v: Int = 1,
        type: String = "config",
        fontSize: Int,
        position: String,
        theme: String,
        opacity: Double
    ) {
        self.v = v
        self.type = type
        self.fontSize = fontSize
        self.position = position
        self.theme = theme
        self.opacity = opacity
    }
}

// MARK: - Sidecar → Daemon (optional, written back on the same socket)

public struct HelloMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "hello"
    public let sidecarPid: Int

    public init(v: Int = 1, type: String = "hello", sidecarPid: Int) {
        self.v = v
        self.type = type
        self.sidecarPid = sidecarPid
    }
}

public struct AckMessage: Codable, Equatable, Sendable {
    public let v: Int
    public let type: String             // = "ack"
    public let id: String

    public init(v: Int = 1, type: String = "ack", id: String) {
        self.v = v
        self.type = type
        self.id = id
    }
}

// MARK: - Discriminator decoder
//
// Wire bytes are NDJSON. The reader peeks at the `type` field to decide
// which Codable struct to decode. Unknown types are returned as `.unknown`
// rather than thrown — protocol evolution shouldn't crash the sidecar.

public enum IncomingMessage: Equatable, Sendable {
    case start(StartMessage)
    case word(WordMessage)
    case pause(PauseMessage)
    case resume(ResumeMessage)
    case stop(StopMessage)
    case config(ConfigMessage)
    case unknown(type: String, v: Int)

    /// Decode a single NDJSON line.
    /// - Returns: nil for empty/whitespace-only lines; throws on malformed JSON.
    public static func decode(line: Data) throws -> IncomingMessage? {
        // Strip leading/trailing whitespace; ignore blanks.
        let trimmed = line.trimmingASCIIWhitespace()
        if trimmed.isEmpty { return nil }

        // First decode just enough to read `type` and `v`. We do this in a
        // single pass with JSONSerialization to avoid a double JSONDecoder
        // run on every message.
        let any = try JSONSerialization.jsonObject(with: trimmed, options: [])
        guard let dict = any as? [String: Any] else {
            throw KaraokeProtocolError.notAnObject
        }
        let type = (dict["type"] as? String) ?? ""
        let v = (dict["v"] as? Int) ?? 0

        // Protocol-version gate. The wire schema is locked at v=1 (see
        // docs/v0.2-plan/02-karaoke-architecture.md § 2). Anything else
        // is from a future or mismatched daemon — surface as .unknown so
        // the PanelController silently ignores it, matching the existing
        // future-type handling pattern. Throwing would crash the read
        // loop; .unknown is the graceful path.
        guard v == 1 else {
            return .unknown(type: type, v: v)
        }

        let decoder = JSONDecoder()
        switch type {
        case "start":  return .start(try decoder.decode(StartMessage.self, from: trimmed))
        case "word":   return .word(try decoder.decode(WordMessage.self, from: trimmed))
        case "pause":  return .pause(try decoder.decode(PauseMessage.self, from: trimmed))
        case "resume": return .resume(try decoder.decode(ResumeMessage.self, from: trimmed))
        case "stop":   return .stop(try decoder.decode(StopMessage.self, from: trimmed))
        case "config": return .config(try decoder.decode(ConfigMessage.self, from: trimmed))
        default:       return .unknown(type: type, v: v)
        }
    }
}

public enum KaraokeProtocolError: Error, Equatable {
    case notAnObject
}

// MARK: - Helpers

extension Data {
    /// Strip ASCII whitespace from both ends without re-allocating unless needed.
    fileprivate func trimmingASCIIWhitespace() -> Data {
        var start = startIndex
        var end = endIndex
        while start < end, isWhitespace(self[start]) { start = index(after: start) }
        while end > start, isWhitespace(self[index(before: end)]) { end = index(before: end) }
        return subdata(in: start..<end)
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        // space, tab, CR, LF
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }
}
