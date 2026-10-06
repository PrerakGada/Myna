// DashboardDesign.swift — tokens and the handful of shared views the
// Dashboard's panes are built from.
//
// The Dashboard commits to the same near-black surface as the popover,
// the pill and the onboarding cinematic, so the app reads as one thing
// regardless of the system appearance. That is a deliberate choice, not
// an oversight: Myna's whole visual system is dark, and a window that
// flipped to light while the popover stayed black would look broken.
// Everything that paints a background here paints it explicitly.
import SwiftUI

public enum DashboardDesign {

    // MARK: - surfaces

    /// Window background. Same #0A0A0C as PopoverDesign.surface.
    public static let surface = Color(red: 0.039, green: 0.039, blue: 0.047)
    /// Sidebar — one step up from the content so the split reads.
    public static let sidebarSurface = Color(red: 0.063, green: 0.063, blue: 0.075)
    /// Card plane.
    public static let card = Color.white.opacity(0.035)
    /// Card plane, raised (hover / selected).
    public static let cardRaised = Color.white.opacity(0.06)
    public static let border = Color.white.opacity(0.07)
    public static let separator = Color.white.opacity(0.06)

    // MARK: - text

    public static let title = Color.white.opacity(0.95)
    public static let body = Color.white.opacity(0.82)
    public static let secondary = Color.white.opacity(0.52)
    public static let tertiary = Color.white.opacity(0.34)
    public static let accent = Color.accentColor

    // MARK: - semantic

    public static let positive = Color(red: 0.298, green: 0.851, blue: 0.392)
    public static let warning = Color(red: 0.949, green: 0.741, blue: 0.231)
    public static let negative = Color(red: 1.0, green: 0.271, blue: 0.227)
    public static let info = Color(red: 0.302, green: 0.651, blue: 1.0)

    /// Chart series colours. Ordered for maximum separation at small
    /// sizes; every one clears 3:1 contrast against `surface`.
    public static let series: [Color] = [
        Color(red: 0.42, green: 0.62, blue: 1.00),
        Color(red: 0.36, green: 0.84, blue: 0.62),
        Color(red: 0.95, green: 0.74, blue: 0.29),
        Color(red: 0.85, green: 0.52, blue: 0.95),
        Color(red: 0.98, green: 0.55, blue: 0.42),
        Color(red: 0.45, green: 0.82, blue: 0.92),
    ]

    public static func seriesColor(_ index: Int) -> Color {
        series[((index % series.count) + series.count) % series.count]
    }

    // MARK: - metrics

    public static let windowWidth: CGFloat = 1_100
    public static let windowHeight: CGFloat = 740
    public static let minWindowWidth: CGFloat = 900
    public static let minWindowHeight: CGFloat = 600
    public static let sidebarWidth: CGFloat = 214
    public static let panePadding: CGFloat = 28
    public static let cardRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 18
    public static let gridSpacing: CGFloat = 14

    // MARK: - type

    public static let paneTitleFont = Font.system(size: 24, weight: .semibold)
    public static let paneSubtitleFont = Font.system(size: 13)
    public static let sectionFont = Font.system(size: 11, weight: .semibold)
    public static let statFont = Font.system(size: 27, weight: .semibold).monospacedDigit()
    public static let bodyFont = Font.system(size: 13)
    public static let captionFont = Font.system(size: 11)
}

// MARK: - scaffolding

/// Standard pane wrapper: a fixed header, then scrolling content. Every
/// pane uses it so titles sit on the same baseline as you switch.
public struct PaneScaffold<Header: View, Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let header: Header
    private let content: Content
    /// Panes that manage their own scrolling (a table, a log tail) opt out.
    private let scrolls: Bool

    public init(
        title: String,
        subtitle: String? = nil,
        scrolls: Bool = true,
        @ViewBuilder header: () -> Header = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(DashboardDesign.paneTitleFont)
                        .foregroundStyle(DashboardDesign.title)
                    if let subtitle {
                        Text(subtitle)
                            .font(DashboardDesign.paneSubtitleFont)
                            .foregroundStyle(DashboardDesign.secondary)
                    }
                }
                Spacer(minLength: 8)
                header
            }
            .padding(.horizontal, DashboardDesign.panePadding)
            .padding(.top, 22)
            .padding(.bottom, 18)

            if scrolls {
                ScrollView(.vertical) {
                    content
                        .padding(.horizontal, DashboardDesign.panePadding)
                        .padding(.bottom, DashboardDesign.panePadding)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                content
                    .padding(.horizontal, DashboardDesign.panePadding)
                    .padding(.bottom, DashboardDesign.panePadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DashboardDesign.surface)
    }
}

/// Bordered panel used for every grouped block in the Dashboard.
public struct DashCard<Content: View>: View {
    private let content: Content
    private let padding: CGFloat

    public init(padding: CGFloat = DashboardDesign.cardPadding, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                    .fill(DashboardDesign.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DashboardDesign.cardRadius, style: .continuous)
                    .strokeBorder(DashboardDesign.border, lineWidth: 1)
            )
    }
}

/// All-caps group label.
public struct DashSectionTitle: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(DashboardDesign.sectionFont)
            .kerning(0.6)
            .foregroundStyle(DashboardDesign.secondary)
    }
}

/// One headline number with a label and an optional footnote.
public struct StatTile: View {
    private let label: String
    private let value: String
    private let footnote: String?
    private let systemImage: String
    private let tint: Color

    public init(
        label: String,
        value: String,
        footnote: String? = nil,
        systemImage: String,
        tint: Color = DashboardDesign.accent
    ) {
        self.label = label
        self.value = value
        self.footnote = footnote
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        DashCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(label)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .lineLimit(1)
                }
                Text(value)
                    .font(DashboardDesign.statFont)
                    .foregroundStyle(DashboardDesign.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(footnote ?? " ")
                    .font(DashboardDesign.captionFont)
                    .foregroundStyle(DashboardDesign.tertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// Neutral "there is nothing here yet" state. Used instead of a blank
/// pane so an empty history explains itself.
public struct DashEmptyState: View {
    private let systemImage: String
    private let title: String
    private let message: String

    public init(systemImage: String, title: String, message: String) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DashboardDesign.tertiary)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DashboardDesign.body)
            Text(message)
                .font(DashboardDesign.bodyFont)
                .foregroundStyle(DashboardDesign.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Small coloured status pill (daemon up/down, outcome, etc.).
public struct DashBadge: View {
    private let text: String
    private let tint: Color

    public init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(0.14))
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.25), lineWidth: 1)
            )
    }
}

/// A labelled row for settings-style panes: description on the left,
/// control on the right. Keeps every control column-aligned across panes
/// without each one inventing its own Form.
public struct DashRow<Control: View>: View {
    private let title: String
    private let help: String?
    private let control: Control

    public init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(DashboardDesign.bodyFont)
                    .foregroundStyle(DashboardDesign.body)
                if let help {
                    Text(help)
                        .font(DashboardDesign.captionFont)
                        .foregroundStyle(DashboardDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 7)
    }
}

/// Hairline between rows inside a card.
public struct DashDivider: View {
    public init() {}
    public var body: some View {
        Rectangle()
            .fill(DashboardDesign.separator)
            .frame(height: 1)
    }
}
