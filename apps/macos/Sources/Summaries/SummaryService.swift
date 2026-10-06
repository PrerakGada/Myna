// SummaryService.swift — turns a summary read into something to speak.
//
// Before this, a summary read went to the daemon as `mode: "summary"` and the
// daemon asked Ollama. Without `brew install ollama` and `ollama pull`, the
// summary key did nothing a user could see. Now, when the read's turn comes
// in the queue (AppDispatcher.synthesizeAndPlay), `prepare` decides:
//
//   Apple Intelligence ready  → summarize here, speak the summary as a full read
//   else Ollama usable        → send mode "summary" + summary_style, as before
//   else                      → a notice naming what's missing; nothing plays
//
// and Automatic falls back from Apple to Ollama when Apple's model declines
// the text or errors. The Summaries card (Dashboard ▸ Reading) reads the same
// status and uses `trySample` for its Try button.
import Combine
import Foundation

/// The daemon calls the service needs; DaemonClient in the app, a fake in tests.
public protocol SummaryDaemonAPI: Sendable {
    func summaryStatus() async throws -> SummaryStatusResponse
    func summarize(text: String, style: String?) async throws -> SummarizeResponse
}

/// What a summary read should do once `prepare` has run.
public enum SummaryPreparation: Equatable, Sendable {
    /// Apple Intelligence wrote it: speak this text as a full read.
    case speak(String)
    /// Let the daemon summarize with Ollama in this style.
    case daemon(SummaryStyle)
    /// Nothing can summarize it. Show the notice; don't play anything.
    case unavailable(SummaryNotice)
    /// Stop, Skip or a newer read took over while summarizing.
    case cancelled
}

/// A summary read's request, ready to send, or the reason nothing plays.
public enum SummaryStep: Equatable, Sendable {
    case send(SynthesizeRequest)
    /// The notice says why; nil when Stop, Skip or a newer read cancelled it.
    case halt(SummaryNotice?)
}

/// The Try button's answer.
public struct SummaryTrial: Equatable, Sendable {
    public var backend: SummaryBackendChoice
    public var text: String?
    public var notice: SummaryNotice?
    public var timing: SummaryTiming?
}

@MainActor
public final class SummaryService: ObservableObject {
    /// The app's service. AppDispatcher attaches the app's DaemonClient.
    public static let shared = SummaryService()

    @Published public private(set) var appleStatus: AppleModelStatus
    @Published public private(set) var ollamaStatus: OllamaSummaryStatus = .checking

    private let model: any OnDeviceLanguageModel
    private var daemon: (any SummaryDaemonAPI)?
    private let preferences: @MainActor () -> (SummaryBackendChoice, SummaryStyle)
    private let budget: TimeInterval
    private let log = Log(.app)
    /// The summary model the daemon is configured with, for notices. Learned
    /// from the status probe; the daemon's default until then.
    private var ollamaModel = "qwen3.5:4b"
    private var lastOllamaCheck: TimeInterval = -.infinity
    /// A probe older than this is repeated before it decides a read's route.
    private static let ollamaStatusLifetime: TimeInterval = 30

    public init(
        model: any OnDeviceLanguageModel = AppleFoundationModel.shared,
        daemon: (any SummaryDaemonAPI)? = nil,
        budget: TimeInterval = MapReduceSummarizer.defaultBudget,
        preferences: @escaping @MainActor () -> (SummaryBackendChoice, SummaryStyle) = {
            (SummaryPreferences.backend(), SummaryPreferences.style())
        }
    ) {
        self.model = model
        self.daemon = daemon
        self.budget = budget
        self.preferences = preferences
        self.appleStatus = model.status
    }

    /// Use this daemon for the Ollama probe and fallback. AppDispatcher
    /// calls it with the app's client, which follows the Settings address.
    public func attach(daemon: any SummaryDaemonAPI) {
        self.daemon = daemon
    }

    // MARK: - status

    /// Re-read Apple's status and probe the daemon's Ollama. Cheap: one local
    /// GET, which the daemon answers from a 1.5 s probe of Ollama.
    public func refreshStatus() async {
        appleStatus = model.status
        await refreshOllama()
    }

