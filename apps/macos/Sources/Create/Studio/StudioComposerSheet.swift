// StudioComposerSheet.swift — the "New conversion" sheet: get the text
// in (paste, web page, files), then review it before rendering.
//
// A fixed-size sheet with its own scrolling, so it fits inside the
// Dashboard at its minimum size (900 × 600) whatever the document.
import SwiftUI

struct StudioComposerSheet: View {
    @ObservedObject var composer: StudioComposer
    let library: StudioLibrary
    let onChooseFiles: () -> Void
    let onClose: () -> Void

    static let width: CGFloat = 680
    static let height: CGFloat = 540

    var body: some View {
        VStack(spacing: 0) {
            header
            DashDivider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            DashDivider()
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(DashboardDesign.surface)
        .preferredColorScheme(.dark)
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DashboardDesign.title)
                Text(headerSubtitle)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerTitle: String {
        switch composer.stage {
        case .paste: return "Paste text"
        case .web: return "From a web page"
        case .importing: return composer.error == nil ? "Opening" : "Couldn't open it"
        case .review: return "Review before rendering"
        }
    }

    private var headerSubtitle: String {
        switch composer.stage {
        case .paste:
            return "Anything long: an article, notes, a chapter. Chapter headings split it into chapters."
        case .web:
            return "Myna fetches the page and keeps the article text. Check it before you continue."
        case .importing(let message):
            return message
        case .review:
            guard let document = composer.document else { return "" }
            let count = document.sections.count
            let parts = [document.kind.label, document.origin == document.kind.label ? nil : document.origin,
                         "\(count) section\(count == 1 ? "" : "s")"]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        switch composer.stage {
        case .paste:
            pasteStage
        case .web:
            webStage
        case .importing:
            importingStage
        case .review:
            StudioReviewView(composer: composer)
                .task { await composer.loadContext(library: library) }
        }
    }

    private var pasteStage: some View {
        TextEditor(text: $composer.pastedText)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardDesign.border)
            )
            .overlay(alignment: .topLeading) {
                if composer.pastedText.isEmpty {
                    Text("Paste or type the text here.")
                        .font(.system(size: 13))
                        .foregroundStyle(DashboardDesign.tertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
            .padding(20)
    }

    private var webStage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("https://example.com/an-article", text: $composer.urlString)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await composer.fetchURL() } }
                Button("Fetch") { Task { await composer.fetchURL() } }
                    .disabled(composer.urlString.trimmingCharacters(in: .whitespaces).isEmpty || composer.fetching)
            }
            if composer.fetching {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Fetching the page…")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                }
            }
            if let fetched = composer.fetched {
                VStack(alignment: .leading, spacing: 6) {
                    Text(fetched.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DashboardDesign.title)
                    let words = HistoryAnalytics.compactCount(fetched.wordCount)
                    Text([composer.fetchedByline, "\(words) words", fetched.origin].compactMap { $0 }.joined(separator: " · "))
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                    ScrollView(.vertical) {
                        Text(fetched.sections.first?.text ?? "")
                            .font(.system(size: 12))
                            .foregroundStyle(DashboardDesign.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.card))
                }
            } else if !composer.fetching {
                Spacer()
            }
        }
        .padding(20)
    }

    private var importingStage: some View {
        VStack(spacing: 14) {
            Spacer()
            if composer.error == nil {
                ProgressView()
                Text("Reading the file. A long book can take a few seconds.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            } else {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(DashboardDesign.tertiary)
                Button("Choose Another File…", action: onChooseFiles)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    // MARK: - footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if let error = composer.error {
                Text(error)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.negative)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if composer.stage == .review {
                Text(summary)
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: close)
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var summary: String {
        let count = composer.includedSections.count
        guard count > 0 else { return "Nothing switched on yet." }
        let words = HistoryAnalytics.compactCount(composer.includedWords)
        return "\(count) section\(count == 1 ? "" : "s") · \(words) words · about "
            + StudioFormat.duration(composer.totalEstimate) + " of audio"
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch composer.stage {
        case .paste:
            Button("Continue") { composer.continueFromPaste() }
                .keyboardShortcut(.defaultAction)
                .disabled(composer.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .web:
            Button("Continue") { composer.continueFromWeb() }
                .keyboardShortcut(.defaultAction)
                .disabled(composer.fetched == nil)
        case .importing:
            EmptyView()
        case .review:
            Button {
                Task {
                    if await composer.submit(to: library) { onClose() }
                }
            } label: {
                if composer.submitting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Start Rendering")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(composer.includedSections.isEmpty || composer.submitting)
        }
    }

    private func close() {
        composer.cancelWork()
        onClose()
    }
}
