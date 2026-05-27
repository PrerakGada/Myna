// OnboardingView.swift — SwiftUI body for the first-run cinematic.
//
// Layout per docs/v0.2-plan/03-ux-direction.md § 2: dark backdrop with
// a centered card (~480×340). For v0.2 we use a larger ~640×440 card
// to fit the headline + body + caption row + controls without crowding.
//
// IMPORTANT — no TimelineView anywhere. v0.2.1 hotfix established that
// TimelineView burns ~99.5% CPU under SwiftUI's macOS implementation
// (commit 1e58bfd). All animation in this file uses .opacity / .scale
// transitions inside withAnimation, which only triggers a redraw on
// state change.
import AppKit
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        ZStack {
            // Backdrop — re-uses the popover surface so the cinematic
            // feels like part of the same product (PopoverDesign.surface
            // is #0A0A0C, the v0.2 visual-system near-black).
            backdrop
            content
            skipButton
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(PopoverDesign.surface)
        .preferredColorScheme(.dark)
    }

    // MARK: - layers

    @ViewBuilder
    private var backdrop: some View {
        // Soft radial vignette over the near-black. No animation —
        // gradients are GPU-cheap as long as they don't redraw.
        RadialGradient(
            colors: [
                Color.white.opacity(0.04),
                Color.clear,
            ],
            center: .center,
            startRadius: 80,
            endRadius: 420
        )
    }

    @ViewBuilder
    private var content: some View {
        if let slide = controller.currentSlide {
            slideCard(slide)
                .id(slide.id)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    )
                )
                .animation(.easeInOut(duration: 0.35), value: slide.id)
        } else {
            // Completed / skipped state — empty (window dismisses).
            Color.clear
        }
    }

    @ViewBuilder
    private var skipButton: some View {
        // Top-right skip is always available per S11 AC #3.
        VStack {
            HStack {
                Spacer()
                Button(action: { controller.skip() }) {
                    Text("Skip")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PopoverDesign.secondaryColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip onboarding")
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - slide

    @ViewBuilder
    private func slideCard(_ slide: OnboardingSlide) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            birdGlyph
                .padding(.bottom, 4)

            Text(slide.headline)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(PopoverDesign.bodyColor)
                .fixedSize(horizontal: false, vertical: true)

            if !slide.body.isEmpty {
                Text(slide.body)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(PopoverDesign.bodyColor.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(3)
            }

            captionRow

            Spacer(minLength: 0)

            controlsRow(for: slide)
        }
        .padding(40)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PopoverDesign.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(PopoverDesign.cardBorder, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
    }

    @ViewBuilder
    private var birdGlyph: some View {
        // Plain SF Symbol — no animation. v0.2.1 hotfix lesson:
        // SwiftUI animation on the menu-bar bird burned 99% CPU.
        // Here we just show the glyph; the speaking-dot row below
        // is the "alive" signal.
        Image(systemName: "bird.fill")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(PopoverDesign.accent)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var captionRow: some View {
        // Live captions of what Myna is saying. Per S11 AC #7 these
        // are *always* present so VoiceOver / muted users see the
        // script even when audio is silent.
        HStack(alignment: .top, spacing: 10) {
            speakingIndicator
            Text(controller.caption)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(PopoverDesign.secondaryColor)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
                .accessibilityLabel("Myna says: \(controller.caption)")
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var speakingIndicator: some View {
        // Two-dot static "speaking" glyph. The opacity tween below
        // is driven by isSpeaking (a discrete state change), NOT a
        // TimelineView — no redraw between state transitions.
        Circle()
            .fill(controller.isSpeaking ? PopoverDesign.dotSpeaking : PopoverDesign.dotIdle)
            .frame(width: 8, height: 8)
            .animation(.easeInOut(duration: 0.3), value: controller.isSpeaking)
            .padding(.top, 4)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func controlsRow(for slide: OnboardingSlide) -> some View {
        HStack {
            slideDots
            Spacer()
            if slide.isFinal {
                Button(action: { controller.getStarted() }) {
                    HStack(spacing: 6) {
                        Text("Get Started")
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(PopoverDesign.accent)
                    )
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Get started with Myna")
            } else {
                Button(action: { controller.advance() }) {
                    HStack(spacing: 6) {
                        Text("Next")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.white.opacity(0.08))
                    )
                    .foregroundStyle(PopoverDesign.bodyColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityLabel("Next slide")
            }
        }
    }

    @ViewBuilder
    private var slideDots: some View {
        // Position indicator. Static dots, no animation between them.
        HStack(spacing: 6) {
            ForEach(Array(controller.slides.enumerated()), id: \.offset) { (i, _) in
                Circle()
                    .fill(isActiveSlide(i) ? PopoverDesign.bodyColor.opacity(0.9) : PopoverDesign.bodyColor.opacity(0.2))
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func isActiveSlide(_ index: Int) -> Bool {
        if case .showing(let i) = controller.phase { return i == index }
        return false
    }
}

// MARK: - Preview

#Preview("Onboarding — slide 1") {
    let controller = OnboardingController(client: nil, player: nil)
    return OnboardingView(controller: controller)
        .frame(width: 720, height: 480)
}

#Preview("Onboarding — final slide") {
    let controller = OnboardingController(client: nil, player: nil)
    // Drive to the final slide by calling advance repeatedly — the
    // controller respects `phase` so the preview lands on the CTA.
    for _ in 0..<(OnboardingScript.all.count - 1) {
        controller.advance()
    }
    return OnboardingView(controller: controller)
        .frame(width: 720, height: 480)
}
