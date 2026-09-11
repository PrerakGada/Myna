// SetupController.swift — drives Myna's first-launch installer.
//
// Myna downloads as a single app; its voice (the daemon, the MLX engine and
// the Kokoro model) installs on first launch. This runs the bundled setup.sh,
// turns its `@@step <id> <state> [note]` lines into the step list SetupView
// draws, keeps the `==>` lines for the details panel, and mirrors the full
// output to ~/Library/Logs/Myna/setup.log.
//
// Mirrors OnboardingController's shape: @MainActor ObservableObject with a
// `phase` the window observes.
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

    /// setup.sh's steps, in the order it runs them.
    public enum StepID: String, CaseIterable, Sendable {
        case check, runtime, engine, service, model, claude
    }

    /// Raw values are the states setup.sh prints.
    public enum StepStatus: String, Equatable, Sendable {
        case pending
        case running = "start"
        case done
        case skipped = "skip"
        case failed = "fail"
    }

    public struct Step: Identifiable, Equatable, Sendable {
        public let id: StepID
        public var status: StepStatus
        /// setup.sh's note once the step ends: "macOS 26.6", "Already installed", an error.
        public var note: String
    }

    public struct StepEvent: Equatable, Sendable {
        public let id: StepID
        public let status: StepStatus
        public let note: String
    }

    /// Where this copy of Myna is running from.
    public enum Location: Equatable, Sendable {
        case installed
        /// Straight off the disk image, or translocated by Gatekeeper: this copy
        /// goes away when the image is ejected.
        case temporary
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var steps: [Step] = SetupController.pendingSteps()
    /// `==>`, warn and FAIL lines, newest last.
    @Published public private(set) var logLines: [String] = []
    /// The latest `==>` line: what setup is doing right now.
    @Published public private(set) var activity = ""
    @Published public private(set) var elapsedSeconds = 0
    @Published public private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published public private(set) var location = SetupController.currentLocation()
    @Published public private(set) var moveError: String?

    private let log = Log(.app)
    private var process: Process?
    /// Elapsed-time ticker while running; Accessibility watcher after success.
    private var ticker: Task<Void, Never>?

    public init() {}

    /// Whether setup looks incomplete right now: the daemon is unreachable or
    /// its engine is down. AppDelegate uses this to present the installer.
    public static func engineIsDown(client: DaemonClient?) async -> Bool {
        guard let client else { return false }
        do { return try await client.health().engineUp == false } catch { return true }
    }

    // MARK: - run

    public func runSetup() {
        guard phase != .running else { return }
        guard let script = Self.bundledScriptPath() else {
            phase = .failed("This copy of Myna is missing its setup files. Download Myna again from myna.prerakgada.in.")
            return
        }
        steps = Self.pendingSteps()
        logLines = []
        activity = ""
        phase = .running
        startTicker()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script]
        task.environment = Self.scriptEnvironment()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let output = ScriptOutput(
            logHandle: SetupLog.open(title: "setup"),
            onLines: { [weak self] lines in
                Task { @MainActor [weak self] in self?.ingest(lines) }
            },
            onExit: { [weak self] status in
                Task { @MainActor [weak self] in self?.finish(status: status) }
            }
        )
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            output.receive(data)
        }
        task.terminationHandler = { finished in output.exited(finished.terminationStatus) }
        process = task
        do {
            try task.run()
            log.info("SetupController: launched setup.sh")
        } catch {
            stopTicker()
            phase = .failed("Couldn't start setup: \(error.localizedDescription)")
        }
    }

    private func ingest(_ lines: [String]) {
        for raw in lines {
            let line = Self.stripANSI(raw).trimmingCharacters(in: .whitespaces)
            if let event = Self.parseStep(line) {
                apply(event)
            } else if line.hasPrefix("==>") {
                let text = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                activity = text
                appendLog(text)
            } else if line.lowercased().hasPrefix("warn:") || line.hasPrefix("FAIL:") {
                appendLog(line)
            }
        }
    }

    private func apply(_ event: StepEvent) {
        guard let index = steps.firstIndex(where: { $0.id == event.id }) else { return }
        steps[index].status = event.status
        steps[index].note = event.status == .running ? "" : event.note
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    private func finish(status: Int32) {
        process = nil
        stopTicker()
        accessibilityGranted = AXIsProcessTrusted()
        if status == 0 {
            for index in steps.indices where steps[index].status == .running {
                steps[index].status = .done
            }
            phase = .succeeded
            log.info("SetupController: setup finished")
            watchAccessibility()
            return
        }
        for index in steps.indices where steps[index].status == .running {
            steps[index].status = .failed
        }
        let stepNote = steps.first { $0.status == .failed }?.note ?? ""
        let failLine = logLines.last { $0.hasPrefix("FAIL:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        let message = stepNote.isEmpty ? (failLine ?? "Setup stopped with exit code \(status).") : stepNote
        phase = .failed(message)
        log.warn("SetupController: setup failed (\(status)): \(message)")
    }

    // MARK: - timers

    private func startTicker() {
        stopTicker()
        elapsedSeconds = 0
        let started = Date()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.elapsedSeconds = Int(Date().timeIntervalSince(started))
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    /// Polls until Accessibility is granted, so the window updates the moment
    /// the user flips the switch in System Settings.
    private func watchAccessibility() {
        stopTicker()
        guard !accessibilityGranted else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.accessibilityGranted = true
                    return
                }
            }
        }
    }

    /// Stops the timers. The launcher calls this when the window closes; a
    /// running install carries on in the background.
    public func close() {
        stopTicker()
    }

    // MARK: - accessibility

    /// Shows the system Accessibility prompt. The app needs it to copy the
    /// current selection for the read hotkey and gestures.
    public func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        watchAccessibility()
    }

    // MARK: - parsing

    /// Parses `@@step <id> <start|done|skip|fail> [note]`.
    nonisolated static func parseStep(_ line: String) -> StepEvent? {
        guard line.hasPrefix("@@step ") else { return nil }
        let parts = line.split(separator: " ", maxSplits: 3)
        guard parts.count >= 3,
              let id = StepID(rawValue: String(parts[1])),
              let status = StepStatus(rawValue: String(parts[2])),
              status != .pending
        else { return nil }
        let note = parts.count == 4 ? parts[3].trimmingCharacters(in: .whitespaces) : ""
        return StepEvent(id: id, status: status, note: note)
    }

    nonisolated static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    nonisolated static func pendingSteps() -> [Step] {
        StepID.allCases.map { Step(id: $0, status: .pending, note: "") }
    }

    // MARK: - bundled script

    /// Path to the `setup.sh` bundled in the app's Resources/setup folder.
    nonisolated static func bundledScriptPath() -> String? {
        Bundle.main.url(forResource: "setup", withExtension: "sh", subdirectory: "setup")?.path
            ?? Bundle.main.url(forResource: "setup", withExtension: "sh")?.path
    }

    /// GUI apps get a minimal PATH; add Homebrew's so setup.sh can find `brew`
    /// on Macs that installed Myna with it.
    nonisolated static func scriptEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = extra + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return env
    }
}

