// OnDeviceSummarizer.swift — summarizing text of any length with a model
// whose context window is small.
//
// `OnDeviceLanguageModel` is the seam: the app's is AppleFoundationModel
// (Apple Intelligence, macOS 26+), tests use a fake. Everything here is
// plain Swift, so the map-reduce logic is tested without a model.
//
// Map-reduce: a text that fits one call is summarized in one call. A longer
// one is cut into parts (SummaryChunker); each part gets a digest that keeps
// its facts and asks, then the style is applied to the digests in order.
// Plain English is the exception: it's a rewrite, so each part is rewritten
// and the rewrites are read in order. When the model says a call overflowed
// its context after all, that piece is halved and tried again. The whole job
// runs against one deadline, so a very long text ends in a clear "too long"
// rather than a read that never starts.
import Foundation

// MARK: - status and failures

/// What Apple's on-device model can do right now, in the words the
/// Summaries card and the notices use.
public enum AppleModelStatus: Equatable, Sendable {
    case ready
    /// Apple Intelligence is switched off in System Settings.
    case notEnabled
    /// The model is still downloading, or getting ready after an update.
    case downloading
    /// This Mac can't run Apple Intelligence.
    case notSupported
    /// macOS older than 26, which has no on-device model API.
    case needsNewerMacOS
    /// A reason newer than this build of Myna knows about.
    case unavailable(String)

    public var isReady: Bool { self == .ready }

    public var statusLine: String {
        switch self {
        case .ready: return "Apple Intelligence: ready"
        case .notEnabled: return "Apple Intelligence: not enabled"
        case .downloading: return "Apple Intelligence: downloading"
        case .notSupported: return "Apple Intelligence: not supported on this Mac"
        case .needsNewerMacOS: return "Apple Intelligence: needs macOS 26 or later"
        case .unavailable(let reason): return "Apple Intelligence: unavailable (\(reason))"
        }
    }

    /// What the user can do about it, as a clause ("turn on…"), or nil when
    /// nothing on this Mac will make it work.
    public var fix: String? {
        switch self {
        case .ready: return nil
        case .notEnabled:
            return "turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri"
        case .downloading:
            return "wait for Apple Intelligence to finish downloading its model"
        case .notSupported, .needsNewerMacOS, .unavailable: return nil
        }
    }
}

/// Why an on-device summary didn't happen.
public enum OnDeviceFailure: Error, Equatable, Sendable {
    case unavailable(AppleModelStatus)
    /// The prompt didn't fit the context window. Handled by splitting; it
    /// only escapes when a piece is already as small as it can be.
    case contextExceeded
    /// A guardrail or the model itself declined the text.
    case refused
    case unsupportedLanguage
    /// The whole job ran past its deadline.
    case timedOut
    case failed(String)
}

// MARK: - the model seam

/// One answer, and how long the first words took (nil when the model
/// doesn't stream).
public struct OnDeviceAnswer: Sendable, Equatable {
    public var text: String
    public var firstTokenSeconds: Double?

    public init(text: String, firstTokenSeconds: Double? = nil) {
        self.text = text
        self.firstTokenSeconds = firstTokenSeconds
    }
}

public protocol OnDeviceLanguageModel: Sendable {
    /// Checked before every summary; cheap.
    var status: AppleModelStatus { get }
    /// Tokens the model's context window holds.
    var contextTokens: Int { get }
    /// Load the model and cache the start of the next prompt, so the first
    /// summary after a key press starts sooner. Fire and forget.
    func prewarm(instructions: String, promptPrefix: String)
    /// One independent request: a fresh session, so nothing from an earlier
    /// call is in the context. Throws OnDeviceFailure or CancellationError.
    func respond(instructions: String, prompt: String) async throws -> OnDeviceAnswer
}

// MARK: - map-reduce

public struct SummaryTiming: Sendable, Equatable {
    /// Seconds from the start of the job to the model's first words. Only
    /// the first call counts, so for a long text this is the first part's.
    public var firstTokenSeconds: Double?
    public var totalSeconds: Double
    /// Model calls made: 1 for a text that fit, more for map-reduce.
    public var calls: Int
}

public struct SummaryOutput: Sendable, Equatable {
    public var text: String
    public var timing: SummaryTiming
}

public struct MapReduceSummarizer: Sendable {
    /// Long enough for a long article; short enough that a book-length
    /// paste fails with a notice instead of keeping the read waiting.
    public static let defaultBudget: TimeInterval = 120

    private let model: any OnDeviceLanguageModel
    private let budget: TimeInterval
    private let now: @Sendable () -> TimeInterval

    public init(
        model: any OnDeviceLanguageModel,
        budget: TimeInterval = MapReduceSummarizer.defaultBudget,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.model = model
        self.budget = budget
        self.now = now
    }

