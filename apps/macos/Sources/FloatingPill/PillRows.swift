// PillRows.swift — the expanded pill's recent-read row and its icon button
// style. Moved out of PillView.swift (over the file-length limit) so the
// transcript button could join the transport row without growing that file;
// internal rather than private so TranscriptPillButton can share the style.
import SwiftUI

// MARK: - recent row

/// One tappable "recent read" row in the expanded pill. The *title* gets the
/// full width (single line, tail-truncated); the relative age sits in a
/// de-emphasised trailing slot. The leading glyph flips replay→play and the
/// row lights up on hover so it reads as a tap target. (We deliberately drop
/// the voice prefix that `RecentItem.displayLine()` carries for the menu —
/// the pill already shows the active voice, so repeating it per row just ate
/// the horizontal room the title needs.)
struct PillRecentRow: View {
    let item: RecentItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: hovering ? "play.fill" : "arrow.counterclockwise")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
                    .frame(width: 14, height: 14)
                Text(item.title)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(hovering ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(item.ageString())
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Re-speak")
        // Swallow the parent tap-to-pin so a row tap doesn't toggle the pin.
        .simultaneousGesture(TapGesture().onEnded {})
    }
}

// MARK: - icon button style

struct PillIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Circle().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.0))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
