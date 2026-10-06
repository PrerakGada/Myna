// AppDispatcher+Summaries.swift — the dispatcher's side of summary reads:
// build the request (SummaryService writes the summary first), and tell the
// user why one didn't play. The deciding happens in SummaryService
// (Sources/Summaries/). Kept out of AppDispatcher.swift, which is at its
// length limits; makeRequest is internal rather than private for this.
import Foundation

extension AppDispatcher {
    /// The request to send for `read`. A summary read's summary is written
    /// first (SummaryService.request), so this can take seconds, or halt.
    func request(for read: QueuedRead) async -> SummaryStep {
        await summaries.request(for: makeRequest(
            text: read.text, url: read.url, mode: read.mode, bundleId: read.appBundleId, source: read.source))
    }

    /// Show a halted summary's notice and close its History row as failed.
    /// Returns the failure text for the queue's log, or nil when there is no
    /// notice (the read was cancelled, or the error wasn't a summary's).
    @discardableResult
    static func present(_ step: SummaryStep, on menu: MenuBarController?, history: HistoryRecorder?) -> String? {
        guard case .halt(let notice?) = step else { return nil }
        menu?.showNotice(title: notice.title, hint: notice.hint)
        history?.noteFailure(notice.title)
        return notice.title
    }
}
