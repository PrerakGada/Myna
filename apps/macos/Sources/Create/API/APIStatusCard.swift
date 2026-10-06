// APIStatusCard.swift — the first thing on the API pane: Myna speaks
// OpenAI's text-to-speech API, here is the address, copy it. Then
// whether the service is answering and which engine and voice it will
// use, because that's what decides what a client hears.
import SwiftUI

struct APIStatusCard: View {
    @ObservedObject var model: APIPaneModel

    private var tint: Color {
        switch model.status {
        case .ready: return DashboardDesign.positive
        case .checking, .restarting: return DashboardDesign.info
        case .engineDown, .noAPI: return DashboardDesign.warning
        case .unreachable, .restartFailed: return DashboardDesign.negative
        case .restartNeeded: return DashboardDesign.warning
        }
    }

    var body: some View {
        DashCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Myna speaks OpenAI's text-to-speech API")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DashboardDesign.title)
                    Text(
                        "Anything that can call OpenAI text-to-speech (the OpenAI SDKs, Open WebUI, your own "
                            + "scripts) can use Myna's voice instead. Set this as its base URL and use any API key. "
                            + "The audio is made on this Mac, free and offline."
                    )
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Base URL")
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.tertiary)
                    APICopyField(value: model.baseURL, fontSize: 15)
                }

                DashDivider()

                statusRow

                if let mp3 = model.mp3Unavailable {
                    mp3Note(mp3)
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if model.status == .restarting || model.status == .checking {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
            }
            .frame(width: 14, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.status.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DashboardDesign.title)
                    if let engine = model.engineName {
                        DashBadge(engine, tint: DashboardDesign.accent)
                    }
                }
                Text(model.status.detail)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let voice = model.defaultVoice {
                    (Text("Requests that name no voice get ")
                        + Text(voice.label).foregroundColor(DashboardDesign.body)
                        + Text(", voice id ")
                        + APIText.code(voice.id)
                        + Text(". OpenAI voice names such as alloy are mapped to one of this engine's voices."))
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func mp3Note(_ mp3: AudioFormatInfo) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(DashboardDesign.warning)
                .frame(width: 14)
            (Text("This Mac can't make MP3")
                + Text(mp3.reason.map { " (\($0))" } ?? "")
                + Text(". OpenAI clients ask for MP3 unless told otherwise, so set the response format to ")
                + APIText.code("wav")
                + Text(", ")
                + APIText.code("aac")
                + Text(" or ")
                + APIText.code("flac")
                + Text(" in the client."))
                .font(DashboardDesign.captionFont)
                .foregroundStyle(DashboardDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