    private func refreshOllama() async {
        guard let daemon else {
            ollamaStatus = .unknown
            return
        }
        do {
            let status = try await daemon.summaryStatus()
            ollamaModel = status.ollama.model
            ollamaStatus = OllamaSummaryStatus(state: status.ollama.state, model: status.ollama.model)
        } catch {
            ollamaStatus = .unknown
        }
        lastOllamaCheck = ProcessInfo.processInfo.systemUptime
    }

    /// The Ollama status, probed again if the last probe is stale.
    private func currentOllama() async -> OllamaSummaryStatus {
        if ProcessInfo.processInfo.systemUptime - lastOllamaCheck > Self.ollamaStatusLifetime {
            await refreshOllama()
        }
        return ollamaStatus
    }

    // MARK: - prewarm

    /// Load Apple's model ahead of the summary about to be asked for. Called
    /// on the summary key press (before the selection is even captured) and
    /// when the Summaries card appears. Does nothing when the user chose
    /// Ollama or Apple's model isn't ready.
    public func prewarm() {
        let (choice, style) = preferences()
        guard choice != .ollama else { return }
        appleStatus = model.status
        guard appleStatus.isReady else { return }
        model.prewarm(instructions: SummaryPrompts.instructions, promptPrefix: SummaryPrompts.promptPrefix(style))
    }

    // MARK: - a read

    /// The request a read should send. A full read passes through; a summary
    /// read comes back either as a full read of Apple Intelligence's summary,
    /// or still `mode: "summary"` with `summary_style` for the daemon.
    public func request(for req: SynthesizeRequest) async -> SummaryStep {
        guard req.mode == .summary else { return .send(req) }
        var out = req
        switch await prepare(text: req.text, url: req.url) {
        case .speak(let summary):
            out.text = summary
            out.url = nil
            out.mode = .full
        case .daemon(let style):
            out.summaryStyle = style.rawValue
        case .unavailable(let notice):
            return .halt(notice)
        case .cancelled:
            return .halt(nil)
        }
        return Task.isCancelled ? .halt(nil) : .send(out)
    }

    /// After a summary read's synthesis threw: the notice when the daemon
    /// couldn't write the summary (Ollama down, model missing…), else nil.
    public func halt(after error: Error, mode: SynthesizeMode) -> SummaryStep {
        guard mode == .summary else { return .halt(nil) }
        return .halt(notice(forDaemonError: error))
    }

    /// Decide what a summary read speaks. Runs at perform time, when the
    /// read's turn has come, so a summary queued behind a long read doesn't
    /// hold the model while it waits.
    public func prepare(text: String?, url: String?) async -> SummaryPreparation {
        let (choice, style) = preferences()
        // An article read has only a URL; the daemon extracts it, so it goes
        // down the daemon path. (No entry point summarizes an article today.)
        guard let text, !text.isEmpty else { return .daemon(style) }
        appleStatus = model.status
        // Ollama only matters when Apple's model won't be used; don't make a
        // ready Apple summary wait on a probe.
        var ollama = ollamaStatus
        if !appleStatus.isReady || choice == .ollama { ollama = await currentOllama() }
        switch SummaryPlanner.route(choice: choice, apple: appleStatus, ollama: ollama) {
        case .ollama:
            return .daemon(style)
        case .unavailable(let notice):
            log.warn("summary: no backend (\(appleStatus.statusLine); \(ollama.statusLine))")
            return .unavailable(notice)
        case .apple:
            return await summarizeOnDevice(text, style: style, choice: choice)
        }
    }

