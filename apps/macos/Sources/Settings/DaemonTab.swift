// DaemonTab.swift — daemon URL + port fields (validate localhost-only),
// engine URL + port, "Restart Daemon" button (runs launchctl unload &&
// load), health indicator.
import Foundation
import SwiftUI

public struct DaemonTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    let client: DaemonClient
    @State private var health: HealthResponse?
    @State private var healthError: String?
    @State private var checking = false
    @State private var restartOutput: String?

    public init(viewModel: SettingsViewModel, client: DaemonClient) {
        self.viewModel = viewModel
        self.client = client
    }

    public var body: some View {
        Form {
            Section("Daemon") {
                TextField("Base URL:", text: $viewModel.daemonURL)
                    .onSubmit { viewModel.setDaemonURL(viewModel.daemonURL) }
                if let err = viewModel.daemonURLError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
                TextField("Port:", value: $viewModel.daemonPort, format: .number)
                healthRow
                Button("Restart daemon") {
                    Task { await restartDaemon() }
                }
                .disabled(restartOutput == "running…")
                if let restartOutput {
                    Text(restartOutput).font(.caption)
                }
            }
            Section("TTS engine (Kokoro)") {
                TextField("Base URL:", text: $viewModel.engineURL)
                TextField("Port:", value: $viewModel.enginePort, format: .number)
            }
        }
        .padding()
        .frame(width: 460, height: 360)
        .task { await checkHealth() }
    }

    @ViewBuilder
    private var healthRow: some View {
        HStack {
            Circle()
                .fill(healthColor)
                .frame(width: 10, height: 10)
            Text(healthLabel)
            Spacer()
            Button("Recheck") { Task { await checkHealth() } }
                .disabled(checking)
        }
    }

    private var healthLabel: String {
        if let healthError { return "error: \(healthError)" }
        guard let health else { return checking ? "checking…" : "unknown" }
        return "daemon v\(health.version), engine \(health.engineUp ? "up" : "down")"
    }

    private var healthColor: Color {
        if let health { return health.ok ? (health.engineUp ? .green : .yellow) : .red }
        return .gray
    }

    private func checkHealth() async {
        checking = true
        healthError = nil
        defer { checking = false }
        do {
            health = try await client.health()
        } catch {
            health = nil
            healthError = String(describing: error)
        }
    }

    private func restartDaemon() async {
        restartOutput = "running…"
        let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/dev.myna.daemon.plist"
        let unload = await runShell("/bin/launchctl unload \(plistPath)")
        let load = await runShell("/bin/launchctl load \(plistPath)")
        restartOutput = "unload: \(unload.0), load: \(load.0)"
        await checkHealth()
    }

    private func runShell(_ command: String) async -> (Int32, String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            let process = Process()
            process.launchPath = "/bin/sh"
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            } catch {
                continuation.resume(returning: (-1, String(describing: error)))
            }
        }
    }
}
