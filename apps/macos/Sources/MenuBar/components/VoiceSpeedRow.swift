// VoiceSpeedRow.swift — voice and speed on one line.
//
// Replaces the VOICE tile grid and the SPEED chip row. Between them they
// took ~150pt of the popover for two settings that are picked once and
// then left alone, and the grid opened by default on a stock install, so
// the most prominent thing in the popover was the thing least often
// touched. Now it is one row read left to right: voice menu, a Test
// button that plays that voice at the current speed, and a stepped speed
// slider.
//
// Speed is a slider rather than a menu of numbers: the presets are an
// ordered scale, and dragging along it (or clicking a notch) says
// "slower / faster" in a way a list of six figures doesn't.
//
// The voice menu is a SwiftUI `Menu` with a hand-drawn label. The
// popover's window is never key and AppKit's button chrome flashes system
// blue on our dark surface (see HoverableRow), so the label draws its own
// pill and `.buttonStyle(.plain)` keeps AppKit from painting over it. The
// pop-up itself is a real NSMenu, which gives native checkmarks.
import AppKit
import SwiftUI

public struct VoiceSpeedRow: View {
    public let voices: [Voice]
    /// Currently selected voice id, or nil when settings haven't loaded.
    public let selectedVoiceId: String?
    public let speed: Double
    public let onSelectVoice: (String) -> Void
    public let onPreview: () -> Void
    public let onSelectSpeed: (Double) -> Void
    /// Offered inside the voice menu when the list is empty — the daemon
    /// may not have answered by the time the popover first rendered.
    public let onRefreshVoices: () -> Void

    /// AVAudioUnitTimePitch's `.rate` hard-caps at 2.0× — values above
    /// silently clamp. Matches the old chip row and Menu options 1:1.
    public static let speedOptions: [Double] = [0.75, 1.0, 1.2, 1.5, 1.75, 2.0]

    public init(
        voices: [Voice],
        selectedVoiceId: String?,
        speed: Double,
        onSelectVoice: @escaping (String) -> Void,
        onPreview: @escaping () -> Void,
        onSelectSpeed: @escaping (Double) -> Void,
        onRefreshVoices: @escaping () -> Void
    ) {
        self.voices = voices
        self.selectedVoiceId = selectedVoiceId
        self.speed = speed
        self.onSelectVoice = onSelectVoice
        self.onPreview = onPreview
        self.onSelectSpeed = onSelectSpeed
        self.onRefreshVoices = onRefreshVoices
    }

    public var body: some View {
        HStack(spacing: 10) {
            Text("VOICE")
                .font(PopoverDesign.sectionHeaderFont)
                .tracking(0.5)
                .foregroundStyle(PopoverDesign.sectionHeaderColor)
            voiceMenu
            TestButton(voiceLabel: currentVoiceLabel, action: onPreview)
            SpeedSlider(
                options: Self.speedOptions,
                speed: speed,
                onSelect: onSelectSpeed
            )
            .frame(minWidth: 80, maxWidth: .infinity)
            Text(Self.formatSpeed(speed))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(PopoverDesign.bodyColor)
                // Wide enough for "0.75×", so the slider doesn't shift
                // as the label changes length.
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - voice

    /// With a handful of voices the menu is one list. Kokoro lists 41 in
    /// seven languages, so past that the user's own voices and the first
    /// group stay in the menu and every other language gets a submenu.
    private var voiceMenu: some View {
        Menu {
            if voices.isEmpty {
                Button("Refresh voice list", action: onRefreshVoices)
            } else {
                let groups = voices.grouped()
                let inline = Self.inlineGroups(groups, total: voices.count)
                ForEach(groups.filter { inline.contains($0.name) }) { group in
                    groupPicker(group, titled: groups.count > 1)
                }
                ForEach(groups.filter { !inline.contains($0.name) }) { group in
                    Menu(group.name) {
                        groupPicker(group, titled: false)
                    }
                }
            }
        } label: {
            MenuPill(title: currentVoiceLabel)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Voice: \(currentVoiceLabel)")
    }

    @ViewBuilder
    private func groupPicker(_ group: VoiceGroup, titled: Bool) -> some View {
        Picker(titled ? group.name : "", selection: voiceBinding) {
            ForEach(group.voices) { voice in
                Text(Self.displayLabel(voice)).tag(voice.id)
            }
        }
        .pickerStyle(.inline)
    }

    /// Groups shown in the top-level menu rather than a submenu.
    nonisolated static func inlineGroups(_ groups: [VoiceGroup], total: Int) -> Set<String> {
        if total <= 16 { return Set(groups.map(\.name)) }
        var names = Set(groups.filter(\.isUserMade).map(\.name))
        if let firstBuiltIn = groups.first(where: { !$0.isUserMade }) {
            names.insert(firstBuiltIn.name)
        }
        return names
    }

    private var voiceBinding: Binding<String> {
        Binding(
            get: { voices.effectiveVoiceId(saved: selectedVoiceId) ?? "" },
            set: { onSelectVoice($0) }
        )
    }

    /// The saved voice may belong to another engine (saved "af_heart",
    /// engine now Pocket); the daemon then reads with this engine's
    /// default, so that is the name to show.
    private var currentVoiceLabel: String {
        guard let id = voices.effectiveVoiceId(saved: selectedVoiceId) else {
            return selectedVoiceId ?? "—"
        }
        if let match = voices.first(where: { $0.id == id }) {
            return Self.displayLabel(match)
        }
        return id
    }

    /// Voice.label is the daemon's human-readable name; an empty one
    /// degrades to the id so voices stay distinguishable.
    static func displayLabel(_ voice: Voice) -> String {
        voice.label.isEmpty ? voice.id : voice.label
    }

    // MARK: - speed

    /// 0.75 → "0.75×"; 1.0 → "1×"; 1.2 → "1.2×"; 2.0 → "2×"
    static func formatSpeed(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))×"
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return "\(text)×"
    }

    /// The preset nearest `speed`. A speed set elsewhere that isn't a
    /// preset (none today) snaps the knob to the closest notch.
    static func nearestIndex(to speed: Double, in options: [Double]) -> Int {
        options.indices.min { abs(options[$0] - speed) < abs(options[$1] - speed) } ?? 0
    }
}

// MARK: - pieces

/// Faint rounded pill shared by the voice menu and the Test button, so the
/// two read as a pair of controls rather than loose text.
private struct PillBackground: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? PopoverDesign.hoverFill : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(PopoverDesign.cardBorder, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// The closed voice menu: name plus an up-down chevron.
private struct MenuPill: View {
    let title: String

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PopoverDesign.bodyColor)
                .lineLimit(1)
                .truncationMode(.tail)
                // A long voice name must not squeeze the slider to nothing.
                .frame(maxWidth: 130, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(PopoverDesign.secondaryColor)
        }
        .modifier(PillBackground(isHovering: isHovering))
        .onHover { isHovering = $0 }
    }
}

