// TextCleanupSettings.swift — which reads the daemon cleans up.
//
// The switches live in the app, not in the daemon's config, and reach the
// daemon on every read as `prep`. That keeps the daemon's text prep a pure
// function of each request: the CLI and API callers get the documented
// default whatever the app is set to, History can re-run a past read with
// the prep it was read with, and nothing has to keep a daemon setting in
// step with a checkbox.
import Foundation

extension SettingsViewModel {
    /// The prep for a read from `source`: `.literal` when cleanup is off,
    /// globally or for that source.
    public func textPrep(for source: ReadSource) -> TextPrep {
        guard textCleanup else { return .literal }
        switch source {
        case .claudeCode:
            return textCleanupClaudeCode ? .auto : .literal
        case .article:
            return textCleanupArticles ? .auto : .literal
        case .selection, .clipboard:
            return textCleanupSelection ? .auto : .literal
        case .replay, .onboarding, .preview, .unknown:
            return .auto
        }
    }
}
