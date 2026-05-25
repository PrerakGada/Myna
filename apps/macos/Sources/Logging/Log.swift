// Log.swift — OSLog-backed structured logging that ALSO mirrors to
// ~/Library/Logs/Myna/myna.log with size-based rotation (5MB, keep 5).
//
// Subsystem: dev.myna.app — visible in Console.app.
// Categories: app, audio, network, input, urlscheme, settings.
import Foundation
import OSLog

public enum LogCategory: String, CaseIterable, Sendable {
    case app
    case audio
    case network
    case input
    case urlscheme
    case settings
}

public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        // swiftlint:disable:next force_unwrapping
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    public var osLevel: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// File-based log mirror with size rotation. Thread-safe via a queue.
public final class LogFileMirror: @unchecked Sendable {
    public static let shared = LogFileMirror()

    /// Default directory: ~/Library/Logs/Myna/.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Myna", isDirectory: true)
    }

    public static let defaultFileName = "myna.log"
    public static let maxBytes = 5 * 1024 * 1024  // 5MB
    public static let maxArchives = 5

    private let queue = DispatchQueue(label: "dev.myna.log.file", qos: .utility)
    private var directory: URL
    private var fileName: String

    public init(
        directory: URL = LogFileMirror.defaultDirectory,
        fileName: String = LogFileMirror.defaultFileName
    ) {
        self.directory = directory
        self.fileName = fileName
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var currentLogURL: URL {
        directory.appendingPathComponent(fileName)
    }

    public func write(_ line: String) {
        queue.async { [weak self] in
            self?.writeLocked(line)
        }
    }

    /// Synchronous version exposed for tests so they don't have to wait
    /// on the queue.
    public func writeSync(_ line: String) {
        queue.sync { [weak self] in
            self?.writeLocked(line)
        }
    }

    private func writeLocked(_ line: String) {
        let url = currentLogURL
        let payload = (line.hasSuffix("\n") ? line : line + "\n").data(using: .utf8) ?? Data()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // Append; rotate before append if would exceed maxBytes.
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let currentSize = (attrs?[.size] as? Int) ?? 0
        if currentSize + payload.count > Self.maxBytes {
            rotate()
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
            try? handle.close()
        }
    }

    /// Rename current → .1, .1 → .2, …; drop > maxArchives.
    private func rotate() {
        let base = directory.appendingPathComponent(fileName)
        // Drop oldest.
        let oldest = directory.appendingPathComponent("\(fileName).\(Self.maxArchives)")
        try? FileManager.default.removeItem(at: oldest)
        // Shift the rest up by 1.
        var index = Self.maxArchives - 1
        while index >= 1 {
            let src = directory.appendingPathComponent("\(fileName).\(index)")
            let dst = directory.appendingPathComponent("\(fileName).\(index + 1)")
            if FileManager.default.fileExists(atPath: src.path) {
                try? FileManager.default.moveItem(at: src, to: dst)
            }
            index -= 1
        }
        // Current → .1.
        let dst = directory.appendingPathComponent("\(fileName).1")
        if FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.moveItem(at: base, to: dst)
        }
        FileManager.default.createFile(atPath: base.path, contents: nil)
    }

    /// Synchronous flush — for tests that want to assert on file contents.
    public func waitForPendingWrites() {
        queue.sync {}
    }
}

public struct Log: Sendable {
    public static let subsystem = "dev.myna.app"
    public static let mirror = LogFileMirror.shared

    public let category: LogCategory
    private let osLog: Logger

    public init(_ category: LogCategory) {
        self.category = category
        self.osLog = Logger(subsystem: Log.subsystem, category: category.rawValue)
    }

    public func debug(_ message: String) { emit(.debug, message) }
    public func info(_ message: String) { emit(.info, message) }
    public func warn(_ message: String) { emit(.warning, message) }
    public func error(_ message: String) { emit(.error, message) }

    private func emit(_ level: LogLevel, _ message: String) {
        // OSLog ingestion (Console.app + tools).
        osLog.log(level: level.osLevel, "\(message, privacy: .public)")
        // File mirror.
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) [\(level.rawValue.uppercased())] [\(category.rawValue)] \(message)"
        Log.mirror.write(line)
    }
}
