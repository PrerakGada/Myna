// AppleFoundationModel.swift — Apple Intelligence's on-device model behind
// the OnDeviceLanguageModel seam.
//
// FoundationModels exists from macOS 26; Myna still runs on 13. Every use is
// inside `#if canImport(FoundationModels)` (an older SDK still builds) and
// `if #available(macOS 26, *)` (an older OS still launches: the framework is
// weak-linked because nothing here is reachable below 26). On a Mac without
// it, `status` says so and the summary goes to Ollama.
//
// Errors differ by OS: macOS 26 throws LanguageModelSession.GenerationError,
// macOS 27 throws LanguageModelError (GenerationError is deprecated there).
// Both map to OnDeviceFailure.
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public final class AppleFoundationModel: OnDeviceLanguageModel, @unchecked Sendable {
    public static let shared = AppleFoundationModel()

    /// A prewarmed session waiting for the next summary, and when it was
    /// made. Guarded by `lock`: prewarm runs on the main actor, respond on
    /// whatever executor the summary runs on.
    private var prewarmed: (session: AnyObject, at: TimeInterval)?
    private let lock = NSLock()
    /// A prewarmed session older than this is dropped rather than used: the
    /// system may have unloaded the model long since.
    private static let prewarmLifetime: TimeInterval = 300

    public init() {}

    public var status: AppleModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return Self.status(of: SystemLanguageModel.default.availability)
        }
        #endif
        return .needsNewerMacOS
    }

    public var contextTokens: Int {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.contextSize
        }
        #endif
        return 4_096
    }

    public func prewarm(instructions: String, promptPrefix: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard status.isReady else { return }
            let session = LanguageModelSession(instructions: instructions)
            session.prewarm(promptPrefix: Prompt(promptPrefix))
            lock.lock()
            prewarmed = (session, ProcessInfo.processInfo.systemUptime)
            lock.unlock()
        }
        #endif
    }

    public func respond(instructions: String, prompt: String) async throws -> OnDeviceAnswer {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let current = status
            guard current.isReady else { throw OnDeviceFailure.unavailable(current) }
            return try await stream(session: takeSession(instructions: instructions), prompt: prompt)
        }
        #endif
        throw OnDeviceFailure.unavailable(.needsNewerMacOS)
    }

    #if canImport(FoundationModels)
    /// The prewarmed session if there is a fresh one, else a new session.
    /// Either way it's used for one request only: a session keeps its
    /// transcript, and an earlier summary must not crowd the next one's
    /// context.
    @available(macOS 26, *)
    private func takeSession(instructions: String) -> LanguageModelSession {
        lock.lock()
        let waiting = prewarmed
        prewarmed = nil
        lock.unlock()
        if let waiting,
           ProcessInfo.processInfo.systemUptime - waiting.at < Self.prewarmLifetime,
           let session = waiting.session as? LanguageModelSession {
            return session
        }
        return LanguageModelSession(instructions: instructions)
    }

    /// Stream the answer so the time to the first words can be measured;
    /// the last snapshot is the whole answer.
    @available(macOS 26, *)
    private func stream(session: LanguageModelSession, prompt: String) async throws -> OnDeviceAnswer {
        let started = ProcessInfo.processInfo.systemUptime
        var first: Double?
        var text = ""
        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                if first == nil { first = ProcessInfo.processInfo.systemUptime - started }
                text = snapshot.content
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.failure(from: error)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnDeviceFailure.failed("the model returned no text") }
        return OnDeviceAnswer(text: trimmed, firstTokenSeconds: first)
    }

    @available(macOS 26, *)
    static func status(of availability: SystemLanguageModel.Availability) -> AppleModelStatus {
        switch availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .downloading
            case .deviceNotEligible: return .notSupported
            @unknown default: return .unavailable(String(describing: reason))
            }
        }
    }

    @available(macOS 26, *)
    static func failure(from error: Error) -> OnDeviceFailure {
        if #available(macOS 27, *) {
            if let modelError = error as? LanguageModelError {
                switch modelError {
                case .contextSizeExceeded: return .contextExceeded
                case .guardrailViolation, .refusal: return .refused
                case .unsupportedLanguageOrLocale: return .unsupportedLanguage
                case .timeout: return .timedOut
                default: return .failed(modelError.localizedDescription)
                }
            }
            if let systemError = error as? SystemLanguageModel.Error,
               case .assetsUnavailable = systemError {
                return .unavailable(.downloading)
            }
        }
        if let generationError = error as? LanguageModelSession.GenerationError {
            switch generationError {
            case .exceededContextWindowSize: return .contextExceeded
            case .guardrailViolation, .refusal: return .refused
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            case .assetsUnavailable: return .unavailable(.downloading)
            default: return .failed(generationError.localizedDescription)
            }
        }
        return .failed(error.localizedDescription)
    }
    #endif
}
