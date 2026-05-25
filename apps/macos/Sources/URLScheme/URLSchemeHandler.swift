// URLSchemeHandler.swift — parses inbound `myna://...` URLs and
// dispatches them to the appropriate services. Security-sensitive
// because URL handlers can be triggered by any local process; we
// validate all inputs and intentionally do NOT expose a "speak
// arbitrary text from URL" route.
//
// Routes (per NATIVE_APP_PROPOSAL § 8):
//
//   myna://speak-selection                  → speak selection (full)
//   myna://speak-selection?mode=summary     → speak selection (summary)
//   myna://read-chrome                      → read Chrome article
//   myna://toggle-pause                     → toggle pause/resume
//   myna://stop                             → stop
//   myna://seek?delta=+15                   → seek +/-N seconds
//   myna://speed?value=1.25                 → absolute speed
//   myna://speed?delta=+0.25                → speed delta
//
// Anything else (including `myna://speak?text=hello`) is logged and
// dropped.
import Foundation

public enum URLSchemeAction: Equatable, Sendable {
    case speakSelection(mode: SynthesizeMode)
    case readChrome
    case togglePause
    case stop
    case seekDelta(TimeInterval)
    case setSpeed(Double)
    case bumpSpeed(Double)
}

/// Abstract dispatcher that the handler routes parsed URLs into.
/// Implementations are responsible for actually performing the action
/// (calling SelectionService, AudioPlayer, etc.). Tests can pass a
/// recording dispatcher to assert routing without touching real state.
@MainActor
public protocol URLSchemeDispatching: AnyObject {
    func speakSelection(mode: SynthesizeMode)
    func readChrome()
    func togglePause()
    func stop()
    func seek(delta: TimeInterval)
    func setSpeed(_ value: Double)
    func bumpSpeed(_ delta: Double)
}

@MainActor
public final class URLSchemeHandler {
    public static let scheme = "myna"

    /// Hard limits from NATIVE_APP_PROPOSAL § 8 ("Security").
    public static let seekDeltaRange: ClosedRange<TimeInterval> = -3_600...3_600
    public static let speedRange: ClosedRange<Double> = 0.5...2.0

    private let dispatcher: URLSchemeDispatching
    /// Optional logger callback for unknown-action / malformed-URL events.
    private let logUnknown: (@MainActor (String) -> Void)?

    public init(
        dispatcher: URLSchemeDispatching,
        logUnknown: (@MainActor (String) -> Void)? = nil
    ) {
        self.dispatcher = dispatcher
        self.logUnknown = logUnknown
    }

    /// Convenience for AppDelegate.application(_:open:).
    public func handle(_ urls: [URL]) {
        for url in urls {
            handle(url)
        }
    }

    public func handle(_ url: URL) {
        guard let action = Self.parse(url) else {
            logUnknown?("unhandled myna:// URL: \(url.absoluteString)")
            return
        }
        switch action {
        case .speakSelection(let mode): dispatcher.speakSelection(mode: mode)
        case .readChrome: dispatcher.readChrome()
        case .togglePause: dispatcher.togglePause()
        case .stop: dispatcher.stop()
        case .seekDelta(let delta): dispatcher.seek(delta: delta)
        case .setSpeed(let value): dispatcher.setSpeed(value)
        case .bumpSpeed(let delta): dispatcher.bumpSpeed(delta)
        }
    }

    /// Pure parser — exposed for testing. Returns nil for unknown or
    /// malformed URLs. Numeric parameters are clamped to safe ranges.
    public static func parse(_ url: URL) -> URLSchemeAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        // The "host" of a custom-scheme URL is the action name. macOS
        // parses `myna://speak-selection` with host = speak-selection
        // and path = "". For URLs with no host (`myna:speak-selection`),
        // fall back to path.
        let host = url.host?.isEmpty == false ? url.host : nil
        let actionName = host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let lowered = actionName.lowercased()

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        switch lowered {
        case "speak-selection":
            let mode = queryString("mode", in: queryItems)?.lowercased() == "summary" ? SynthesizeMode.summary : .full
            return .speakSelection(mode: mode)
        case "read-chrome":
            return .readChrome
        case "toggle-pause":
            return .togglePause
        case "stop":
            return .stop
        case "seek":
            guard let raw = queryString("delta", in: queryItems), let value = Double(raw) else { return nil }
            let clamped = max(seekDeltaRange.lowerBound, min(seekDeltaRange.upperBound, value))
            return .seekDelta(clamped)
        case "speed":
            if let raw = queryString("value", in: queryItems), let value = Double(raw) {
                let clamped = max(speedRange.lowerBound, min(speedRange.upperBound, value))
                return .setSpeed(clamped)
            }
            if let raw = queryString("delta", in: queryItems), let delta = Double(raw) {
                return .bumpSpeed(delta)
            }
            return nil
        default:
            return nil  // intentionally drops `myna://speak?text=...` etc.
        }
    }

    private static func queryString(_ name: String, in items: [URLQueryItem]) -> String? {
        for item in items where item.name == name {
            return item.value
        }
        return nil
    }
}
