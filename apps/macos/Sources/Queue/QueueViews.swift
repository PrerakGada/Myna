// QueueViews.swift — the queue as the popover and the Dashboard show it.
//
// The pill renders its own chip (PillView keeps its styles private), but
// every surface takes its wording from `ReadQueue.countLabel`, so the pill,
// the popover and the Dashboard can't drift into three phrasings of one fact.
import SwiftUI

// MARK: - popover

/// "Up next" in the popover: each waiting read as one line — its first few
/// words and where it came from — with a button to drop it. Hidden when the
/// queue is empty. Rows don't play on click; the order is the point.
public struct QueueSection: View {
    @ObservedObject var queue: ReadQueue

    public init(queue: ReadQueue) {
        self.queue = queue
    }

    public var body: some View {
        VStack(spacing: 2) {
            header
            ForEach(queue.items) { read in
                QueueRow(read: read) { queue.remove(id: read.id) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UP NEXT")
                .font(PopoverDesign.sectionHeaderFont)
                .tracking(0.5)
                .foregroundStyle(PopoverDesign.sectionHeaderColor)
            Spacer(minLength: 0)
            if let label = queue.countLabel {
                Text(label)
                    .font(PopoverDesign.captionFont)
                    .foregroundStyle(PopoverDesign.secondaryColor)
            }
            Button("Clear") { queue.clear() }
                .buttonStyle(.plain)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.accent)
                .help("Remove every waiting read. The current read keeps playing.")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

private struct QueueRow: View {
    let read: QueuedRead
    let onRemove: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: read.source.systemImage)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(PopoverDesign.secondaryColor)
                .frame(width: 12)
            Text(read.preview)
                .font(PopoverDesign.bodyFont)
                .foregroundStyle(PopoverDesign.bodyColor)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(detail)
                .font(PopoverDesign.captionFont)
                .foregroundStyle(PopoverDesign.secondaryColor)
                .lineLimit(1)
                .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isHovering ? PopoverDesign.bodyColor : PopoverDesign.secondaryColor)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from the queue")
            .accessibilityLabel("Remove \(read.preview) from the queue")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering ? PopoverDesign.hoverFill : Color.clear)
        )
        .onHover { isHovering = $0 }
    }

    /// Where the read came from: "Selection · Safari", "Article · Summary".
    /// The app is named only for a selection, the one source where the
    /// frontmost app is where the text actually lives.
    private var detail: String {
        var parts = [read.source.label]
        if read.source == .selection, let app = read.appName, !app.isEmpty { parts.append(app) }
        if read.mode == .summary { parts.append("Summary") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Dashboard sidebar

/// The Dashboard's NowPlayingStrip count: "· +2 queued", or nothing.
struct QueuedCountText: View {
    @ObservedObject var queue: ReadQueue = .shared

    var body: some View {
        if let label = queue.countLabel {
            Text("\u{00B7} \(label)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DashboardDesign.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
