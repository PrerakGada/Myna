// FeedbackView.swift — the form behind "Report a Problem…" and
// "Send Feedback…". Copy and layout follow the shared spec in
// work/company/infra/product-feedback.md; keep them identical across apps.
import AppKit
import SwiftUI

/// State for one feedback window. Lives only as long as the window, so a
/// name or email typed here is never persisted.
@MainActor
final class FeedbackFormModel: ObservableObject {
    enum Phase: Equatable {
        case editing
        case sending
        case sent
    }

    @Published var kind: FeedbackKind
    @Published var message = ""
    @Published var name = ""
    @Published var email = ""
    @Published private(set) var phase: Phase = .editing
    @Published private(set) var errorText: String?

    let context: FeedbackContext
    private let sender: any FeedbackSending
    private var sendTask: Task<Void, Never>?

    init(kind: FeedbackKind, context: FeedbackContext, sender: any FeedbackSending) {
        self.kind = kind
        self.context = context
        self.sender = sender
    }

    var canSend: Bool { phase == .editing && FeedbackDraft.hasEnoughText(message) }

    /// Sends once. Success swaps the form for the thank-you; failure shows the
    /// error inline and keeps everything typed.
    func send() {
        guard canSend else { return }
        let draft = FeedbackDraft(kind: kind, message: message, name: name, email: email)
        phase = .sending
        errorText = nil
        sendTask = Task { [weak self, sender, context] in
            do {
                _ = try await sender.send(draft, context: context)
                guard !Task.isCancelled else { return }
                self?.phase = .sent
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .editing
                self?.errorText = ((error as? FeedbackError) ?? .couldNotSend).message
            }
        }
    }

    /// Wait for the in-flight send (tests).
    func waitForSend() async {
        await sendTask?.value
    }

    /// The window closed: drop any in-flight send rather than finishing it
    /// in the background.
    func cancel() {
        sendTask?.cancel()
        sendTask = nil
    }

    /// The window was asked for again while still open.
    func prepare(for requested: FeedbackKind) {
        switch phase {
        case .sent:
            kind = requested
            message = ""
            name = ""
            email = ""
            errorText = nil
            phase = .editing
        case .editing where message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            kind = requested
        default:
            break  // keep what the user has typed
        }
    }
}

struct FeedbackView: View {
    @ObservedObject var model: FeedbackFormModel
    let onClose: () -> Void

    @FocusState private var messageFocused: Bool

    var body: some View {
        Group {
            if model.phase == .sent {
                sentView
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: FeedbackWindow.contentSize.width, height: FeedbackWindow.contentSize.height, alignment: .top)
    }

    // MARK: - form

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Inputs freeze while sending; Cancel stays live.
            VStack(alignment: .leading, spacing: 14) {
                Picker("Kind", selection: $model.kind) {
                    ForEach(FeedbackKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                MessageEditor(text: $model.message, placeholder: model.kind.placeholder)
                    .focused($messageFocused)
                    .frame(height: 160)

                contactFields
            }
            .disabled(model.phase == .sending)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.context.summary)
                    .textSelection(.enabled)
                Text("Goes straight to Prerak, who makes Myna. Nothing is sent until you press Send.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if let errorText = model.errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .onAppear {
            Task { @MainActor in messageFocused = true }
        }
    }

    private var contactFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your name").font(.callout)
                    // The label sits above; an empty prompt avoids repeating it inside.
                    TextField(text: $model.name, prompt: Text("")) { Text("Your name") }
                        .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Email").font(.callout)
                    TextField(text: $model.email, prompt: Text("")) { Text("Email") }
                        .labelsHidden()
                        .autocorrectionDisabled()
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("Optional. Add your email if you'd like a reply.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if model.phase == .sending {
                ProgressView()
                    .controlSize(.small)
                Text("Sending…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onClose)
                .keyboardShortcut(.cancelAction)
            // ⌘↩, not plain Return: Return has to start a new line in the message.
            Button(action: model.send) {
                Text("Send").frame(minWidth: 56)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSend)
            .help("Send (⌘↩)")
        }
    }

    // MARK: - sent

    private var sentView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Thanks, it's sent.")
                .font(.title3.weight(.semibold))
            Text("If you added your email, I may reply.")
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Multi-line message box with a placeholder (TextEditor has none on macOS 13).
private struct MessageEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            if text.isEmpty {
                // TextEditor insets its text by the 5pt line-fragment padding.
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .accessibilityLabel("Message")
    }
}
