// APIServiceState.swift — the two small state machines behind the API
// pane's status line.
//
// `APIRestartTracker`: turning "Allow devices on my network" on or off
// makes the daemon rebind, which it does by re-executing itself about
// 0.3 s after answering (RENDER_API.md § 4, `restart_pending`). For a
// moment nothing answers. The pane shows "Restarting…" and re-polls until
// the daemon is back with the requested setting. If it gives up, it says
// which of two things happened: the daemon never came back, or it kept
// answering without applying the change (a daemon started by hand with
// `uvicorn --factory` can't rebind itself and needs a manual restart).
//
// `APIServiceStatus`: what the status line says, derived from the last
// settings fetch, the health check and the tracker. Both are pure so the
// transitions are unit-tested instead of discovered on screen.
import Foundation

struct APIRestartTracker: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case waiting(attempts: Int)
        /// Gave up. `answering`: the last poll got a reply, so the daemon
        /// is up but still hasn't applied the change.
        case timedOut(answering: Bool)
    }

    /// One poll of `GET /v2/api/settings` while waiting.
    enum Observation: Equatable, Sendable {
        /// The daemon answered. `settled` is true when it reports no
        /// pending restart and the LAN setting the user asked for.
        case answered(settled: Bool)
        /// Connection refused or timed out: still restarting.
        case noAnswer
    }

    static let defaultPollInterval: TimeInterval = 0.5
    /// 40 × 0.5 s = 20 s. A cold daemon start is ~2 s; the engine lives in
    /// its own process and isn't restarted with it.
    static let defaultMaxAttempts = 40

    private(set) var phase: Phase = .idle
    let maxAttempts: Int

    init(maxAttempts: Int = APIRestartTracker.defaultMaxAttempts) {
        self.maxAttempts = maxAttempts
    }

    var isWaiting: Bool {
        if case .waiting = phase { return true }
        return false
    }

    var hasTimedOut: Bool {
        if case .timedOut = phase { return true }
        return false
    }

    mutating func begin() {
        phase = .waiting(attempts: 0)
    }

    mutating func reset() {
        phase = .idle
    }

    /// Feed one poll result. Returns true while the pane should keep polling.
    @discardableResult
    mutating func observe(_ observation: Observation) -> Bool {
        guard case .waiting(let attempts) = phase else { return false }
        if observation == .answered(settled: true) {
            phase = .idle
            return false
        }
        let next = attempts + 1
        if next >= maxAttempts {
            phase = .timedOut(answering: observation != .noAnswer)
            return false
        }
        phase = .waiting(attempts: next)
        return true
    }
}

enum APIServiceStatus: Equatable, Sendable {
    /// First load in flight.
    case checking
    /// Daemon and engine both answer.
    case ready
    /// Daemon answers but the voice engine is down: speech requests will
    /// fail with `engine_down` until it starts.
    case engineDown
    /// Rebinding after a LAN change.
    case restarting
    /// The daemon answers but has no `/v2/api/*` (older than this app).
    case noAPI
    /// Nothing answers.
    case unreachable(String)
    /// Waited for a restart and the daemon never came back.
    case restartFailed
    /// The daemon answers but never applied the LAN change.
    case restartNeeded

    /// Inputs are what the last refresh saw; nil means "not fetched yet".
    static func derive(
        settings: Result<APISettings, RenderAPIError>?,
        engineUp: Bool?,
        restart: APIRestartTracker
    ) -> APIServiceStatus {
        switch restart.phase {
        case .waiting: return .restarting
        case .timedOut(answering: false): return .restartFailed
        case .timedOut(answering: true): return .restartNeeded
        case .idle: break
        }
        guard let settings else { return .checking }
        switch settings {
        case .success:
            return engineUp == false ? .engineDown : .ready
        case .failure(.notFound):
            return .noAPI
        case .failure(let error):
            if case .transport = error {
                return .unreachable(error.localizedDescription)
            }
            // Answered, just not usefully (decode error, 5xx). The daemon is
            // there, so report on the engine rather than "unreachable".
            return engineUp == false ? .engineDown : .noAPI
        }
    }

    var label: String {
        switch self {
        case .checking: return "Checking…"
        case .ready: return "Ready"
        case .engineDown: return "Engine not running"
        case .restarting: return "Restarting…"
        case .noAPI: return "API not available"
        case .unreachable: return "Not reachable"
        case .restartFailed: return "Didn't come back"
        case .restartNeeded: return "Restart needed"
        }
    }

    /// One sentence under the label: what it means and what to do.
    var detail: String {
        switch self {
        case .checking:
            return "Asking Myna's voice service for its settings."
        case .ready:
            return "Myna's voice service is answering on this Mac."
        case .engineDown:
            return "The service answers, but the voice engine isn't running, so speech requests fail. "
                + "Start it from the Engine page."
        case .restarting:
            return "Myna's voice service is restarting to change who can reach it. This takes a few seconds."
        case .noAPI:
            return "The voice service running now is older than this app and has no API. "
                + "Restart it from the Engine page, or update Myna."
        case .unreachable:
            return "Myna's voice service isn't answering. Restart it from the Engine page."
        case .restartFailed:
            return "The voice service didn't come back after 20 seconds. Restart it from the Engine page."
        case .restartNeeded:
            return "The network setting is saved, but the voice service hasn't restarted to apply it. "
                + "Restart it from the Engine page."
        }
    }
}
