// OnboardingScript.swift — typed model + script content for the v0.2
// first-run cinematic (S11).
//
// Source script: docs/v0.2-plan/03-ux-direction.md § 2. The full ~60s
// brief weaves three permission prompts into the narration; for v0.2
// we condense to FIVE slides covering the same beats but only firing
// ONE permission prompt (Accessibility — the only one Myna currently
// fails-silent without). Notifications + Input Monitoring stay as
// future work since the existing app doesn't request them.
//
// Adding/reordering slides only requires editing `OnboardingScript.all`
// — the controller iterates through whatever's here. Per S11 AC #2:
// "Scene loader iterates through scene modules in order; adding scenes
// requires no orchestrator change."
import Foundation

/// One slide of the cinematic. The `spoken` string is fed into the
/// daemon's TTS pipeline so the user hears Myna's actual voice while
/// the slide is on screen — this is the "dogfood" part of the brief.
/// `fallbackDuration` is used if synthesis fails (S11 AC #5: 30s cap)
/// or if the user has VoiceOver active and silent-mode is engaged.
public struct OnboardingSlide: Equatable, Sendable {
    /// Stable identifier for state persistence (`first_run_scene_reached`).
    public let id: String
    /// Headline shown large at the top of the slide.
    public let headline: String
    /// Body copy under the headline. May span multiple lines.
    public let body: String
    /// Text spoken aloud by Myna while this slide is visible. Kept short
    /// so each slide lands in ~8-15s of audio.
    public let spoken: String
    /// Fallback duration if synthesis fails (no audio to wait for) or
    /// if VoiceOver is running. Per S11 AC #5: max 30s per scene.
    public let fallbackDuration: TimeInterval
    /// If `true`, this slide triggers the Accessibility-permission
    /// prompt as part of its narration. Currently only `permissions`.
    public let requestsAccessibility: Bool
    /// If `true`, this is the final slide — the "Get Started" CTA
    /// replaces the Next affordance.
    public let isFinal: Bool

    public init(
        id: String,
        headline: String,
        body: String,
        spoken: String,
        fallbackDuration: TimeInterval = 8,
        requestsAccessibility: Bool = false,
        isFinal: Bool = false
    ) {
        self.id = id
        self.headline = headline
        self.body = body
        self.spoken = spoken
        self.fallbackDuration = fallbackDuration
        self.requestsAccessibility = requestsAccessibility
        self.isFinal = isFinal
    }
}

public enum OnboardingScript {
    /// Ordered list of slides for the cinematic. Adapted from the
    /// 60s script in docs/v0.2-plan/03-ux-direction.md § 2.
    ///
    /// Beats:
    ///   1. Hi → introduce Myna (0:00-0:03)
    ///   2. What I do → reading companion, local-only (0:03-0:11)
    ///   3. Three small things → permission ask framing (0:11-0:16)
    ///   4. Accessibility prompt → fires the TCC dialog (0:16-0:28)
    ///   5. Final → "I live up here" + Get Started (0:52-0:58)
    ///
    /// The v0.3 cinematic will expand back to the full 6-slide script
    /// with notifications + input-monitoring scenes; for v0.2 we ship
    /// the condensed version.
    public static let all: [OnboardingSlide] = [
        OnboardingSlide(
            id: "intro",
            headline: "Hi. I'm Myna.",
            body: "",
            spoken: "Hi. I'm Myna.",
            fallbackDuration: 4
        ),
        OnboardingSlide(
            id: "what-i-do",
            headline: "Your reading companion.",
            body: "I read things out loud. Articles you're scrolling. Replies from Claude. Anything you've selected. All from right here on your Mac.",
            spoken:
                "I read things out loud. Articles you're scrolling. Replies from Claude. Anything you've selected. All from right here on your Mac. Nothing goes to the cloud.",
            fallbackDuration: 12
        ),
        OnboardingSlide(
            id: "small-things",
            headline: "Just one small thing.",
            body: "To do this well, I need permission to know what you've highlighted. I'll only read what you tell me to.",
            spoken: "To do this well, I need one small thing. I'll ask once.",
            fallbackDuration: 6
        ),
        OnboardingSlide(
            id: "permissions",
            headline: "Accessibility",
            body: "This lets me see what you've selected when you press the shortcut. I never read your screen on my own. Only when you tell me to.",
            spoken:
                "Accessibility. This lets me know what you've highlighted. I never read your screen on my own. Only when you tell me to.",
            fallbackDuration: 12,
            requestsAccessibility: true
        ),
        OnboardingSlide(
            id: "final",
            headline: "I live up here.",
            body: "Click the bird in your menu bar anytime. Try the Option-Command-K shortcut on any selected text to hear me again.",
            spoken: "I live up here. Click me anytime. Let's start.",
            fallbackDuration: 6,
            isFinal: true
        ),
    ]
}
