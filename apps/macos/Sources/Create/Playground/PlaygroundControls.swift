// PlaygroundControls.swift — voice, speed, Generate, and Compare.
//
// Rows rather than a toolbar: at the Dashboard's minimum width the
// content column is about 630 points, and a row per control keeps every
// label readable there without anything wrapping into a second line.
import SwiftUI

struct PlaygroundControlsCard: View {
    @ObservedObject var model: PlaygroundModel
    @ObservedObject var draft: PlaygroundDraft

    var body: some View {
        let stats = PlaygroundText.stats(for: draft.text, speed: 1)
        let blocker = model.generateBlocker(for: stats)
        DashCard {
            VStack(alignment: .leading, spacing: 4) {
                voiceRow
                DashDivider()
                speedRow
                DashDivider()
                generateRow(blocker: blocker)
                DashDivider()
                compareRow(blocker: blocker)
            }
        }
    }

    // MARK: - voice

    private var voiceRow: some View {
        DashRow("Voice", help: voiceHelp) {
            if model.voices.isEmpty {
                Text(model.engineState == .loading ? "Loading voices…" : "No voices")
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.tertiary)
            } else {
                Picker("", selection: $model.voiceId) {
                    ForEach(model.voices) { voice in
                        Text(Self.menuLabel(voice)).tag(voice.id)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                .disabled(model.isBusy)
            }
        }
    }

    private var voiceHelp: String {
        guard let engine = model.engine else { return "The voices of the active engine." }
        let count = model.voices.count
        return "\(count) \(count == 1 ? "voice" : "voices") from \(engine.name), the active engine."
    }

    static func menuLabel(_ voice: Voice) -> String {
        voice.lang.isEmpty ? voice.label : "\(voice.label) · \(voice.lang.uppercased())"
    }

    // MARK: - speed

    private var speedRow: some View {
        DashRow("Speed", help: speedHelp) {
            HStack(spacing: 10) {
                Slider(value: $model.speed, in: 0.5...2.0, step: 0.05)
                    .frame(width: 180)
                    .accessibilityLabel("Speed")
                Text(PlaygroundText.speedLabel(model.honoursSpeed ? model.speed : 1))
                    .font(DashboardDesign.bodyFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.body)
                    .frame(width: 46, alignment: .trailing)
            }
            .disabled(!model.honoursSpeed || model.isBusy)
        }
    }

    private var speedHelp: String {
        let name = model.engine?.name ?? "The engine"
        if model.honoursSpeed {
            return "\(name) speaks at this pace, so the take and any file you save from it match."
        }
        return "\(name) speaks at a fixed pace and ignores speed, so its takes render at 1×."
    }

    // MARK: - generate

    private func generateRow(blocker: String?) -> some View {
        HStack(spacing: 10) {
            if let job = model.job {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: job.startedAt, by: 0.1)) { timeline in
                    Text(Self.jobLabel(job, now: timeline.date))
                        .font(DashboardDesign.bodyFont.monospacedDigit())
                        .foregroundStyle(DashboardDesign.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop waiting for this take (Esc)")
            } else {
                Button {
                    model.generate()
                } label: {
                    Label("Generate", systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(blocker != nil)
                .help("Render the text in the chosen voice (⌘↩)")
                Text(blocker ?? "⌘↩")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Toggle("Play when ready", isOn: $model.playWhenReady)
                    .toggleStyle(.checkbox)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .help("Play each new take as soon as it arrives. Comparisons never play on their own.")
            }
        }
        .frame(minHeight: 28)
        .padding(.vertical, 8)
    }

    static func jobLabel(_ job: PlaygroundModel.Job, now: Date) -> String {
        let elapsed = String(format: "%.1f s", max(0, now.timeIntervalSince(job.startedAt)))
        if job.total > 1 {
            return "Rendering \(job.index + 1) of \(job.total): \(job.voiceLabel)… \(elapsed)"
        }
        return "Rendering in \(job.voiceLabel)… \(elapsed)"
    }

    // MARK: - compare

    private func compareRow(blocker: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DashRow("Compare voices", help: compareHelp) {
                HStack(spacing: 8) {
                    compareMenu
                    Button("Compare") { model.compare() }
                        .disabled(blocker != nil || model.compareVoiceIds.count < 2)
                        .help(model.compareVoiceIds.count < 2 ? "Choose at least two voices" : "Render every chosen voice")
                }
            }
            if !model.compareVoiceIds.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.compareVoiceIds, id: \.self) { id in
                        chip(id)
                    }
                    if model.compareVoiceIds.count < 2 {
                        Text("Choose one more.")
                            .font(DashboardDesign.captionFont)
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var compareHelp: String {
        if model.engine != nil, model.voices.count == 1 {
            return "\(model.engine?.name ?? "This engine") has one voice, so there is nothing to compare. "
                + "Switch to an engine with several voices on the Engine page."
        }
        return "Renders this text in up to \(PlaygroundModel.maxCompareVoices) voices, one after another, "
            + "and lays the takes side by side."
    }

    private var compareMenu: some View {
        Menu {
            ForEach(model.voices) { voice in
                let chosen = model.compareVoiceIds.contains(voice.id)
                Toggle(Self.menuLabel(voice), isOn: Binding(
                    get: { chosen },
                    set: { _ in model.toggleCompareVoice(voice.id) }
                ))
                .disabled(!chosen && model.compareVoiceIds.count >= PlaygroundModel.maxCompareVoices)
            }
        } label: {
            Text(model.compareVoiceIds.isEmpty ? "Choose voices" : "\(model.compareVoiceIds.count) chosen")
        }
        .fixedSize()
        .disabled(model.voices.count < 2 || model.isBusy)
    }

    private func chip(_ id: String) -> some View {
        HStack(spacing: 4) {
            Text(model.label(for: id))
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.body)
                .lineLimit(1)
            Button {
                model.toggleCompareVoice(id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DashboardDesign.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityLabel("Remove \(model.label(for: id))")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.07)))
        .overlay(Capsule().strokeBorder(DashboardDesign.border, lineWidth: 1))
    }
}
