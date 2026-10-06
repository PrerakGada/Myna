// StudioJobPresentation.swift — what a library row says about a render job.
//
// The mapping from RenderJob to words lives here, apart from the views,
// so it can be tested without rendering anything: which badge, which
// progress, which one-line summary, and what a failure means in plain
// language rather than the daemon's reason code.
import Foundation

struct StudioJobPresentation: Equatable {
    enum Phase: Equatable {
        case queued, rendering, encoding, done, failed, cancelled
    }

    enum Tint: Equatable {
        case accent, positive, warning, negative, neutral
    }

    let phase: Phase
    /// Empty for finished jobs: the row's content says it all.
    let badge: String
    let tint: Tint
    /// 0…1 for a bar; nil when there's no bar, or it's indeterminate.
    let progress: Double?
    let showsIndeterminateProgress: Bool
    /// The line under the title.
    let detail: String
    /// Why it failed, in plain words, for failed jobs.
    let failure: String?
    let canCancel: Bool
    let canRetry: Bool
    let canPlay: Bool

    /// - Parameters:
    ///   - ahead: active jobs created before this one (for a queued job).
    ///   - hasRequest: whether the app still has the original request, which
    ///     retry needs.
    static func make(job: RenderJob, ahead: Int = 0, hasRequest: Bool) -> StudioJobPresentation {
        let words = job.words > 0 ? "\(HistoryAnalytics.compactCount(job.words)) words" : nil
        switch job.status {
        case .queued:
            let wait = ahead == 0 ? "Starting soon" : "Waiting for \(ahead) render\(ahead == 1 ? "" : "s") ahead"
            return StudioJobPresentation(
                phase: .queued, badge: "Queued", tint: .neutral, progress: nil, showsIndeterminateProgress: false,
                detail: join([wait, words]), failure: nil, canCancel: true, canRetry: false, canPlay: false)
        case .rendering:
            var parts: [String?] = []
            if job.chunksTotal > 0 {
                parts.append("\(job.chunksDone) of \(job.chunksTotal) parts")
            } else {
                parts.append("Starting")
            }
            if job.audioS > 0 { parts.append("\(StudioFormat.duration(job.audioS)) of audio") }
            if let eta = job.etaS, eta > 0 { parts.append("about \(StudioFormat.duration(eta)) left") }
            return StudioJobPresentation(
                phase: .rendering, badge: "Rendering", tint: .accent,
                progress: min(1, max(0, job.progress)), showsIndeterminateProgress: false,
                detail: join(parts), failure: nil, canCancel: true, canRetry: false, canPlay: false)
        case .encoding:
            return StudioJobPresentation(
                phase: .encoding, badge: "Encoding", tint: .accent, progress: nil, showsIndeterminateProgress: true,
                detail: join(["Saving the \(StudioFormat.formatLabel(job.format)) file",
                              job.audioS > 0 ? "\(StudioFormat.duration(job.audioS)) of audio" : nil]),
                failure: nil, canCancel: true, canRetry: false, canPlay: false)
        case .done:
            let chapters = job.chapters?.count ?? 0
            return StudioJobPresentation(
                phase: .done, badge: "", tint: .positive, progress: nil, showsIndeterminateProgress: false,
                detail: join([
                    StudioFormat.duration(job.audioS),
                    job.bytes.map(StudioFormat.bytes),
                    StudioFormat.formatLabel(job.format),
                    job.voice,
                    abs(job.speed - 1) > 0.001 ? StudioFormat.speed(job.speed) : nil,
                    StudioFormat.when(job.finishedAt ?? job.createdAt),
                    chapters > 1 ? "\(chapters) chapters" : nil,
                ]),
                failure: nil, canCancel: false, canRetry: false, canPlay: job.filePath != nil)
        case .failed:
            return StudioJobPresentation(
                phase: .failed, badge: "Failed", tint: .negative, progress: nil, showsIndeterminateProgress: false,
                detail: join([StudioFormat.when(job.finishedAt ?? job.createdAt), words]),
                failure: failureText(job), canCancel: false, canRetry: hasRequest, canPlay: false)
        case .cancelled:
            return StudioJobPresentation(
                phase: .cancelled, badge: "Cancelled", tint: .neutral, progress: nil, showsIndeterminateProgress: false,
                detail: join([StudioFormat.when(job.finishedAt ?? job.createdAt), words]),
                failure: nil, canCancel: false, canRetry: hasRequest, canPlay: false)
        }
    }