    private func summarizeOnDevice(
        _ text: String, style: SummaryStyle, choice: SummaryBackendChoice
    ) async -> SummaryPreparation {
        do {
            let output = try await MapReduceSummarizer(model: model, budget: budget).summarize(text, style: style)
            log.info("summary: Apple Intelligence, \(style.rawValue), \(Self.describe(output.timing))")
            return .speak(output.text)
        } catch {
            // Stop, Skip or an interrupting read cancelled the task.
            if Task.isCancelled || error is CancellationError { return .cancelled }
            let failure = error as? OnDeviceFailure ?? .failed(error.localizedDescription)
            log.warn("summary: Apple Intelligence failed (\(failure)); choosing a fallback")
            let ollama = await currentOllama()
            switch SummaryPlanner.routeAfterAppleFailure(failure, choice: choice, ollama: ollama) {
            case .ollama, .apple: return .daemon(style)
            case .unavailable(let notice): return .unavailable(notice)
            }
        }
    }

    /// The notice for a summary read the daemon failed (Ollama down, model
    /// missing…), or nil when the error isn't a summary failure.
    public func notice(forDaemonError error: Error) -> SummaryNotice? {
        SummaryPlanner.notice(forDaemonError: error, model: ollamaModel)
    }

    // MARK: - Try

    /// Summarize `SummarySample.text` in `style` the way the next summary
    /// read would, and return the text instead of speaking it.
    public func trySample(style: SummaryStyle) async -> SummaryTrial {
        let (choice, _) = preferences()
        await refreshStatus()
        switch SummaryPlanner.route(choice: choice, apple: appleStatus, ollama: ollamaStatus) {
        case .unavailable(let notice):
            return SummaryTrial(backend: choice, notice: notice)
        case .apple:
            do {
                let output = try await MapReduceSummarizer(model: model, budget: budget)
                    .summarize(SummarySample.text, style: style)
                return SummaryTrial(backend: .apple, text: output.text, timing: output.timing)
            } catch let failure as OnDeviceFailure {
                let next = SummaryPlanner.routeAfterAppleFailure(failure, choice: choice, ollama: ollamaStatus)
                guard next == .ollama else {
                    if case .unavailable(let notice) = next { return SummaryTrial(backend: .apple, notice: notice) }
                    return SummaryTrial(backend: .apple)
                }
                return await tryWithOllama(style: style)
            } catch {
                return SummaryTrial(backend: .apple)
            }
        case .ollama:
            return await tryWithOllama(style: style)
        }
    }

    private func tryWithOllama(style: SummaryStyle) async -> SummaryTrial {
        guard let daemon else {
            return SummaryTrial(
                backend: .ollama,
                notice: SummaryNotice(title: "The voice service isn't connected", hint: "Restart Myna and try again."))
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await daemon.summarize(text: SummarySample.text, style: style.rawValue)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            return SummaryTrial(
                backend: .ollama, text: response.summary.map(SummaryPrompts.tidy),
                timing: SummaryTiming(firstTokenSeconds: nil, totalSeconds: seconds, calls: 1))
        } catch {
            let notice = notice(forDaemonError: error)
                ?? SummaryNotice(
                    title: "The voice service didn't answer",
                    hint: "Myna's voice service summarizes with Ollama. Check it's running in Engine, then try again.")
            return SummaryTrial(backend: .ollama, notice: notice)
        }
    }

    nonisolated static func describe(_ timing: SummaryTiming) -> String {
        let total = String(format: "%.2fs total", timing.totalSeconds)
        let first = timing.firstTokenSeconds.map { String(format: "first words %.2fs, ", $0) } ?? ""
        return first + total + ", \(timing.calls) call\(timing.calls == 1 ? "" : "s")"
    }
}

/// The Try button's paragraph: short, with a decision, dates and things to
/// do, so each style has something to work with.
public enum SummarySample {
    public static let text =
        "The office move is now set for Friday the 14th. Movers arrive at eight in the morning, "
        + "so everyone needs to pack their desk into the labelled boxes by Thursday evening. IT will "
        + "disconnect computers at five on Thursday; anything not saved to the shared drive by then "
        + "may be lost. Parking at the new building is limited for the first two weeks, and the "
        + "company will cover train fares during that time if you send your receipts to Priya by the "
        + "end of the month. The new address is 40 Harbour Street, third floor. Questions about the "
        + "move go to Daniel, who is coordinating it."
}
