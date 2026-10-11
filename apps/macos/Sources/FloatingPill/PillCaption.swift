// PillCaption.swift — live captions in the pill: the sentence Myna is
// reading, its spoken word lit, from any app or from Claude Code
// (LiveCaptions). Also the pill's glass background, shared with PillView.
//
// The lit word changes colour and gets a soft backing, never weight: bold
// would widen it and re-wrap the sentence on every word. Words already
// spoken stay bright and the rest of the sentence waits dimmer, so the eye
// finds its place at a glance.
import SwiftUI

enum PillCaptionStyle {
    static let width: CGFloat = 420
    static let radius: CGFloat = 18
    static let font = Font.system(size: 14, weight: .medium, design: .rounded)
    static let lines = 3
    static let spoken = Color.white.opacity(0.94)
    static let upcoming = Color.white.opacity(0.52)
    static let unlit = Color.white.opacity(0.85)
}

/// The caption's text, styled. Used by the caption card and the expanded
/// mini-player.
struct PillCaptionText: View {
    let caption: Caption

    var body: some View {
        Text(styled)
            .font(PillCaptionStyle.font)
            .lineSpacing(2)
            .lineLimit(PillCaptionStyle.lines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(caption.isPaused ? 0.6 : 1)
            // Words step, they don't fade: no animation between captions.
            .transaction { $0.animation = nil }
            .accessibilityLabel(caption.text)
    }

    private var styled: AttributedString {
        let text = caption.text as NSString
        guard let word = caption.word, word.length > 0, NSMaxRange(word) <= text.length else {
            var all = AttributedString(caption.text)
            all.foregroundColor = PillCaptionStyle.unlit
            return all
        }
        var before = AttributedString(text.substring(to: word.location))
        before.foregroundColor = PillCaptionStyle.spoken
        var now = AttributedString(text.substring(with: word))
        now.foregroundColor = Color.accentColor
        now.backgroundColor = Color.accentColor.opacity(0.22)
        var after = AttributedString(text.substring(from: NSMaxRange(word)))
        after.foregroundColor = PillCaptionStyle.upcoming
        return before + now + after
    }
}

/// The `.caption` layout: what Myna is reading, while it reads. Hover or a
/// click opens the full mini-player as before.
struct PillCaptionCard: View {
    let caption: Caption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            indicator
            PillCaptionText(caption: caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: PillCaptionStyle.width, alignment: .leading)
        .background(PillChrome(cornerRadius: PillCaptionStyle.radius))
        .overlay(
            RoundedRectangle(cornerRadius: PillCaptionStyle.radius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder private var indicator: some View {
        if caption.isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: PillStyle.dotsWidth, height: 10)
        } else {
            WaveformDots(isPlaying: true)
                .frame(width: PillStyle.dotsWidth, height: 10)
        }
    }
}

// MARK: - background

/// The pill's chrome: Liquid Glass where the SDK and OS have it, frosted
/// material otherwise.
struct PillChrome: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // `glassEffect` only EXISTS in the macOS 26 SDK (Xcode 26 / Swift 6.2+).
        // A runtime `#available(macOS 26.0, *)` check is not enough: on an older
        // SDK the symbol is absent and the file won't compile at all. Release CI
        // builds on Xcode 16 / macOS 15 SDK, so the glass path must be excluded
        // at COMPILE time there — hence the `#if compiler(>=6.2)` gate. On a
        // macOS 26 toolchain we still fall back to the material below at runtime
        // on pre-26 systems.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Liquid Glass: a tinted regular glass so the dark chrome reads
            // over bright desktops while still refracting what's behind it.
            shape
                .fill(.clear)
                .glassEffect(.regular.tint(Color.black.opacity(0.18)), in: shape)
                .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 6)
        } else {
            material(shape)
        }
        #else
        material(shape)
        #endif
    }

    /// Pre-Liquid-Glass background: stacked ultra-thin material + dark wash.
    /// Used on macOS < 26 at runtime, and as the sole path when built against
    /// an SDK that predates `glassEffect`.
    private func material(_ shape: RoundedRectangle) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color.black.opacity(0.28))
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.34), radius: 16, x: 0, y: 6)
    }
}