    /// The daemon's reason codes (RENDER_API.md §2) as a sentence that
    /// says what happened and what to do.
    static func failureText(_ job: RenderJob) -> String {
        let detail = job.error?.detail.flatMap { $0.isEmpty ? nil : $0 }
        switch job.error?.reason {
        case "interrupted":
            return "Myna's voice service stopped while this was rendering. Retry to start it again."
        case "engine_changed":
            return "The voice engine was switched after this was queued. Retry to render it with the current engine."
        case "engine_down":
            return "The voice engine stopped responding. Check the Engine pane, then retry."
        case "engine_error":
            return "The voice engine failed" + (detail.map { ": \($0)" } ?? ".")
        case "encode_failed":
            return "The audio couldn't be saved as \(StudioFormat.formatLabel(job.format))"
                + (detail.map { ": \($0)" } ?? ".") + " Retry with another format."
        case .some(let reason):
            return detail ?? reason.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        case .none:
            return detail ?? "It stopped without saying why."
        }
    }

    private static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Number and time formatting shared by Studio's views.
enum StudioFormat {
    /// "42s", "12m 5s", "1h 12m".
    static func duration(_ seconds: Double) -> String {
        HistoryAnalytics.durationString(max(0, seconds))
    }

    /// "4:05", "1:02:03" — a player's clock.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    /// "1×", "1.5×", "1.25×".
    static func speed(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    /// "M4A", "MP3" — upper-cased format id, the way people name files.
    static func formatLabel(_ id: String) -> String {
        id == "opus" ? "Ogg Opus" : id.uppercased()
    }

    static func when(_ unixSeconds: Double) -> String {
        let date = Date(timeIntervalSince1970: unixSeconds)
        if Calendar.current.isDateInToday(date) {
            return "today at " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// How long a document will be as audio, before it's rendered.
enum StudioEstimate {
    /// Kokoro at 1× reads a little faster than a person does aloud.
    static let fallbackWordsPerMinute: Double = 160

    static func seconds(words: Int, speed: Double, wordsPerMinute: Double) -> Double {
        guard words > 0, wordsPerMinute > 0 else { return 0 }
        return Double(words) / (wordsPerMinute * max(0.25, speed)) * 60
    }

    static func totalSeconds(sectionWords: [Int], speed: Double, wordsPerMinute: Double, pauseMs: Int) -> Double {
        let speech = sectionWords.reduce(0) { $0 + seconds(words: $1, speed: speed, wordsPerMinute: wordsPerMinute) }
        let pauses = Double(max(0, sectionWords.count - 1) * max(0, pauseMs)) / 1000
        return speech + pauses
    }

    /// This Mac's measured pace at 1×: finished renders on the active
    /// engine first (they're the same kind of work), then completed reads
    /// at normal speed from History, else the fallback. The median, so one
    /// odd file doesn't skew it.
    static func wordsPerMinute(renders: [RenderJob], engine: String?, history: [ReadEvent]) -> Double {
        let fromRenders = renders.compactMap { job -> Double? in
            guard job.status == .done, job.words >= 150, job.audioS >= 30 else { return nil }
            if let engine, job.engine != engine { return nil }
            return Double(job.words) / (job.audioS / 60) / max(0.25, job.speed)
        }
        if let median = median(fromRenders) { return clamp(median) }

        let fromReads = history.compactMap { event -> Double? in
            guard event.outcome == .completed, abs(event.speed - 1) < 0.01,
                  event.words >= 60, event.audioSeconds >= 20 else { return nil }
            return Double(event.words) / (event.audioSeconds / 60)
        }
        if let median = median(fromReads) { return clamp(median) }
        return fallbackWordsPerMinute
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private static func clamp(_ wpm: Double) -> Double { min(260, max(100, wpm)) }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
