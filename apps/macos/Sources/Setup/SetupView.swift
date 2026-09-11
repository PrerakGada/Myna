// SetupView.swift — Myna's first-launch installer window. Lists what setup
// will install, streams each step's progress, and ends on the Accessibility
// grant. Dark and card-based, matched to the onboarding window.
import AppKit
import KeyboardShortcuts
import SwiftUI

struct SetupView: View {
    @ObservedObject var controller: SetupController
    /// Closes the window (wired by SetupLauncher).
    let onClose: () -> Void
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsLocationBanner {
                locationBanner.padding(.top, 18)
            }
            Group {
                if showingDetails { detailsPanel } else { stepList }
            }
            .padding(.top, 20)
            Spacer(minLength: 14)
            footnote
            footer.padding(.top, 16)
        }
        .padding(.horizontal, 30)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(
            width: SetupWindow.size(for: controller.location).width,
            height: SetupWindow.size(for: controller.location).height
        )
        .background(backdrop)
        .preferredColorScheme(.dark)
    }

    // MARK: - header

    private var backdrop: some View {
        ZStack {
            PopoverDesign.surface
            RadialGradient(
                colors: [PopoverDesign.accent.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(PopoverDesign.bodyColor)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(PopoverDesign.secondaryColor)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch controller.phase {
        case .idle: "Welcome to Myna"
        case .running: "Setting up Myna"
        case .succeeded: "Myna is ready"
        case .failed: "Setup didn't finish"
        }
    }

    private var subtitle: String {
        switch controller.phase {
        case .idle:
            "Before Myna can speak, it downloads its voice: a speech engine and the Kokoro voice model. "
                + "Everything installs in your user account, no password needed."
        case .running:
            "This takes a few minutes. You can keep working while it runs."
        case .succeeded:
            "Select text in any app and press \(readShortcut) to hear it."
        case .failed(let message):
            message
        }
    }

    private var readShortcut: String {
        KeyboardShortcuts.getShortcut(for: .speakSelectionFull)?.description ?? "⌘⌥⇧S"
    }

    // MARK: - location banner

    private var showsLocationBanner: Bool {
        guard controller.location == .temporary else { return false }
        switch controller.phase {
        case .idle, .failed: return true
        case .running, .succeeded: return false
        }
    }

    private var locationBanner: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PopoverDesign.dotThinking)
            VStack(alignment: .leading, spacing: 2) {
                Text("Myna is running from the disk image")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PopoverDesign.bodyColor)
                Text(controller.moveError ?? "Move it to Applications first, so it's still here after you eject the image.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PopoverDesign.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            secondaryButton("Move to Applications") { controller.moveToApplications() }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(PopoverDesign.dotThinking.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(PopoverDesign.dotThinking.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - steps and details

    private var stepList: some View {
        VStack(spacing: 0) {
            ForEach(controller.steps) { step in
                SetupStepRow(step: step, copy: SetupStepCopy.copy(for: step.id), activity: controller.activity)
                if step.id != controller.steps.last?.id {
                    Rectangle()
                        .fill(PopoverDesign.cardBorder)
                        .frame(height: 1)
                        .padding(.leading, 46)
                }
            }
        }
        .padding(.vertical, 4)
        .background(card)
    }

    private var detailsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("FAIL") ? PopoverDesign.dotError : PopoverDesign.bodyColor.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .padding(12)
            }
            .frame(height: SetupWindow.listHeight)
            .background(card)
            .onChange(of: controller.logLines.count) { count in
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(PopoverDesign.cardSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(PopoverDesign.cardBorder, lineWidth: 1)
            )
    }

    // MARK: - footnote

    @ViewBuilder
    private var footnote: some View {
        switch controller.phase {
        case .idle:
            note(
                icon: "lock.fill",
                "About 1 GB in all, a few minutes on a good connection. What you read is spoken on this Mac and never sent anywhere."
            )
        case .running:
            note(icon: "clock", "Elapsed \(elapsed)")
        case .succeeded:
            accessibilityCard
        case .failed:
            note(icon: "doc.text", "Trying again picks up where setup stopped. The full log is in ~/Library/Logs/Myna/setup.log.")
        }
    }

    private func note(icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11.5).monospacedDigit())
        .foregroundStyle(PopoverDesign.secondaryColor)
    }

    private var elapsed: String {
        let seconds = controller.elapsedSeconds
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var accessibilityCard: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.accessibilityGranted ? "checkmark.circle.fill" : "hand.raised.fill")
                .font(.system(size: 18))
                .foregroundStyle(controller.accessibilityGranted ? PopoverDesign.dotSpeaking : PopoverDesign.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.accessibilityGranted ? "Accessibility is on" : "One last thing: allow Accessibility")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PopoverDesign.bodyColor)
                Text("Myna uses it to copy the text you select, so it can read it to you.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PopoverDesign.secondaryColor)
            }
            Spacer(minLength: 8)
            if !controller.accessibilityGranted {
                secondaryButton("Allow…") { controller.requestAccessibility() }
            }
        }
        .padding(12)
        .background(card)
    }

    // MARK: - footer

    private var footer: some View {
        HStack(spacing: 14) {
            if controller.phase != .idle {
                Button(showingDetails ? "Show steps" : "Show details") { showingDetails.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PopoverDesign.secondaryColor)
                    .focusable(false)
            }
            Spacer()
            switch controller.phase {
            case .idle:
                quietButton("Not now", cancels: true, action: onClose)
                primaryButton("Install") { controller.runSetup() }
            case .running:
                primaryButton("Installing…", enabled: false) {}
            case .succeeded:
                primaryButton("Continue", action: onClose)
            case .failed:
                quietButton("Reveal log") { NSWorkspace.shared.activateFileViewerSelecting([SetupLog.url]) }
                quietButton("Close", cancels: true, action: onClose)
                primaryButton("Try again") { controller.runSetup() }
            }
        }
    }

    private func primaryButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Capsule().fill(PopoverDesign.accent.opacity(enabled ? 1 : 0.4)))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.7))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
        // Return triggers it; without this the window opens with a focus
        // ring drawn around the first button instead.
        .focusable(false)
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .foregroundStyle(PopoverDesign.bodyColor)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    /// `cancels` binds Escape, since these buttons don't take keyboard focus.
    private func quietButton(_ title: String, cancels: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(PopoverDesign.secondaryColor)
            .keyboardShortcut(cancels ? .cancelAction : nil)
            .focusable(false)
    }
}

