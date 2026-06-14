// SetupController.swift — drives the in-app "Finish setup" flow.
//
// A fresh Homebrew install lands the app + daemon, but the voice engine
// (mlx-audio + Kokoro), the model, and the Claude Code hook still need to be
// installed — work Homebrew shouldn't do on your behalf. Rather than make the
// user paste a `curl … | bash` one-liner, the app runs the bundled `setup.sh`
// itself and streams its progress here, then nudges for Accessibility.
//
// Mirrors OnboardingController's shape: @MainActor ObservableObject with a
// `phase` the window observes, plus a live `logLines` for the progress view.
import AppKit
import ApplicationServices
import Combine
import Foundation

@MainActor
public final class SetupController: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// `==>`-prefixed progress lines from setup.sh (the human-readable steps).
    @Published public private(set) var logLines: [String] = []
    /// Whether Accessibility is granted (drives the final "grant" affordance).
    @Published public private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()

    private let client: DaemonClient?
    private let log = Log(.app)
    private var process: Process?

    public init(client: DaemonClient?) {
        self.client = client
    }

    /// Whether setup looks incomplete right now (engine unreachable). Used by
    /// AppDelegate to decide whether to auto-present this on launch.
    public static func engineIsDown(client: DaemonClient?) async -> Bool {
        guard let client else { return false }
        do { return try await client.health().engineUp == false }
        catch { return true }  // unreachable daemon/engine → setup needed
    }

    // MARK: - run

    public func runSetup() {
        guard phase != .running else { return }
        guard let script = Self.bundledScriptPath() else {
            phase = .failed("Couldn't find the bundled setup script.")
            return
        }
        phase = .running
        logLines = ["Starting setup…"]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script]
        // GUI apps get a minimal PATH; setup.sh needs brew + python3.13.
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingest(text) }
        }
        task.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in self?.finish(status: proc.terminationStatus) }
        }
        self.process = task
        do {
            try task.run()
            log.info("SetupController: launched setup.sh")
        } catch {
            phase = .failed("Couldn't start setup: \(error.localizedDescription)")
        }
    }

    /// Parse a chunk of setup.sh output: keep the `==>` step lines (and warn/
    /// FAIL lines) for the UI, drop the noisy pip/curl chatter.
    private func ingest(_ text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // strip ANSI colour codes setup.sh emits (\033[1;35m … \033[0m)
            let clean = trimmed.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            guard clean.hasPrefix("==>") || clean.lowercased().hasPrefix("warn:")
                || clean.lowercased().hasPrefix("fail:") || clean.contains("Setup summary")
            else { continue }
            let display = clean.replacingOccurrences(of: "==> ", with: "")
            logLines.append(display)
            if logLines.count > 40 { logLines.removeFirst(logLines.count - 40) }
        }
    }

    private func finish(status: Int32) {
        process = nil
        accessibilityGranted = AXIsProcessTrusted()
        Task { @MainActor in
            // setup.sh can exit 0 yet the engine still be warming; confirm.
            let engineUp = !(await Self.engineIsDown(client: client))
            if status == 0 && engineUp {
                logLines.append("Voice engine ready.")
                phase = .succeeded
            } else if status == 0 {
                // Script succeeded but engine not yet answering — usually the
                // model is still downloading. Treat as success; it'll come up.
                logLines.append("Setup finished — the voice model may still be downloading.")
                phase = .succeeded
            } else {
                phase = .failed("Setup exited with code \(status). See the log above.")
            }
        }
    }

    // MARK: - accessibility

    /// Prompt for Accessibility (shows the system dialog). The app needs it for
    /// the global hotkey + reading the current selection.
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Re-read shortly after; the user may grant it in System Settings.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.accessibilityGranted = AXIsProcessTrusted()
        }
    }

    // MARK: - bundled script

    /// Path to the `setup.sh` bundled in the app's Resources/setup folder.
    static func bundledScriptPath() -> String? {
        Bundle.main.url(forResource: "setup", withExtension: "sh", subdirectory: "setup")?.path
            ?? Bundle.main.url(forResource: "setup", withExtension: "sh")?.path
    }
}
