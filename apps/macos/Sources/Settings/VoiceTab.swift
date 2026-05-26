// VoiceTab.swift — voice picker (queries DaemonClient.voices()) with
// a per-voice ▶ Preview button (S09). Preview behaviour:
//
//   • Click ▶ → fetch + play short sample at -6dB
//   • Main playback ducks to 30% during preview (AudioDuckable)
//   • Switching voices mid-preview cancels the in-flight one within 100ms
//   • Closing Settings stops any active preview
//   • Engine 503 → inline "Engine warming…" for 2s
//
// VoicePreviewService owns the orchestration; this view just binds.
import SwiftUI

public struct VoiceTab: View {
    @ObservedObject var viewModel: SettingsViewModel
    let client: DaemonClient
    /// Optional audio sink (the main AudioPlayer) so preview can duck it
    /// to 30% per S09. AppDelegate injects this; tests can pass nil.
    private weak var audioSink: (any AudioDuckable)?

    @State private var voices: [Voice] = []
    @State private var refreshing = false
    @State private var errorMessage: String?
    @StateObject private var previewService: VoicePreviewService

    public init(
        viewModel: SettingsViewModel,
        client: DaemonClient,
        audioSink: (any AudioDuckable)? = nil
    ) {
        self.viewModel = viewModel
        self.client = client
        self.audioSink = audioSink
        _previewService = StateObject(
            wrappedValue: VoicePreviewService(client: client, sink: audioSink)
        )
    }

    public var body: some View {
        Form {
            Section("Voice") {
                if voices.isEmpty {
                    HStack {
                        Text(viewModel.voice)
                        Spacer()
                        if refreshing { Text("Refreshing…").foregroundStyle(.secondary) }
                    }
                } else {
                    ForEach(voices) { voice in
                        voiceRow(voice)
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
        .frame(width: 460, height: 360)
        .task { await refresh() }
        .onDisappear {
            previewService.cancel()
        }
    }

    private func voiceRow(_ voice: Voice) -> some View {
        HStack {
            Button {
                viewModel.voice = voice.id
            } label: {
                HStack {
                    Text(voice.label)
                    if viewModel.voice == voice.id {
                        Text("✓").foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            Spacer()
            inlineWarmingLabel(for: voice)
            Button {
                previewService.preview(voiceId: voice.id)
            } label: {
                Image(systemName: isPlayingPreview(voice) ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview \(voice.label) voice")
        }
    }

    @ViewBuilder
    private func inlineWarmingLabel(for voice: Voice) -> some View {
        if case .warming(let id) = previewService.state, id == voice.id {
            Text("Engine warming…")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .transition(.opacity)
        } else if case .failed(let id, _) = previewService.state, id == voice.id {
            Text("Couldn't preview")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }

    private func isPlayingPreview(_ voice: Voice) -> Bool {
        switch previewService.state {
        case .loading(let id), .playing(let id):
            return id == voice.id
        default:
            return false
        }
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
