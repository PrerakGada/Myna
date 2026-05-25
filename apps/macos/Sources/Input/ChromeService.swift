// ChromeService.swift — grab the URL of the front Chrome tab via
// NSAppleScript. The AppleScript runner is protocol-injected so tests
// can run without needing Chrome installed or Automation permission
// granted on the test host.
import AppKit
import Foundation

public protocol AppleScriptRunnerProtocol: Sendable {
    /// Returns the script's string output, or nil on failure.
    func runReturningString(_ source: String) -> String?
}

public struct NSAppleScriptRunner: AppleScriptRunnerProtocol {
    public init() {}

    public func runReturningString(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor.stringValue
    }
}

public final class ChromeService: @unchecked Sendable {
    private let runner: AppleScriptRunnerProtocol

    public init(runner: AppleScriptRunnerProtocol = NSAppleScriptRunner()) {
        self.runner = runner
    }

    /// Return the URL of the front Chrome tab if Chrome is running and
    /// the URL is a valid http(s) one. Otherwise nil.
    ///
    /// The AppleScript carries a 5-second timeout so a wedged Chrome
    /// (mid-crash, beachball, stuck script) can't hang the menu bar.
    /// Per AUDIT_REPORT.md Security 🟡 #1.
    public func frontTabURL() -> String? {
        let source = """
            with timeout of 5 seconds
              tell application "Google Chrome" to return URL of active tab of front window
            end timeout
            """
        guard let raw = runner.runReturningString(source) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidHTTPURL(trimmed) else { return nil }
        return trimmed
    }

    public static func isValidHTTPURL(_ url: String) -> Bool {
        guard !url.isEmpty,
            let parsed = URL(string: url),
            let scheme = parsed.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            parsed.host?.isEmpty == false
        else {
            return false
        }
        return true
    }
}
