// SettingsView.swift — TabView with the four Settings tabs.
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let client: DaemonClient
    /// Optional sink the Voice tab uses to duck during preview (S09).
    weak var audioSink: (any AudioDuckable)?

    public init(viewModel: SettingsViewModel, client: DaemonClient, audioSink: (any AudioDuckable)? = nil) {
        self.viewModel = viewModel
        self.client = client
        self.audioSink = audioSink
    }

    public var body: some View {
        TabView {
            HotkeysTab()
                .tabItem { Label("Hotkeys", systemImage: "keyboard") }
            VoiceTab(viewModel: viewModel, client: client, audioSink: audioSink)
                .tabItem { Label("Voice", systemImage: "waveform") }
            BehaviorTab(viewModel: viewModel)
                .tabItem { Label("Behavior", systemImage: "sparkles") }
            DaemonTab(viewModel: viewModel, client: client)
                .tabItem { Label("Daemon", systemImage: "server.rack") }
            AdvancedTab(viewModel: viewModel)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540, height: 420)
    }
}
