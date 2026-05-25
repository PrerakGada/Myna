// VoiceTab.swift — voice picker (queries DaemonClient.voices()),
// default speed slider, summary mode toggle.
import SwiftUI

public struct VoiceTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    let client: DaemonClient
    @State private var voices: [Voice] = []
    @State private var refreshing = false
    @State private var errorMessage: String?

    public init(viewModel: SettingsViewModel, client: DaemonClient) {
        self.viewModel = viewModel
        self.client = client
    }

    public var body: some View {
        Form {
            Section("Voice") {
                Picker("Voice:", selection: $viewModel.voice) {
                    if voices.isEmpty {
                        Text(viewModel.voice).tag(viewModel.voice)
                    } else {
                        ForEach(voices) { voice in
                            Text(voice.label).tag(voice.id)
                        }
                    }
                }
                Button(refreshing ? "Refreshing…" : "Refresh voice list") {
                    Task { await refresh() }
                }
                .disabled(refreshing)
                if let err = errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Playback defaults") {
                Slider(value: $viewModel.defaultSpeed, in: 0.5...2.0, step: 0.05) {
                    Text("Default speed: \(viewModel.defaultSpeed, format: .number.precision(.fractionLength(2)))×")
                }
                Toggle("Summarize before speaking by default", isOn: $viewModel.summaryMode)
            }
        }
        .padding()
        .frame(width: 460, height: 280)
        .task { await refresh() }
    }

    private func refresh() async {
        refreshing = true
        errorMessage = nil
        defer { refreshing = false }
        do {
            voices = try await client.voices(forceRefresh: true)
        } catch {
            errorMessage = "could not load voices: \(error)"
        }
    }
}
