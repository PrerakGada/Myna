// HistoryReadText.swift — a History row's text, as written or as heard.
//
// The daemon cleans text before speaking it (markdown, code, URLs, citation
// marks out; see daemon/myna/speakable.py) and applies the pronunciation
// list, so what a row holds isn't quite what was said. The cleanup is
// deterministic, so "As heard" asks the daemon to run it again with the
// read's own source and prep rather than storing a second copy of every
// text. The pronunciation list is the one in force now, not at the time.
// Rows from before cleanup existed (no prep) were read as written, so they
// don't offer it; nor do summaries, whose words came from the summariser
// and aren't stored.
import SwiftUI

struct HistoryReadText: View {
    let event: ReadEvent
    let text: String
    let client: DaemonClient

    private enum Version: Hashable { case written, heard }

    @State private var version: Version = .written
    @State private var heard: SpeakableResponse?
    @State private var failed = false

    private var offersHeard: Bool {
        event.prep != nil && event.mode == SynthesizeMode.full.rawValue
    }

    private var shown: String {
        if version == .heard, let heard { return heard.text }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                DashSectionTitle("What was read")
                Spacer(minLength: 0)
                if offersHeard {
                    Picker("", selection: $version) {
                        Text("As written").tag(Version.written)
                        Text("As heard").tag(Version.heard)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("As heard: the text after Myna's cleanup, which is what was spoken.")
                }
            }
            if version == .heard, let note {
                Text(note)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(shown)
                .font(.system(size: 12))
                .foregroundStyle(DashboardDesign.body)
                .opacity(version == .heard && heard == nil && !failed ? 0.45 : 1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: version) { await loadHeard() }
    }

    private var note: String? {
        if failed {
            return "Myna's background service didn't answer, so this is the text as written. "
                + "Try again once it's running."
        }
        if let heard, !heard.changed {
            return "Nothing in this text was changed before it was read."
        }
        return nil
    }

    private func loadHeard() async {
        guard version == .heard, heard == nil else { return }
        failed = false
        let prep = event.prep.flatMap(TextPrep.init(rawValue:)) ?? .auto
        let request = SpeakableRequest(text: text, source: event.source.rawValue, prep: prep)
        do {
            heard = try await client.speakable(request)
        } catch {
            failed = true
        }
    }
}
