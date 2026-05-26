// Mailbox.swift — single-slot coalescing mailbox for backpressure.
//
// Word events arrive faster than the renderer can paint them. We drop
// older `word` events when a newer one arrives (single-slot, replace).
// `start`/`stop`/`pause`/`resume`/`config` are control events — they
// MUST NOT drop. They go into a separate FIFO queue.
//
// See docs/v0.2-plan/02-karaoke-architecture.md § 2 "Backpressure".

import Foundation

/// Thread-safe single-slot mailbox + control-event FIFO.
///
/// - `latestWord` holds at most one pending WordMessage. New writes replace.
/// - `controlQueue` is FIFO — start/stop/pause/resume/config never drop.
/// - All access is serialized via an internal lock; cheap (no contention
///   under expected load: writer is socket-read on bg queue, reader is main).
public final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var word: WordMessage?
    private var control: [IncomingMessage] = []

    public init() {}

    /// Submit an incoming message. Word events coalesce; control events queue.
    public func submit(_ message: IncomingMessage) {
        lock.lock()
        defer { lock.unlock() }

        switch message {
        case .word(let wordMessage):
            // Replace, don't queue. If a newer word index arrives while an
            // older one is still pending paint, the renderer sees only the
            // newer index — correct end-state, faster perceived response.
            word = wordMessage
        case .start, .stop, .pause, .resume, .config, .unknown:
            control.append(message)
        }
    }

    /// Drain everything pending. Returns control events in FIFO order, then
    /// the latest word event (if any). Empties the mailbox.
    public func drain() -> [IncomingMessage] {
        lock.lock()
        defer { lock.unlock() }

        var out: [IncomingMessage] = control
        control.removeAll(keepingCapacity: true)
        if let pendingWord = word {
            out.append(.word(pendingWord))
            word = nil
        }
        return out
    }

    /// Inspect without draining — for tests and assertions.
    public var pendingWord: WordMessage? {
        lock.lock()
        defer { lock.unlock() }
        return word
    }

    public var pendingControlCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return control.count
    }
}