// MARK: - step row

/// What each step is called and what it downloads, before setup reports on it.
struct SetupStepCopy {
    let title: String
    let detail: String
    let size: String?

    static func copy(for id: SetupController.StepID) -> SetupStepCopy {
        switch id {
        case .check:
            SetupStepCopy(title: "Check this Mac", detail: "Apple Silicon and macOS 14 or later", size: nil)
        case .runtime:
            SetupStepCopy(title: "Python runtime", detail: "A private copy of Python, used only by Myna", size: "~40 MB")
        case .engine:
            SetupStepCopy(title: "Voice engine", detail: "MLX speech synthesis for Apple Silicon", size: "~600 MB")
        case .service:
            SetupStepCopy(title: "Background service", detail: "Keeps the voice ready and starts when you log in", size: nil)
        case .model:
            SetupStepCopy(title: "Kokoro voice", detail: "The voice model, downloaded once", size: "~370 MB")
        case .claude:
            SetupStepCopy(title: "Claude Code", detail: "Reads finished Claude replies aloud, if you use it", size: nil)
        }
    }
}

private struct SetupStepRow: View {
    let step: SetupController.Step
    let copy: SetupStepCopy
    let activity: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            indicator.frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PopoverDesign.bodyColor.opacity(step.status == .pending ? 0.7 : 1))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(step.status == .failed ? PopoverDesign.dotError : PopoverDesign.secondaryColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let size = copy.size, step.status == .pending || step.status == .running {
                Text(size)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(PopoverDesign.secondaryColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var detail: String {
        switch step.status {
        case .pending: copy.detail
        case .running: activity.isEmpty ? copy.detail : activity
        case .done, .skipped, .failed: step.note.isEmpty ? copy.detail : step.note
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch step.status {
        case .pending:
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                .frame(width: 14, height: 14)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(PopoverDesign.dotSpeaking)
        case .skipped:
            Image(systemName: "minus.circle")
                .font(.system(size: 16))
                .foregroundStyle(Color.white.opacity(0.35))
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(PopoverDesign.dotError)
        }
    }
}
