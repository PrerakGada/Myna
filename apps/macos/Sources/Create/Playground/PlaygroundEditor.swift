// PlaygroundEditor.swift — the text area, its counts, and the samples.
//
// An NSTextView rather than SwiftUI's TextEditor, for two reasons:
//   • TextEditor's NSTextView takes every file drop itself and inserts
//     the path, so "drop a .txt onto it to load it" can't be done from
//     SwiftUI's .onDrop.
//   • Replacing the text (a sample, a dropped file, "Use this text") goes
//     through shouldChangeText/didChangeText, so ⌘Z brings back what you
//     had typed.
// Autocorrect, smart quotes and text replacement are off: the text is
// spoken exactly as written, and silently "fixing" pasted text would
// change what the voice says.
import AppKit
import SwiftUI

struct PlaygroundEditorCard: View {
    @ObservedObject var model: PlaygroundModel
    @ObservedObject var draft: PlaygroundDraft
    let onSendToStudio: () -> Void

    static let editorHeight: CGFloat = 180

    var body: some View {
        let stats = PlaygroundText.stats(for: draft.text, speed: model.effectiveSpeed ?? 1)
        DashCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    PlaygroundTextView(text: $draft.text) { urls in
                        model.textForDroppedFiles(urls)
                    }
                    if draft.text.isEmpty {
                        Text("Type or paste text here, or drop a .txt or .md file.")
                            .font(.system(size: 14))
                            .foregroundStyle(DashboardDesign.tertiary)
                            .padding(.horizontal, PlaygroundTextView.inset.width + 5)
                            .padding(.vertical, PlaygroundTextView.inset.height)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: Self.editorHeight)

                DashDivider()
                footer(stats)
                if stats.isOverLimit {
                    DashDivider()
                    overLimit(stats)
                }
            }
        }
    }

    private func footer(_ stats: PlaygroundText.Stats) -> some View {
        HStack(spacing: 10) {
            Text(countsLine(stats))
                .font(DashboardDesign.captionFont.monospacedDigit())
                .foregroundStyle(nearLimit(stats) ? DashboardDesign.warning : DashboardDesign.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Spoken length is an estimate at about \(Int(PlaygroundText.wordsPerMinute)) words a minute.")
            Spacer(minLength: 8)
            Menu {
                ForEach(PlaygroundText.samples) { sample in
                    Button(sample.title) { draft.text = sample.text }
                }
            } label: {
                Label("Samples", systemImage: "text.quote")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Replace the text with a short sample for trying voices")
            Button {
                draft.text = ""
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .disabled(draft.text.isEmpty)
            .help("Clear the text. ⌘Z brings it back.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func countsLine(_ stats: PlaygroundText.Stats) -> String {
        let chars = PlaygroundText.grouped(stats.characters)
        let words = PlaygroundText.grouped(stats.words)
        let wordNoun = stats.words == 1 ? "word" : "words"
        return "\(chars) characters · \(words) \(wordNoun) · \(PlaygroundText.estimateLabel(stats.estimatedSeconds))"
    }

    private func nearLimit(_ stats: PlaygroundText.Stats) -> Bool {
        Double(stats.characters) > Double(PlaygroundText.syncCharacterLimit) * 0.9
    }

    private func overLimit(_ stats: PlaygroundText.Stats) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DashboardDesign.warning)
            Text(
                "That's \(PlaygroundText.grouped(stats.characters)) characters. One take holds up to "
                    + "\(PlaygroundText.grouped(PlaygroundText.syncCharacterLimit)). Studio renders "
                    + "longer text into an audio file in the background."
            )
            .font(DashboardDesign.captionFont)
            .foregroundStyle(DashboardDesign.body)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Send to Studio", action: onSendToStudio)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - the text view

struct PlaygroundTextView: NSViewRepresentable {
    @Binding var text: String
    /// Text for dropped .txt/.md files, or nil to refuse the drop.
    let onDropFiles: @MainActor ([URL]) -> String?

    static let inset = NSSize(width: 10, height: 10)

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // Apple's recipe for a text view in a scroll view: size the scroll
        // view first, then make the text view exactly its content size.
        // Autoresizing keeps whatever offset the two start with, so a text
        // view wider than its clip view would wrap text off the right edge.
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let contentSize = scroll.contentSize

        let textView = PlaygroundDropTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = Self.inset

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = NSColor(white: 1, alpha: 0.9)
        textView.insertionPointColor = NSColor(white: 1, alpha: 0.9)
        textView.drawsBackground = false
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor(white: 1, alpha: 0.9),
        ]
        textView.setAccessibilityLabel("Text to speak")
        textView.string = text
        textView.delegate = context.coordinator
        textView.onFileDrop = onDropFiles

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? PlaygroundDropTextView else { return }
        textView.onFileDrop = onDropFiles
        guard textView.string != text else { return }
        // The model changed the text (a sample, Clear, "Use this text").
        // Replace it as an edit so it can be undone, without echoing the
        // change back into the binding mid-update.
        context.coordinator.isApplyingModelText = true
        textView.replaceAllText(with: text)
        context.coordinator.isApplyingModelText = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var isApplyingModelText = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingModelText, let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// NSTextView that loads dropped .txt/.md files instead of inserting
/// their paths. Everything else (dragged text, pictures) behaves as usual.
final class PlaygroundDropTextView: NSTextView {
    var onFileDrop: (@MainActor ([URL]) -> String?)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        textFiles(in: sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        textFiles(in: sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = textFiles(in: sender)
        guard !files.isEmpty else { return super.performDragOperation(sender) }
        guard let text = onFileDrop?(files) else { return false }
        replaceAllText(with: text)
        window?.makeFirstResponder(self)
        return true
    }

    /// Replaces everything as one undoable edit and returns to the top.
    func replaceAllText(with text: String) {
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard shouldChangeText(in: whole, replacementString: text) else { return }
        replaceCharacters(in: whole, with: text)
        didChangeText()
        let start = NSRange(location: 0, length: 0)
        setSelectedRange(start)
        scrollRangeToVisible(start)
    }

    private func textFiles(in info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { PlaygroundText.droppableExtensions.contains($0.pathExtension.lowercased()) }
    }
}
