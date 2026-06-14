// SetupView.swift — the "Finish setup" window UI. Shows what setup will do,
// runs it on a tap, streams live progress, and ends with an Accessibility
// nudge. Dark, card-based, matched to the onboarding look.
import SwiftUI

struct SetupView: View {
    @ObservedObject var controller: SetupController
    /// Closes the window (wired by SetupWindow).
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                content
                Spacer(minLength: 0)
                footer
            }
            .padding(28)
        }
        .frame(width: 560, height: 440)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bird.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(
                    LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish setting up Myna")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("One-time install of the on-device voice engine.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Self.steps, id: \.title) { step in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                            Text(step.detail).font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    } icon: {
                        Image(systemName: step.icon).foregroundStyle(Color.accentColor)
                            .frame(width: 20)
                    }
                }
                Text("Everything runs locally on your Mac. Takes a few minutes the first time.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 2)
            }
        case .running, .succeeded, .failed:
            logPanel
        }
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.phase == .running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing… this can take a few minutes.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(controller.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }.padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                .frame(maxHeight: 180)
                .onChange(of: controller.logLines.count) { n in
                    withAnimation { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
            if case .failed(let msg) = controller.phase {
                Text(msg).font(.system(size: 11)).foregroundStyle(.red.opacity(0.85))
            }
            if controller.phase == .succeeded && !controller.accessibilityGranted {
                Text("Last step: grant Accessibility so the read-aloud hotkey can see your selection.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch controller.phase {
            case .idle:
                Button("Not now", action: onClose).buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                primary("Install voice engine") { controller.runSetup() }
            case .running:
                primaryDisabled("Installing…")
            case .failed:
                Button("Close", action: onClose).buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                primary("Retry") { controller.runSetup() }
            case .succeeded:
                if controller.accessibilityGranted {
                    primary("Done", action: onClose)
                } else {
                    Button("Done", action: onClose).buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.5))
                    primary("Grant Accessibility") { controller.requestAccessibility() }
                }
            }
        }
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(Color.accentColor)).foregroundStyle(.white)
        }.buttonStyle(.plain)
    }

    private func primaryDisabled(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Color.accentColor.opacity(0.4))).foregroundStyle(.white.opacity(0.7))
    }

    private struct Step { let icon: String; let title: String; let detail: String }
    private static let steps = [
        Step(icon: "waveform", title: "Install the voice engine",
             detail: "mlx-audio + the Kokoro voice model (~340 MB), Apple-Silicon native"),
        Step(icon: "bolt.horizontal.circle", title: "Start the background services",
             detail: "the daemon + engine that turn text into speech, all on-device"),
        Step(icon: "sparkles", title: "Connect Claude Code",
             detail: "registers the hook so finished Claude replies can be read aloud"),
    ]
}
