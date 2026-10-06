// APITryItCard.swift — proves the endpoint works without leaving the
// app: type a line, pick a voice and a format, send the real request,
// hear the result, see what came back.
import SwiftUI

struct APITryItCard: View {
    @ObservedObject var model: APIPaneModel
    @ObservedObject var tryIt: APITryItModel

    private var formats: [AudioFormatInfo] {
        model.formats.isEmpty ? [Self.wavFallback] : model.formats
    }

    private static let wavFallback = AudioFormatInfo(
        id: "wav", label: "WAV", available: true, ext: "wav", mime: "audio/wav", reason: nil)

    private var serviceUsable: Bool {
        switch model.status {
        case .ready, .engineDown, .checking, .restartNeeded: return true
        case .restarting, .noAPI, .unreachable, .restartFailed: return false
        }
    }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    DashSectionTitle("Try it")
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        APIMethodTag(method: "POST", width: nil)
                        Text("/v1/audio/speech")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DashboardDesign.tertiary)
                    }
                }
                Text(
                    "Sends a real request to the endpoint, the way an OpenAI client would, and plays what "
                        + "comes back. It appears under Recent requests."
                )
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)

                editor
                controls
                result
            }
        }
        .onChange(of: model.formats) { newFormats in
            tryIt.adoptDefaultFormat(APISnippets.preferredFormat(newFormats), available: newFormats)
        }
        .onChange(of: model.voices) { newVoices in
            let known = Set(newVoices.map(\.id)).union(APISnippets.openAIVoiceNames)
            if !tryIt.voice.isEmpty, !known.contains(tryIt.voice) { tryIt.voice = "" }
        }
        .onAppear {
            if !model.formats.isEmpty {
                tryIt.adoptDefaultFormat(model.snippetFormat, available: model.formats)
            }
        }
        .onDisappear { tryIt.stop() }
    }

    private var editor: some View {
        TextEditor(text: $tryIt.text)
            .font(DashboardDesign.bodyFont)
            .foregroundStyle(DashboardDesign.title)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 64)
            .background(
                RoundedRectangle(cornerRadius: APIDesign.codeRadius, style: .continuous)
                    .fill(APIDesign.codeSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: APIDesign.codeRadius, style: .continuous)
                    .strokeBorder(APIDesign.codeBorder, lineWidth: 1)
            )
            .accessibilityLabel("Text to speak")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Voice", selection: $tryIt.voice) {
                Text(defaultVoiceLabel).tag("")
                if !model.voices.isEmpty {
                    Section("This engine") {
                        ForEach(model.voices) { voice in
                            Text("\(voice.label) (\(voice.id))").tag(voice.id)
                        }
                    }
                }
                Section("OpenAI names") {
                    ForEach(APISnippets.openAIVoiceNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }
            .fixedSize()

            Menu {
                ForEach(formats) { format in
                    Button {
                        tryIt.chooseFormat(format.id)
                    } label: {
                        Text(format.available ? format.label : "\(format.label): \(format.reason ?? "not available")")
                    }
                    .disabled(!format.available)
                }
            } label: {
                Text("Format: \(formats.first { $0.id == tryIt.format }?.label ?? tryIt.format.uppercased())")
            }
            .fixedSize()

            Spacer(minLength: 8)

            Button {
                tryIt.run()
            } label: {
                Label(tryIt.isRunning ? "Waiting…" : "Send request", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!tryIt.canRun || !serviceUsable)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send the request (⌘↩)")
        }
    }

    private var defaultVoiceLabel: String {
        guard let voice = model.defaultVoice else { return "Engine default" }
        return "Default: \(voice.label)"
    }

    @ViewBuilder private var result: some View {
        switch tryIt.phase {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Waiting for the voice engine…")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(DashboardDesign.negative)
                Text(message)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done(let take):
            takeRow(take)
        }
    }

    private func takeRow(_ take: APITryItModel.Take) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DashboardDesign.positive)
                Text(Self.summary(take))
                    .font(DashboardDesign.captionFont.monospacedDigit())
                    .foregroundStyle(DashboardDesign.body)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if take.playable {
                    Button {
                        tryIt.isPlaying ? tryIt.stop() : tryIt.play()
                    } label: {
                        Label(tryIt.isPlaying ? "Stop" : "Play", systemImage: tryIt.isPlaying ? "stop.fill" : "play.fill")
                    }
                }
                Button("Save…") { tryIt.save() }
            }
            if !take.playable {
                Text("The preview plays WAV, MP3, AAC, M4A and FLAC. Save the file to open it in another app.")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
            }
        }
    }

    /// `200 OK · 1.8 s · 96 KB · 3.2 s of audio · af_heart on kokoro`
    static func summary(_ take: APITryItModel.Take) -> String {
        var parts = ["200 OK", APILogFormat.duration(ms: take.wallMs)]
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(take.bytes), countStyle: .file))
        if let seconds = take.durationS { parts.append("\(APILogFormat.audio(seconds)) of audio") }
        if let voice = take.voice {
            parts.append(take.engine.map { "\(voice) on \($0)" } ?? voice)
        }
        return parts.joined(separator: " · ")
    }
}