/// Plays the selected voice at the selected speed. Its own control, not a
/// menu item — an NSMenu item can't carry a second action.
private struct TestButton: View {
    let voiceLabel: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .semibold))
            Text("Test")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(isHovering ? PopoverDesign.accent : PopoverDesign.bodyColor)
        .modifier(PillBackground(isHovering: isHovering))
        .fixedSize()
        .onHover { isHovering = $0 }
        .onTapGesture(perform: action)
        .help("Hear \(voiceLabel) at this speed")
        .accessibilityLabel("Test \(voiceLabel)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A slider that only lands on the presets. Drag along it or click a
/// notch; each notch crossed ticks the trackpad. Drawn by hand because
/// NSSlider's stepped style can't space six unevenly-valued presets
/// evenly, and its chrome renders inactive in the never-key popover.
private struct SpeedSlider: View {
    let options: [Double]
    let speed: Double
    let onSelect: (Double) -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    private let knobSize: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let index = VoiceSpeedRow.nearestIndex(to: speed, in: options)
            let usable = max(1, geo.size.width - knobSize)
            let step = usable / CGFloat(max(1, options.count - 1))
            let knobX = knobSize / 2 + step * CGFloat(index)
            let midY = geo.size.height / 2

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: usable, height: 3)
                    .position(x: geo.size.width / 2, y: midY)
                Capsule()
                    .fill(PopoverDesign.accent)
                    .frame(width: max(0, knobX - knobSize / 2), height: 3)
                    .position(x: knobSize / 2 + (knobX - knobSize / 2) / 2, y: midY)
                ForEach(options.indices, id: \.self) { i in
                    Circle()
                        .fill(i <= index ? PopoverDesign.accent : Color.white.opacity(0.3))
                        .frame(width: 4, height: 4)
                        .position(x: knobSize / 2 + step * CGFloat(i), y: midY)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
                    .scaleEffect(isDragging ? 1.2 : (isHovering ? 1.1 : 1))
                    .position(x: knobX, y: midY)
                    .animation(.easeOut(duration: 0.12), value: index)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let raw = (value.location.x - knobSize / 2) / step
                        let target = min(options.count - 1, max(0, Int(raw.rounded())))
                        if target != index {
                            NSHapticFeedbackManager.defaultPerformer.perform(
                                .alignment, performanceTime: .now)
                            onSelect(options[target])
                        }
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: 24)
        .onHover { isHovering = $0 }
        .help("Playback speed")
        .accessibilityElement()
        .accessibilityLabel("Speed")
        .accessibilityValue(VoiceSpeedRow.formatSpeed(speed))
        .accessibilityAdjustableAction { direction in
            let index = VoiceSpeedRow.nearestIndex(to: speed, in: options)
            switch direction {
            case .increment where index < options.count - 1: onSelect(options[index + 1])
            case .decrement where index > 0: onSelect(options[index - 1])
            default: break
            }
        }
    }
}
