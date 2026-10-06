// SummaryPlanner.swift — which model writes a summary, and what to tell the
// user when none can.
//
// Pure functions over three facts: the user's choice (Automatic, Apple
// Intelligence, Ollama), Apple's model status, and the daemon's Ollama probe.
// A summary never fails silently: every "can't" becomes a SummaryNotice that
// names what's missing and how to fix it.
import Foundation

/// The Ollama fallback, as the daemon's GET /v2/summarize/status sees it.
public enum OllamaSummaryStatus: Equatable, Sendable {
    case checking
    case ready(model: String)
    /// Ollama answers, but the summary model isn't pulled.
    case modelMissing(model: String)
    case notRunning(model: String)
    case notInstalled(model: String)
    /// The daemon didn't answer the probe (down, or an older daemon without
    /// it). The read is still sent to the daemon, which reports its own error.
    case unknown

    public init(state: String, model: String) {
        switch state {
        case "ready": self = .ready(model: model)
        case "model_missing": self = .modelMissing(model: model)
        case "not_running": self = .notRunning(model: model)
        case "not_installed": self = .notInstalled(model: model)
        default: self = .unknown
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Worth sending the read to the daemon: ready, or not known to be broken.
    public var mayWork: Bool {
        switch self {
        case .ready, .checking, .unknown: return true
        case .modelMissing, .notRunning, .notInstalled: return false
        }
    }

    public var statusLine: String {
        switch self {
        case .checking: return "Ollama: checking…"
        case .ready(let model): return "Ollama: found, model \(model)"
        case .modelMissing(let model): return "Ollama: running, but \(model) isn't downloaded"
        case .notRunning: return "Ollama: installed, not running"
        case .notInstalled: return "Ollama: not installed"
        case .unknown: return "Ollama: couldn't check (the voice service didn't answer)"
        }
    }

    /// What the user can do about it, as a clause, or nil when it's ready or
    /// nothing is known.
    public var fix: String? {
        switch self {
        case .ready, .checking, .unknown: return nil
        case .modelMissing(let model): return "run “ollama pull \(model)” in Terminal"
        case .notRunning: return "open Ollama"
        case .notInstalled(let model): return "install Ollama from ollama.com and run “ollama pull \(model)”"
        }
    }
}

/// A notice for the menu-bar toast: what happened, and what to do next.
public struct SummaryNotice: Equatable, Sendable {
    public var title: String
    public var hint: String

    public init(title: String, hint: String) {
        self.title = title
        self.hint = hint
    }
}

public enum SummaryRoute: Equatable, Sendable {
    /// Summarize in the app with Apple's on-device model.
    case apple
    /// Send `mode: "summary"` to the daemon, which uses Ollama.
    case ollama
    case unavailable(SummaryNotice)
}

public enum SummaryPlanner {

    /// Where a summary goes before anything has been tried.
    public static func route(
        choice: SummaryBackendChoice, apple: AppleModelStatus, ollama: OllamaSummaryStatus
    ) -> SummaryRoute {
        switch choice {
        case .automatic:
            if apple.isReady { return .apple }
            if ollama.mayWork { return .ollama }
            return .unavailable(neither(apple: apple, ollama: ollama))
        case .apple:
            if apple.isReady { return .apple }
            return .unavailable(appleNotReady(apple, ollama: ollama))
        case .ollama:
            if ollama.mayWork { return .ollama }
            return .unavailable(ollamaNotReady(ollama))
        }
    }

    /// Where a summary goes after Apple's model tried and failed. Automatic
    /// falls back to Ollama unless the text was simply too long (Ollama would
    /// be slower still) or Ollama is known not to work.
    public static func routeAfterAppleFailure(
        _ failure: OnDeviceFailure, choice: SummaryBackendChoice, ollama: OllamaSummaryStatus
    ) -> SummaryRoute {
        if case .unavailable(let status) = failure {
            return route(choice: choice, apple: status, ollama: ollama)
        }
        if choice == .automatic, failure != .timedOut, ollama.mayWork {
            return .ollama
        }
        return .unavailable(appleFailed(failure, choice: choice, ollama: ollama))
    }

    /// The notice for a summary read the daemon answered with 503
    /// {"reason": …} (daemon/myna/summary_routes.py), or nil when `error`
    /// isn't one.
    public static func notice(forDaemonError error: Error, model: String) -> SummaryNotice? {
        guard case DaemonError.http(503, let body) = error,
              let data = body.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DaemonSummaryFailure.self, from: data),
              let reason = payload.reason else { return nil }
        return notice(forDaemonReason: reason, model: model)
    }

    public static func notice(forDaemonReason reason: String, model: String) -> SummaryNotice {
        switch reason {
        case "ollama_not_running":
            return SummaryNotice(
                title: "Ollama isn't running",
                hint: "Myna summarizes with Ollama when Apple Intelligence can't. Open Ollama, then try again.")
        case "ollama_not_installed":
            return SummaryNotice(
                title: "Summaries need Apple Intelligence or Ollama",
                hint: "Turn on Apple Intelligence in System Settings ▸ Apple Intelligence & Siri, or "
                    + "install Ollama from ollama.com and run “ollama pull \(model)”.")
        case "summary_model_missing":
            return SummaryNotice(
                title: "The summary model isn't downloaded",
                hint: "Run “ollama pull \(model)” in Terminal, then try again.")
        case "summary_timeout":
            return SummaryNotice(
                title: "The summary took too long",
                hint: "Ollama didn't finish in time. Try a shorter selection.")
        default:
            return SummaryNotice(
                title: "Ollama couldn't summarize this",
                hint: "Check that “ollama run \(model)” works in Terminal, then try again.")
        }
    }

    // MARK: - notice wording

    static func neither(apple: AppleModelStatus, ollama: OllamaSummaryStatus) -> SummaryNotice {
        let fixes = [apple.fix, ollama.fix].compactMap { $0 }
        let hint: String
        if fixes.isEmpty {
            hint = "Summaries need Apple Intelligence (System Settings ▸ Apple Intelligence & Siri) or Ollama."
        } else if apple.fix == nil {
            hint = "This Mac can't use Apple Intelligence, so summaries need Ollama: "
                + (ollama.fix ?? "") + "."
        } else {
            hint = sentence(fixes.joined(separator: ", or ")) + "."
        }
        return SummaryNotice(title: "Summaries need Apple Intelligence or Ollama", hint: hint)
    }

    static func appleNotReady(_ apple: AppleModelStatus, ollama: OllamaSummaryStatus) -> SummaryNotice {
        let title: String
        switch apple {
        case .notEnabled: title = "Apple Intelligence is off"
        case .downloading: title = "Apple Intelligence is still downloading"
        default: title = "Apple Intelligence isn't available on this Mac"
        }
        let switchHint = ollama.mayWork
            ? "Or set Summaries to Automatic in Myna's Reading settings to use Ollama."
            : "Or set up Ollama and choose it in Myna's Reading settings."
        let hint = apple.fix.map { sentence($0) + ". " + switchHint }
            ?? "Summaries are set to Apple Intelligence only. " + switchHint
        return SummaryNotice(title: title, hint: hint)
    }

    static func ollamaNotReady(_ ollama: OllamaSummaryStatus) -> SummaryNotice {
        let title: String
        switch ollama {
        case .modelMissing: title = "The summary model isn't downloaded"
        case .notRunning: title = "Ollama isn't running"
        default: title = "Ollama isn't installed"
        }
        return SummaryNotice(title: title, hint: sentence(ollama.fix ?? "set up Ollama") + ", then try again.")
    }

    static func appleFailed(
        _ failure: OnDeviceFailure, choice: SummaryBackendChoice, ollama: OllamaSummaryStatus
    ) -> SummaryNotice {
        let title: String
        var detail: String
        switch failure {
        case .refused:
            title = "Apple Intelligence wouldn't summarize this"
            detail = "Its safety checks stopped it."
        case .unsupportedLanguage:
            title = "Apple Intelligence can't summarize this language"
            detail = "It supports a limited set of languages."
        case .timedOut:
            return SummaryNotice(
                title: "This is too long to summarize",
                hint: "The summary didn't finish within two minutes. Select a shorter passage and try again.")
        case .contextExceeded:
            title = "This is too long for Apple Intelligence"
            detail = "It couldn't fit even a small part of the text."
        case .failed(let message):
            title = "Apple Intelligence couldn't summarize this"
            let said = message.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            detail = "It said: \(said)."
        case .unavailable(let status):
            return appleNotReady(status, ollama: ollama)
        }
        if choice == .apple, ollama.mayWork {
            detail += " Set Summaries to Automatic to let Ollama try."
        } else if let fix = ollama.fix {
            detail += " To have Ollama try instead, " + fix + "."
        }
        return SummaryNotice(title: title, hint: detail)
    }

    private static func sentence(_ clause: String) -> String {
        clause.prefix(1).uppercased() + clause.dropFirst()
    }
}

/// The daemon's 503 body for a failed summary.
struct DaemonSummaryFailure: Decodable {
    let ok: Bool?
    let reason: String?
    let detail: String?
}
