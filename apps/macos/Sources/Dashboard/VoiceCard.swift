// VoiceCard.swift — one voice on the Voices screen.
//
// Name, then the facts that help choose: gender, where your own voice came
// from, how often you have used it, and Kokoro's quality grade. Your own
// clips and blends get a menu to rename or delete them; a licensed clip
// carries its credit line.
import SwiftUI

struct VoiceCard: View {
    let voice: Voice
    let isSelected: Bool
    let previewState: VoicePreviewService.State
    let uses: Int
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onRename: (() -> Void)?
    let onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(voice.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(DashboardDesign.title)
                        .lineLimit(1)
                    Text(factsLine)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    DashBadge("Active", tint: DashboardDesign.accent)
                }
                if let grade = voice.grade {
                    DashBadge(grade, tint: gradeTint(grade))
                        .help("hexgrad's quality grade for this voice, A best to F worst. It reflects "
                              + "how much clean audio the voice was trained on.")
                }
                if onRename != nil || onDelete != nil {
                    Menu {
                        if let onRename { Button("Rename…", action: onRename) }
                        if let onDelete { Button("Delete…", role: .destructive, action: onDelete) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DashboardDesign.secondary)
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More for \(voice.label)")
                }
            }

            HStack(spacing: 8) {
                Button(action: onSelect) {
                    Text(isSelected ? "Selected" : "Use this voice")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected
                                    ? DashboardDesign.accent.opacity(0.18)
                                    : Color.white.opacity(isHovering ? 0.10 : 0.06))
                        )
                        .foregroundStyle(
                            isSelected ? DashboardDesign.accent : DashboardDesign.body)
                }
                .buttonStyle(.plain)
                .disabled(isSelected)

                Button(action: onPreview) {
                    Image(systemName: isBusy ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            isBusy ? DashboardDesign.accent : DashboardDesign.secondary)
                }
                .buttonStyle(.plain)
                .help("Hear a sample of \(voice.label)")
                .accessibilityLabel("Preview \(voice.label)")
            }

            if let note = previewNote {
                Text(note)
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(
                        note.hasPrefix("Couldn't")
                            ? DashboardDesign.negative : DashboardDesign.warning)
            } else if let credit = voice.credit {
                Text(credit)
                    .font(.system(size: 10))
                    .foregroundStyle(DashboardDesign.tertiary)
                    .lineLimit(1)
                    .help(credit)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .fill(isSelected ? DashboardDesign.cardRaised : DashboardDesign.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                .strokeBorder(
                    isSelected ? DashboardDesign.accent.opacity(0.45) : DashboardDesign.border,
                    lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    /// "Female · Used 3 times", or for your own voices where it came from.
    private var factsLine: String {
        var facts: [String] = []
        if let gender = voice.gender { facts.append(gender.capitalized) }
        if voice.isUserMade, let detail = voice.detail { facts.append(detail) }
        facts.append(usageLine)
        return facts.joined(separator: " · ")
    }

    private var usageLine: String {
        switch uses {
        case 0: return "Not used yet"
        case 1: return "Used once"
        default: return "Used \(uses) times"
        }
    }

    private func gradeTint(_ grade: String) -> Color {
        switch grade.first {
        case "A": return DashboardDesign.positive
        case "B": return DashboardDesign.info
        case "C": return DashboardDesign.secondary
        default: return DashboardDesign.tertiary
        }
    }

    private var isBusy: Bool {
        switch previewState {
        case .loading(let id), .playing(let id): return id == voice.id
        default: return false
        }
    }

    private var previewNote: String? {
        switch previewState {
        case .warming(let id) where id == voice.id: return "Engine warming…"
        case .failed(let id, _) where id == voice.id: return "Couldn't preview this voice"
        default: return nil
        }
    }
}
