// SummaryFakes.swift — a scripted on-device model and a scripted daemon for
// the summary tests. No model, no network.
import Foundation

@testable import Myna

/// Answers each prompt with `answer(prompt)`, or throws what it throws.
final class FakeOnDeviceModel: OnDeviceLanguageModel, @unchecked Sendable {
    private let lock = NSLock()
    private var storedStatus: AppleModelStatus
    private var storedPrompts: [String] = []
    private var storedPrewarms: [String] = []
    let contextTokens: Int
    private let answer: @Sendable (String) throws -> String

    init(
        status: AppleModelStatus = .ready,
        contextTokens: Int = 4_096,
        answer: @escaping @Sendable (String) throws -> String = { _ in "A short summary." }
    ) {
        self.storedStatus = status
        self.contextTokens = contextTokens
        self.answer = answer
    }

    var status: AppleModelStatus {
        get { locked { storedStatus } }
        set { locked { storedStatus = newValue } }
    }

    var prompts: [String] { locked { storedPrompts } }
    var prewarms: [String] { locked { storedPrewarms } }

    func prewarm(instructions: String, promptPrefix: String) {
        locked { storedPrewarms.append(promptPrefix) }
    }

    func respond(instructions: String, prompt: String) async throws -> OnDeviceAnswer {
        locked { storedPrompts.append(prompt) }
        return OnDeviceAnswer(text: try answer(prompt), firstTokenSeconds: 0.25)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// The daemon's summary calls, scripted.
final class FakeSummaryDaemon: SummaryDaemonAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: String
    private var storedCalls: [(text: String, style: String?)] = []
    var statusFails = false
    var summarizeError: Error?

    init(state: String = "ready") {
        storedState = state
    }

    var state: String {
        get { lock.lock(); defer { lock.unlock() }; return storedState }
        set { lock.lock(); storedState = newValue; lock.unlock() }
    }

    var summarizeCalls: [(text: String, style: String?)] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    private func record(_ text: String, _ style: String?) {
        lock.lock()
        storedCalls.append((text, style))
        lock.unlock()
    }

    func summaryStatus() async throws -> SummaryStatusResponse {
        if statusFails { throw DaemonError.transport("connection refused") }
        return SummaryStatusResponse(
            ollama: .init(state: state, model: "qwen3.5:4b", url: "http://127.0.0.1:11434"),
            styles: SummaryStyle.allCases.map(\.rawValue),
            defaultStyle: "tldr")
    }

    func summarize(text: String, style: String?) async throws -> SummarizeResponse {
        record(text, style)
        if let summarizeError { throw summarizeError }
        return SummarizeResponse(ok: true, summary: "Here is a summary:\nOllama's summary.")
    }
}

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}