// MARK: - location

extension SetupController {
    nonisolated static func currentLocation(bundleURL: URL = Bundle.main.bundleURL) -> Location {
        if bundleURL.path.contains("/AppTranslocation/") { return .temporary }
        let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true ? .temporary : .installed
    }

    /// Copies this app into /Applications and relaunches from there.
    public func moveToApplications() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/Myna.app")
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try manager.copyItem(at: source, to: destination)
        } catch {
            moveError = "Couldn't copy Myna into Applications. Drag it there from the disk image, then open it again."
            log.warn("SetupController: move to Applications failed: \(error.localizedDescription)")
            return
        }
        // The copy keeps the download's quarantine flag, and a quarantined app
        // opened from somewhere the user didn't drag it gets translocated again.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        try? xattr.run()
        xattr.waitUntilExit()

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            let opened = error == nil
            Task { @MainActor in
                if opened { NSApp.terminate(nil) }
            }
        }
        log.info("SetupController: copied Myna to /Applications, relaunching")
    }
}

// MARK: - output collection

/// Collects setup.sh output off the main thread. Splits it into whole lines
/// and reports the exit status only once the pipe has drained, so the last
/// step lines always arrive before `finish`.
private final class ScriptOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var partial = Data()
    private var reachedEnd = false
    private var exitStatus: Int32?
    private var reported = false
    private let logHandle: FileHandle?
    private let onLines: @Sendable ([String]) -> Void
    private let onExit: @Sendable (Int32) -> Void

    init(
        logHandle: FileHandle?,
        onLines: @escaping @Sendable ([String]) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.logHandle = logHandle
        self.onLines = onLines
        self.onExit = onExit
    }

    /// From the pipe's readability handler; empty data means end of file.
    func receive(_ data: Data) {
        lock.lock()
        var lines: [String] = []
        if data.isEmpty {
            reachedEnd = true
            if !partial.isEmpty {
                lines.append(String(bytes: partial, encoding: .utf8) ?? "")
                partial.removeAll()
            }
        } else {
            try? logHandle?.write(contentsOf: data)
            partial.append(data)
            while let newline = partial.firstIndex(of: 0x0A) {
                lines.append(String(bytes: partial[partial.startIndex..<newline], encoding: .utf8) ?? "")
                partial.removeSubrange(partial.startIndex...newline)
            }
        }
        let status = takeStatusIfDrained()
        lock.unlock()
        if !lines.isEmpty { onLines(lines) }
        if let status { onExit(status) }
    }

    /// From the process's termination handler.
    func exited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        let ready = takeStatusIfDrained()
        lock.unlock()
        if let ready {
            onExit(ready)
            return
        }
        // Safety net: if a stray child keeps the pipe open, report anyway.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            receive(Data())
        }
    }

    /// Caller holds the lock.
    private func takeStatusIfDrained() -> Int32? {
        guard reachedEnd, let exitStatus, !reported else { return nil }
        reported = true
        try? logHandle?.close()
        return exitStatus
    }
}
