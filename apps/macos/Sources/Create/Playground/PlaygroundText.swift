// PlaygroundText.swift — the arithmetic behind the Playground's editor:
// counts, the spoken-length estimate, the single-clip limit, the sample
// texts, Markdown flattening for dropped files, and the default filename
// for a saved take.
//
// Everything here is pure and nonisolated so it is unit-tested without a
// window, and so the views can call it on every keystroke without caring
// which actor they are on.
import Foundation

enum PlaygroundText {

    /// POST /v1/audio/speech refuses more than this (RENDER_API.md §1).
    /// Counted in Unicode scalars, which is what the daemon's Python
    /// `len()` counts, so both sides agree on where the line is.
    static let syncCharacterLimit = 40_000

    /// Spoken words per minute at 1×. Kokoro's voices land around
    /// 150–170 on plain prose; the estimate says "about" for a reason.
    static let wordsPerMinute: Double = 160

    /// Largest file a drop will load into the editor. Anything bigger is
    /// far past the single-clip limit anyway and belongs in Studio.
    static let maxDroppedFileBytes = 2_000_000

    /// Extensions a drop onto the editor accepts.
    static let droppableExtensions: Set<String> = ["txt", "text", "md", "markdown"]

    struct Stats: Equatable, Sendable {
        let characters: Int
        let words: Int
        let estimatedSeconds: Double

        var isOverLimit: Bool { characters > PlaygroundText.syncCharacterLimit }
        var isEmpty: Bool { words == 0 }
    }

    static func stats(for text: String, speed: Double) -> Stats {
        let words = wordCount(text)
        return Stats(
            characters: characterCount(text),
            words: words,
            estimatedSeconds: estimatedSeconds(words: words, speed: speed)
        )
    }

    static func characterCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// Whitespace-separated tokens that contain a letter or a digit, so a
    /// stray dash or bullet doesn't count as a word.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { token in token.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    /// Seconds of speech for `words` at `speed` (clamped to the daemon's
    /// 0.5–2.0 range). Pass 1 for engines that ignore speed.
    static func estimatedSeconds(words: Int, speed: Double) -> Double {
        guard words > 0 else { return 0 }
        let rate = max(0.5, min(2.0, speed))
        return Double(words) / wordsPerMinute * 60 / rate
    }

    // MARK: - formatting

    /// "0:07", "4:05", "1:02:09" — a clock, for playheads and durations.
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "about 1m 20s" for the editor footer.
    static func estimateLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "nothing to speak" }
        if seconds < 1 { return "under a second" }
        return "about \(HistoryAnalytics.durationString(seconds))"
    }

    /// "40,000" — exact, grouped. Near a limit the exact count matters.
    static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "1.8 s" / "420 ms" for render times.
    static func renderTimeLabel(ms: Int) -> String {
        if ms < 1_000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1_000)
    }

    /// "1×", "1.25×".
    static func speedLabel(_ speed: Double) -> String {
        var text = String(format: "%.2f", speed)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + "×"
    }

    // MARK: - samples

    struct Sample: Identifiable, Equatable, Sendable {
        let title: String
        let text: String
        var id: String { title }
    }

    /// Short texts that exercise the things voices differ on: pace,
    /// numbers, dialogue, names and questions.
    static let samples: [Sample] = [
        Sample(
            title: "A short paragraph",
            text: "Most of the old town sits on a hill above the river. In the morning the streets "
                + "are quiet, and the only sounds are a bakery fan and a radio somewhere upstairs. "
                + "By noon the market opens and the square fills with people buying fruit and bread."
        ),
        Sample(
            title: "Numbers and dates",
            text: "The train leaves platform 4 at 7:45 a.m. on Tuesday, 3 March 2026. A return ticket "
                + "costs $18.50, and the trip takes 2 hours and 15 minutes. Seats 21 to 36 are in coach B."
        ),
        Sample(
            title: "Dialogue",
            text: "\"Are you coming?\" she asked. He looked at the clock, then at the rain on the window. "
                + "\"Give me ten minutes,\" he said. \"I'll be right behind you.\""
        ),
        Sample(
            title: "Names and abbreviations",
            text: "Dr. Nguyen reviewed the MRI results with the NASA team in Worcester, then flew to "
                + "Reykjavík by way of Zürich. The report is due to the WHO by 5 p.m. on Friday."
        ),
        Sample(
            title: "Questions and a list",
            text: "Before you leave, check three things: the stove is off, the windows are shut, and "
                + "the back door is locked. Did you remember all three? Good. Then we can go."
        ),
    ]

    // MARK: - files

    /// Default name for a saved take: the first few words, then the voice.
    /// `"The train leaves platform 4 at - Heart (female).wav"`.
    static func defaultFileName(
        text: String,
        voice: String?,
        ext: String,
        maxWords: Int = 6,
        maxLength: Int = 60
    ) -> String {
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { sanitizeFileComponent(String($0)) }
            .filter { !$0.isEmpty }
        var stem = ""
        for word in words.prefix(maxWords) {
            let candidate = stem.isEmpty ? word : stem + " " + word
            if candidate.count > maxLength { break }
            stem = candidate
        }
        if stem.isEmpty, let first = words.first {
            stem = String(first.prefix(maxLength))
        }
        stem = stem.trimmingCharacters(in: trailingPunctuation)
        if stem.isEmpty { stem = "Myna take" }

        if let voice {
            let cleanVoice = sanitizeFileComponent(voice).trimmingCharacters(in: .whitespaces)
            if !cleanVoice.isEmpty { stem += " - " + cleanVoice }
        }
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleanExt.isEmpty ? stem : "\(stem).\(cleanExt)"
    }

    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?…-–—'\"“”‘’()[] ")

    /// Removes what Finder or the shell would choke on, and leading dots
    /// (which would hide the file).
    static func sanitizeFileComponent(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let kept = raw.unicodeScalars.filter { !banned.contains($0) }
        var out = String(String.UnicodeScalarView(kept))
        while out.hasPrefix(".") { out.removeFirst() }
        return out
    }

    /// Reads a dropped text file. Markdown is flattened to the words a
    /// person would read aloud. Returns nil for a file that isn't text.
    static func loadDroppedFile(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        guard let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" ? plainText(fromMarkdown: raw) : raw
    }

    /// A deliberately light Markdown flattener: headings, emphasis, inline
    /// code, links and images, block quotes, list markers and fenced code
    /// markers. It keeps the words and drops the punctuation a voice would
    /// otherwise read out ("asterisk asterisk").
    static func plainText(fromMarkdown markdown: String) -> String {
        var lines: [String] = []
        for rawLine in markdown.components(separatedBy: .newlines) {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { continue }
            if trimmed.range(of: #"^([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            line = replace(line, #"^\s{0,3}#{1,6}\s+"#, with: "")
            line = replace(line, #"^\s*>\s?"#, with: "")
            line = replace(line, #"^\s*([-*+]|\d+[.)])\s+"#, with: "")
            line = replace(line, #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
            line = replace(line, #"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
            line = replace(line, #"(\*\*|__)(.+?)\1"#, with: "$2")
            line = replace(line, #"(?<![\w*])[*_](?!\s)(.+?)(?<!\s)[*_](?![\w*])"#, with: "$1")
            line = replace(line, #"`([^`]*)`"#, with: "$1")
            line = replace(line, #"\s+#+\s*$"#, with: "")
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
