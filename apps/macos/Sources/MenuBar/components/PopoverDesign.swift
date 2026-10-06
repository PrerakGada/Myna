// PopoverDesign.swift — design tokens for the v0.2.1 menu-bar popover.
//
// Per docs/v0.2-plan/04-visual-direction.md the popover background is the
// near-black #0A0A0C used throughout the visual system. All other token
// values flow from Caravaggio's spec.
//
// Numbers live here (not scattered through views) so the look stays
// consistent if we tweak any of them later.
import SwiftUI

public enum PopoverDesign {

    // MARK: - layout
    /// 440, up from 360: Claude Code items are one-line rows now, and the
    /// extra width is what lets their preview carry a useful sentence.
    public static let popoverWidth: CGFloat = 440
    /// Fixed popover height. The body scrolls inside it and the footer is
    /// pinned below, so opening a section never resizes the window.
    /// Clamped to the usable screen height at render time.
    public static let popoverHeight: CGFloat = 640
    public static let popoverHorizontalPadding: CGFloat = 14
    public static let popoverVerticalPadding: CGFloat = 12
    public static let sectionSpacing: CGFloat = 12
    public static let cardCornerRadius: CGFloat = 8
    public static let outerCornerRadius: CGFloat = 12
    public static let cardInteriorPadding: CGFloat = 12

    // MARK: - colors
    /// Popover surface. Near-black #0A0A0C.
    public static let surface: Color = Color(red: 0.039, green: 0.039, blue: 0.047)
    /// Card surface on top of the popover surface — slightly lighter so
    /// the card reads as a distinct plane.
    public static let cardSurface: Color = Color.white.opacity(0.04)
    /// Card hairline border.
    public static let cardBorder: Color = Color.white.opacity(0.06)
    /// Section header tint (70% body-on-dark, all caps in the spec).
    public static let sectionHeaderColor: Color = Color.white.opacity(0.55)
    /// Body text color.
    public static let bodyColor: Color = Color.white.opacity(0.95)
    /// Secondary / caption text color.
    public static let secondaryColor: Color = Color.white.opacity(0.55)
    /// Accent. Uses the system tint so the user's macOS accent flows
    /// through (Sally's spec: respect user system accent for non-CC chrome).
    public static let accent: Color = Color.accentColor
    /// Status dot — idle (gray).
    public static let dotIdle: Color = Color.white.opacity(0.35)
    /// Status dot — speaking (green).
    public static let dotSpeaking: Color = Color(red: 0.298, green: 0.851, blue: 0.392)
    /// Status dot — thinking (amber).
    public static let dotThinking: Color = Color(red: 0.949, green: 0.741, blue: 0.231)
    /// Status dot — paused (blue).
    public static let dotPaused: Color = Color(red: 0.302, green: 0.651, blue: 1.0)
    /// Status dot — error (red, matches BirdIcon's #FF453A).
    public static let dotError: Color = Color(red: 1.0, green: 0.271, blue: 0.227)

    // MARK: - typography
    /// Hero title. SF Pro Display 17pt semibold (system handles
    /// "Display" selection automatically at this size on macOS).
    public static let heroTitleFont: Font = .system(size: 17, weight: .semibold)
    /// All-caps section header.
    public static let sectionHeaderFont: Font = .system(size: 11, weight: .medium)
    /// Body row.
    public static let bodyFont: Font = .system(size: 13, weight: .regular)
    /// Caption / secondary.
    public static let captionFont: Font = .system(size: 11, weight: .regular)
    /// Monospaced digit display (for time codes that should stop jittering).
    public static let timeCodeFont: Font = .system(size: 11, weight: .regular).monospacedDigit()

    // MARK: - hover
    /// Hover background fill for clickable rows / buttons.
    public static let hoverFill: Color = Color.white.opacity(0.08)
    /// Pressed background fill.
    public static let pressedFill: Color = Color.white.opacity(0.12)

    // MARK: - v0.6 popover rework
    //
    // The rows below arrived with the "the menu can't do anything" pass:
    // quick actions, the always-visible speed row, the inline options
    // group. They reuse the palette above rather than introducing new
    // hues — the only genuinely new colour is `warning`, and it is the
    // same amber as the thinking dot so "engine is unhappy" reads the
    // same in the popover as it does in the menu bar.

    /// Amber used by the engine-down strip. Deliberately identical to
    /// `dotThinking` so one colour means one thing across the whole UI.
    public static let warning: Color = dotThinking

    /// Primary action tile (Read clipboard). Accent-tinted so exactly one
    /// control in the popover reads as "the thing you came here to press".
    public static let primaryActionFill: Color = Color.accentColor.opacity(0.18)
    public static let primaryActionHoverFill: Color = Color.accentColor.opacity(0.30)
    public static let primaryActionBorder: Color = Color.accentColor.opacity(0.45)

    /// Secondary action tile (Summarize, Chrome tab).
    public static let actionFill: Color = Color.white.opacity(0.05)
    public static let actionHoverFill: Color = Color.white.opacity(0.10)

    /// Height of a quick-action tile — glyph over a two-line-capable label.
    public static let actionTileHeight: CGFloat = 54
    /// Height of a settings toggle row inside the OPTIONS group.
    public static let optionRowHeight: CGFloat = 26
    /// Indent for rows nested under a section header, so the group reads
    /// as belonging to its header rather than floating at popover level.
    /// Must exceed a section header's own 8pt inset or the nesting is
    /// invisible — which is exactly how the first cut of OPTIONS looked.
    public static let nestedIndent: CGFloat = 16
    /// Label used for disabled affordances (no clipboard text, engine down).
    public static let disabledColor: Color = Color.white.opacity(0.28)
}
