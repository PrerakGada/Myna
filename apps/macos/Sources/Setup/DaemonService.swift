// DaemonService.swift — the launchd side of Myna's daemon: which job runs it
// on this Mac, restarting it, and keeping a standalone install's daemon in
// step with the app after an update.
//
// dist/setup.sh installs the daemon one of two ways:
//   • homebrew    the `myna-daemon` formula, launchd job homebrew.mxcl.myna-daemon
//   • standalone  the DMG download: ~/.venvs/myna-daemon, launchd job dev.myna.daemon
import Foundation

public enum DaemonService {
    static let standaloneLabel = "dev.myna.daemon"
    static let homebrewLabel = "homebrew.mxcl.myna-daemon"

    /// True when the app's own setup installed the daemon (the DMG path), as
    /// opposed to Homebrew's service or a developer checkout.
    public static var isStandaloneInstall: Bool {
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(standaloneLabel).plist"
        guard let text = try? String(contentsOfFile: plist, encoding: .utf8) else { return false }
        return text.contains("/.venvs/myna-daemon/")
    }

    /// Version of the daemon source bundled inside this copy of Myna.
    public static func bundledVersion(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "__init__", withExtension: "py", subdirectory: "setup/daemon/myna"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return parseVersion(source)
    }

    /// Pulls `x.y.z` out of a `__version__ = "x.y.z"` line.
    static func parseVersion(_ source: String) -> String? {
        for line in source.split(separator: "\n") where line.hasPrefix("__version__") {
            let quoted = line.split(separator: "\"")
            if quoted.count >= 2 { return String(quoted[1]) }
        }
        return nil
    }

    /// Restarts whichever launchd job runs the daemon on this Mac and returns
    /// a one-line result for the UI.
    public static func restart() async -> String {
        let domain = "gui/\(getuid())"
        for label in [standaloneLabel, homebrewLabel]
        where await run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"]) == 0 {
            return "Restarted \(label)"
        }
        return "No Myna daemon service found. Quit and reopen Myna to run setup."
    }

    /// A standalone install keeps running the daemon it was set up with, even
    /// after Sparkle updates the app. When the bundled daemon is newer, reinstall
    /// it in the background (a few seconds; the script restarts the service).
    @MainActor
    public static func updateIfStale(runningVersion: String) {
        guard isStandaloneInstall,
              let bundled = bundledVersion(),
              let bundledSemver = Semver(bundled),
              let runningSemver = Semver(runningVersion),
              runningSemver < bundledSemver,
              let script = SetupController.bundledScriptPath()
        else { return }
        Log(.app).info("DaemonService: updating the daemon \(runningVersion) → \(bundled)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script, "--update-daemon"]
        process.environment = SetupController.scriptEnvironment()
        if let handle = SetupLog.open(title: "update daemon \(runningVersion) → \(bundled)") {
            process.standardOutput = handle
            process.standardError = handle
        }
        process.terminationHandler = { finished in
            Log(.app).info("DaemonService: daemon update exited \(finished.terminationStatus)")
        }
        do {
            try process.run()
        } catch {
            Log(.app).warn("DaemonService: couldn't start the daemon update: \(error.localizedDescription)")
        }
    }

    static func run(_ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }
}

/// ~/Library/Logs/Myna/setup.log — the full output of every setup run, for
/// bug reports. The app log (myna.log) sits beside it.
enum SetupLog {
    static var url: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Myna/setup.log")
    }

    /// Opens the log for appending and writes a header for this run.
    static func open(title: String) -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        let header = "\n=== \(ISO8601DateFormatter().string(from: Date())) \(title) ===\n"
        try? handle.write(contentsOf: Data(header.utf8))
        return handle
    }
}
