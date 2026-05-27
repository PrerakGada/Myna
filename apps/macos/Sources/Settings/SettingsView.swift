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
            VoiceWardrobeView(client: client)
                .tabItem { Label("Wardrobe", systemImage: "person.crop.rectangle.stack") }
            BehaviorTab(viewModel: viewModel)
                .tabItem { Label("Behavior", systemImage: "sparkles") }
            GesturesTab(viewModel: viewModel)
                .tabItem { Label("Gestures", systemImage: "hand.tap") }
            DaemonTab(viewModel: viewModel, client: client)
                .tabItem { Label("Daemon", systemImage: "server.rack") }
            AdvancedTab(viewModel: viewModel)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        // Frame sized for the largest tab (Wardrobe with rows + add button).
        // Bumped 540×420 → 560×440 when Wardrobe and Gestures tabs were added.
        .frame(width: 560, height: 440)
    }
}
