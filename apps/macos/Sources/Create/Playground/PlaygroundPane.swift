// PlaygroundPane.swift — Myna as a text-to-speech tool you use directly.
//
// Everything else in Myna reads text out of other apps. Here you type or
// paste text, hear it in any voice of the active engine, tune the speed,
// render the same text in several voices to compare them, keep the takes
// you like and save them as audio files.
//
// Layout, top to bottom: a notice line when something needs saying, the
// editor, the controls, the takes. Parts:
//   PlaygroundModel      state + rendering (one per app run)
//   PlaygroundEditor     the text area, counts, samples, file drop
//   PlaygroundControls   voice, speed, Generate, Compare
//   PlaygroundTakesView  takes and comparisons
//   PlaygroundTakeStore  takes on disk; PlaygroundPlayer plays them
//
// Keys: ⌘↩ generates (the Generate button's shortcut). Space plays or
// pauses the selected take, ⌘S saves it and Esc cancels a render; those
// come from a local key monitor installed while this pane is on screen,
// because Space must go to the text area when you are typing, and SwiftUI
// on macOS 13 has no focus-aware way to say that.
import AppKit
import SwiftUI

struct PlaygroundPane: View {
    let context: DashboardContext
    @ObservedObject var launcher: DashboardLauncher

    var body: some View {
        PlaygroundScreen(model: PlaygroundModel.session(for: context), launcher: launcher)
    }
}

private struct PlaygroundScreen: View {
    @ObservedObject var model: PlaygroundModel
    let launcher: DashboardLauncher

    @StateObject private var keys = PlaygroundKeyMonitor()

    var body: some View {
        PaneScaffold(
            title: DashboardPane.playground.title,
            subtitle: DashboardPane.playground.subtitle
        ) {
            PlaygroundEngineBadge(model: model) { launcher.pane = .daemon }
        } content: {
            VStack(alignment: .leading, spacing: DashboardDesign.gridSpacing) {
                if model.engineState == .unreachable {
                    unreachableBanner
                }
                if let notice = model.notice {
                    PlaygroundNoticeBanner(
                        notice: notice,
                        onAction: perform,
                        onDismiss: { model.notice = nil }
                    )
                }
                PlaygroundEditorCard(model: model, draft: model.draft, onSendToStudio: sendToStudio)
                PlaygroundControlsCard(model: model, draft: model.draft)
                PlaygroundTakesSection(model: model, store: model.store, player: model.player)
            }
        }
        .task { await model.refresh() }
        .onAppear {
            // Each handler checks the pane too: the monitor is removed on
            // disappear, but a stray one must never act on another pane.
            keys.install(
                onSpace: { launcher.pane == .playground && model.toggleSelectedPlayback() },
                onSave: {
                    guard launcher.pane == .playground, model.selectedTake != nil, !model.isSaving else {
                        return false
                    }
                    // Open the save panel after this key event, not inside it.
                    Task { @MainActor in model.saveSelected() }
                    return true
                },
                onEscape: {
                    guard launcher.pane == .playground, model.isBusy else { return false }
                    model.cancel()
                    return true
                }
            )
        }
        .onDisappear {
            keys.remove()
            model.player.stop()
        }
    }

    private var unreachableBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bolt.horizontal.circle")
                .foregroundStyle(DashboardDesign.negative)
            Text("Myna's voice service isn't answering, so there are no voices to choose from. "
                + "Engine shows what's wrong and can restart it.")
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Try Again") { Task { await model.refresh() } }
            Button("Open Engine") { launcher.pane = .daemon }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DashboardDesign.negative.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DashboardDesign.negative.opacity(0.3), lineWidth: 1)
        )
    }

    private func sendToStudio() {
        PlaygroundHandoff.pendingStudioText = model.draft.text
        launcher.pane = .studio
    }

    private func perform(_ action: PlaygroundNotice.Action) {
        switch action {
        case .openEngine: launcher.pane = .daemon
        case .sendToStudio: sendToStudio()
        case .openStudio: launcher.pane = .studio
        case .reveal(let url): PlaygroundExport.reveal(url)
        }
    }
}

// MARK: - header

/// Which engine renders, and the way to change it. The Playground never
/// switches engines itself: switching reloads models under a live read.
struct PlaygroundEngineBadge: View {
    @ObservedObject var model: PlaygroundModel
    let onOpenEngine: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch model.engineState {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Checking the engine…")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            case .unreachable:
                DashBadge("Engine not answering", tint: DashboardDesign.negative)
            case .ready:
                if let switching = model.switchingTo {
                    DashBadge("Switching to \(switching)…", tint: DashboardDesign.warning)
                } else {
                    DashBadge(model.engine?.name ?? "Engine ready", tint: DashboardDesign.positive)
                        .help("The active engine. Every take is rendered with it.")
                }
            }
            Button("Change Engine…", action: onOpenEngine)
                .help("Only the active engine renders. Switch it on the Engine page.")
        }
        .fixedSize()
    }
}

// MARK: - notice

struct PlaygroundNoticeBanner: View {
    let notice: PlaygroundNotice
    let onAction: (PlaygroundNotice.Action) -> Void
    let onDismiss: () -> Void

    private var tint: Color {
        notice.kind == .error ? DashboardDesign.negative : DashboardDesign.positive
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(notice.message)
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = notice.action {
                Button(action.title) { onAction(action) }
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardDesign.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - keys and focus

/// Space and ⌘S for the Playground, only in the Dashboard window and only
/// when no text view has the keyboard — so typing a space in the editor is
/// still a space. Esc cancels a render wherever the keyboard is: NSTextView
/// binds Esc to word completion, so the Cancel button's own shortcut would
/// never fire while you're typing.
@MainActor
final class PlaygroundKeyMonitor: ObservableObject {
    private var token: Any?

    static let spaceKeyCode: UInt16 = 49
    static let escapeKeyCode: UInt16 = 53

    /// Each handler returns true when it acted, which swallows the key.
    struct Handlers {
        let onSpace: @MainActor () -> Bool
        let onSave: @MainActor () -> Bool
        let onEscape: @MainActor () -> Bool
    }

    func install(
        onSpace: @escaping @MainActor () -> Bool,
        onSave: @escaping @MainActor () -> Bool,
        onEscape: @escaping @MainActor () -> Bool
    ) {
        remove()
        let handlers = Handlers(onSpace: onSpace, onSave: onSave, onEscape: onEscape)
        // Local monitors run on the main thread, inside NSApplication's
        // event dispatch, so this main-actor closure is safe here.
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.route(event, handlers) ? nil : event
        }
    }

    func remove() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private static func route(_ event: NSEvent, _ handlers: Handlers) -> Bool {
        guard let window = event.window, window is DashboardWindow, window.isKeyWindow else { return false }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == spaceKeyCode, flags.isEmpty {
            if window.firstResponder is NSText || event.isARepeat { return false }
            return handlers.onSpace()
        }
        if event.keyCode == escapeKeyCode, flags.isEmpty {
            return handlers.onEscape()
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
            return handlers.onSave()
        }
        return false
    }
}

enum PlaygroundFocus {
    /// Takes the keyboard away from the editor after a click on a take,
    /// so Space controls playback rather than typing into the text.
    @MainActor
    static func releaseEditor() {
        guard let window = NSApp.keyWindow, window is DashboardWindow,
              window.firstResponder is PlaygroundDropTextView
        else { return }
        window.makeFirstResponder(nil)
    }
}
