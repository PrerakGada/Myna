// StudioReviewView.swift — the review step: what will be read, how, and
// into which file.
//
// Top to bottom: the title; the sections with a switch, word count and
// estimated length each (or the text itself, for a single section);
// voice, speed, pause and format; then the optional cleanups. The engine
// is named but can't be changed here.
import SwiftUI

struct StudioReviewView: View {
    @ObservedObject var composer: StudioComposer

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                titleField
                if composer.sections.count > 1 {
                    sectionList
                } else {
                    singleSectionPreview
                }
                voiceAndFile
                cleanupOptions
            }
            .padding(20)
        }
    }

    // MARK: - title

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashSectionTitle("Title")
            TextField("Title", text: $composer.title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            Text("Names the file and appears in the audio's details.")
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.tertiary)
        }
    }

    // MARK: - sections

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DashSectionTitle("Sections")
                Text("Each becomes a chapter")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                Spacer()
                Button("All") { composer.setAll(included: true) }
                    .controlSize(.small)
                Button("None") { composer.setAll(included: false) }
                    .controlSize(.small)
            }
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach($composer.sections) { $section in
                        StudioSectionRow(section: $section, seconds: composer.estimate(words: section.words))
                        DashDivider()
                    }
                }
            }
            .frame(height: min(166, CGFloat(composer.sections.count) * 41 + 4))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardDesign.border))
        }
    }

    private var singleSectionPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DashSectionTitle("Text")
                Spacer()
                if let section = composer.sections.first {
                    Text("\(HistoryAnalytics.compactCount(section.words)) words · about "
                         + StudioFormat.duration(composer.estimate(words: section.words)))
                        .font(DashboardDesign.captionFont.monospacedDigit())
                        .foregroundStyle(DashboardDesign.tertiary)
                }
            }
            ScrollView(.vertical) {
                Text(String((composer.sections.first?.text ?? "").prefix(4_000)))
                    .font(.system(size: 12))
                    .foregroundStyle(DashboardDesign.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DashboardDesign.card))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DashboardDesign.border))
        }
    }

    // MARK: - cleanups

    private var cleanupOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            DashSectionTitle("Cleanup")
            Toggle("Remove web addresses (https://…), which would be read out character by character",
                   isOn: $composer.cleanup.removeURLs)
            Toggle("Remove citation markers like [12] and [citation needed]", isOn: $composer.cleanup.removeCitations)
            if composer.sections.count > 1 {
                Toggle("Switch off very short sections and contents, copyright and index pages",
                       isOn: $composer.cleanup.skipShortSections)
            }
        }
        .toggleStyle(.checkbox)
        .font(DashboardDesign.bodyFont)
        .foregroundStyle(DashboardDesign.body)
    }

    // MARK: - voice and file

    private var voiceAndFile: some View {
        VStack(alignment: .leading, spacing: 2) {
            DashSectionTitle("Voice and file")
                .padding(.bottom, 4)
            DashRow("Voice", help: engineHelp) {
                if composer.voices.isEmpty {
                    Text("Engine default")
                        .font(DashboardDesign.bodyFont)
                        .foregroundStyle(DashboardDesign.secondary)
                } else {
                    Picker("", selection: $composer.voiceId) {
                        ForEach(composer.voices) { voice in
                            Text(voiceLabel(voice)).tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            }
            DashDivider()
            DashRow("Speed", help: composer.nativeSpeed ? nil : speedHelp) {
                HStack(spacing: 8) {
                    // Continuous (a stepped slider draws 30 tick marks), rounded to 0.05.
                    Slider(
                        value: Binding(get: { composer.speed }, set: { composer.speed = ($0 * 20).rounded() / 20 }),
                        in: 0.5...2.0
                    )
                        .frame(width: 170)
                        .accessibilityLabel("Speed")
                    Text(String(format: "%.2f×", composer.effectiveSpeed))
                        .font(DashboardDesign.captionFont.monospacedDigit())
                        .foregroundStyle(DashboardDesign.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!composer.nativeSpeed)
            }
            if composer.includedSections.count > 1 {
                DashDivider()
                DashRow("Pause between sections") {
                    Picker("", selection: $composer.pauseMs) {
                        ForEach(StudioComposer.pauseChoices, id: \.self) { ms in
                            Text(pauseLabel(ms)).tag(ms)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
            }
            DashDivider()
            formatRow
            if let note = composer.contextError {
                Text(note)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.warning)
                    .padding(.top, 6)
            }
        }
    }

    private var engineHelp: String {
        guard let name = composer.engineName else {
            return "Voices of the active engine. Studio never switches engines."
        }
        return "Voices of \(name), the active engine. Studio never switches engines; change it in the Engine pane."
    }

    private var speedHelp: String {
        "\(composer.engineName ?? "This engine") speaks at one pace, so files come out at 1×."
    }

    private func voiceLabel(_ voice: Voice) -> String {
        voice.id == composer.usualVoiceId ? "\(voice.label) · your voice" : voice.label
    }

    private func pauseLabel(_ ms: Int) -> String {
        if ms == 0 { return "None" }
        return ms.isMultiple(of: 1_000) ? "\(ms / 1_000) s" : String(format: "%.1f s", Double(ms) / 1_000)
    }

    private var formatRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("Format")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    ForEach(composer.formats) { format in
                        FormatChip(
                            format: format,
                            selected: format.id == composer.formatId,
                            select: { composer.formatId = format.id }
                        )
                    }
                }
            }
            let unavailable = composer.formats.filter { !$0.available }
            if !unavailable.isEmpty {
                Text(unavailable.map { "\(StudioFormat.formatLabel($0.id)) \($0.reason ?? "isn't available on this Mac")" }
                    .joined(separator: ". ") + ".")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct StudioSectionRow: View {
    @Binding var section: StudioReviewSection
    let seconds: Double

    var body: some View {
        HStack(spacing: 9) {
            Toggle("", isOn: $section.included)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(section.words == 0)
                .accessibilityLabel("Include \(section.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.title)
                    .lineLimit(1)
                Text(preview)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text("\(HistoryAnalytics.compactCount(section.words)) words")
                .frame(width: 78, alignment: .trailing)
            Text(StudioFormat.duration(seconds))
                .frame(width: 58, alignment: .trailing)
        }
        .font(DashboardDesign.captionFont.monospacedDigit())
        .foregroundStyle(DashboardDesign.secondary)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .opacity(section.included ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { if section.words > 0 { section.included.toggle() } }
    }

    /// The opening words after the spoken heading.
    private var preview: String {
        var text = section.text
        let heading = StudioText.spokenHeading(section.title)
        if text.hasPrefix(heading) { text = String(text.dropFirst(heading.count)) }
        let flat = text.prefix(160).replacingOccurrences(of: "\n", with: " ")
        return flat.trimmingCharacters(in: .whitespaces)
    }
}

private struct FormatChip: View {
    let format: AudioFormatInfo
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            Text(StudioFormat.formatLabel(format.id))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.white : DashboardDesign.body)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? DashboardDesign.accent : DashboardDesign.card)
                )
                .overlay(Capsule().strokeBorder(selected ? Color.clear : DashboardDesign.border))
        }
        .buttonStyle(.plain)
        .disabled(!format.available)
        .opacity(format.available ? 1 : 0.4)
        .help(format.available ? format.label : "\(format.label): \(format.reason ?? "not available on this Mac")")
        .accessibilityLabel(format.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