    public func summarize(_ text: String, style: SummaryStyle) async throws -> SummaryOutput {
        let job = Job(model: model, style: style, budget: budget, now: now)
        let body = try await job.summarize(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return SummaryOutput(
            text: SummaryPrompts.tidy(body),
            timing: SummaryTiming(
                firstTokenSeconds: job.firstTokenSeconds,
                totalSeconds: now() - job.started,
                calls: job.calls))
    }
}

/// One summary's state. Lives inside a single task, so it needs no locking.
private final class Job {
    let model: any OnDeviceLanguageModel
    let style: SummaryStyle
    let now: @Sendable () -> TimeInterval
    let started: TimeInterval
    let deadline: TimeInterval
    let partChars: Int
    var calls = 0
    var firstTokenSeconds: Double?

    init(model: any OnDeviceLanguageModel, style: SummaryStyle, budget: TimeInterval,
         now: @escaping @Sendable () -> TimeInterval) {
        self.model = model
        self.style = style
        self.now = now
        self.started = now()
        self.deadline = started + budget
        self.partChars = SummaryChunker.partChars(contextTokens: model.contextTokens, style: style)
    }

    func summarize(_ text: String) async throws -> String {
        let parts = SummaryChunker.split(text, maxChars: partChars)
        guard parts.count > 1 else {
            do {
                return try await call(SummaryPrompts.prompt(style, text: text))
            } catch OnDeviceFailure.contextExceeded where text.count > SummaryChunker.minPartChars {
                return try await summarizeParts(SummaryChunker.halves(text))
            }
        }
        return try await summarizeParts(parts)
    }

    private func summarizeParts(_ parts: [String]) async throws -> String {
        if style == .plainEnglish {
            var rewrites: [String] = []
            for part in parts { rewrites.append(SummaryPrompts.tidy(try await rewrite(part))) }
            return rewrites.joined(separator: "\n\n")
        }
        var digests: [String] = []
        for (offset, part) in parts.enumerated() {
            digests += try await digest(part, index: offset + 1, count: parts.count)
        }
        return try await reduce(digests)
    }

    private func rewrite(_ part: String) async throws -> String {
        do {
            return try await call(SummaryPrompts.prompt(.plainEnglish, text: part))
        } catch OnDeviceFailure.contextExceeded where part.count > SummaryChunker.minPartChars {
            var out: [String] = []
            for half in SummaryChunker.halves(part) { out.append(try await rewrite(half)) }
            return out.joined(separator: "\n\n")
        }
    }

    private func digest(_ part: String, index: Int, count: Int) async throws -> [String] {
        do {
            return [try await call(SummaryPrompts.partPrompt(part, index: index, count: count))]
        } catch OnDeviceFailure.contextExceeded where part.count > SummaryChunker.minPartChars {
            var out: [String] = []
            for half in SummaryChunker.halves(part) { out += try await digest(half, index: index, count: count) }
            return out
        }
    }

    /// Apply the style to the digests. When they're too long together for
    /// one call, digest them again in groups first.
    private func reduce(_ first: [String]) async throws -> String {
        var digests = first
        var limit = partChars
        for _ in 0..<8 {
            let joined = digests.joined(separator: "\n\n")
            if joined.count > limit {
                let groups = SummaryChunker.split(joined, maxChars: limit)
                var next: [String] = []
                for (offset, group) in groups.enumerated() {
                    next += try await digest(group, index: offset + 1, count: groups.count)
                }
                digests = next
                continue
            }
            do {
                return try await call(SummaryPrompts.reducePrompt(digests, style: style))
            } catch OnDeviceFailure.contextExceeded where limit / 2 >= SummaryChunker.minPartChars {
                limit /= 2
            }
        }
        throw OnDeviceFailure.contextExceeded
    }

    private func call(_ prompt: String) async throws -> String {
        try Task.checkCancellation()
        let remaining = deadline - now()
        guard remaining > 0 else { throw OnDeviceFailure.timedOut }
        let callStarted = now()
        let answer = try await withDeadline(remaining) { [model] in
            try await model.respond(instructions: SummaryPrompts.instructions, prompt: prompt)
        }
        calls += 1
        if firstTokenSeconds == nil, let first = answer.firstTokenSeconds {
            firstTokenSeconds = callStarted - started + first
        }
        return answer.text
    }
}

/// Run `work`, or throw `.timedOut` after `seconds`, cancelling it.
private func withDeadline(
    _ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> OnDeviceAnswer
) async throws -> OnDeviceAnswer {
    try await withThrowingTaskGroup(of: OnDeviceAnswer.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw OnDeviceFailure.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw OnDeviceFailure.timedOut }
        return first
    }
}
