// AdvancedTab.swift — log level picker, "Open Logs Folder" button,
// "Clear Cache" button, "Reset All Settings".
import AppKit
import SwiftUI

public struct AdvancedTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var resetConfirming = false
    @State private var lastAction: String?

    // Floating-pill master toggle (Lane A, v0.2.x). Default ON.
    // Persisted under the same dev.myna.app.* keyspace as the other
    // settings; not modelled in SettingsViewModel because the pill
    // module reads the raw UserDefaults key directly to avoid a
    // dependency on SettingsViewModel from FloatingPill.
    @AppStorage("dev.myna.app.showFloatingPill") private var showFloatingPill: Bool = true

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("Floating pill") {
                Toggle("Show floating pill while speaking", isOn: $showFloatingPill)
                Text("A small chip appears at the bottom of your active display when Myna is speaking. Hover to expand into a mini-player.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Logging") {
                Picker("Level:", selection: $viewModel.logLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level.rawValue)
                    }
                }
                Button("Open Logs folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LogFileMirror.shared.currentLogURL])
                }
            }
            Section("Cache") {
                Button("Clear cache") {
                    let ok = viewModel.clearCache()
                    lastAction = ok ? "cleared ~/Library/Caches/Myna/" : "could not clear cache"
                }
            }
            Section("Reset") {
                Button("Reset all settings") { resetConfirming = true }
                    .foregroundStyle(.red)
                    .confirmationDialog(
                        "Reset every Myna preference?",
                        isPresented: $resetConfirming,
                        titleVisibility: .visible
                    ) {
                        Button("Reset", role: .destructive) {
                            viewModel.resetAll()
                            lastAction = "all settings reset to defaults"
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            }
            if let lastAction {
                Section {
                    Text(lastAction).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 460, height: 400)
    }
}
