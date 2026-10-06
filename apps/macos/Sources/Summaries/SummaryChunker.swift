// SummaryChunker.swift — cutting a long text into parts a small model can
// summarize one at a time.
//
// Apple's on-device model has a small context window (4,096 tokens on
// macOS 26, 8,192 on this Mac's macOS 27), and it has to hold the
// instructions, the text and the answer. So a long text is split at paragraph
// breaks, then sentence ends, then spaces, into parts that fit. Same rules as
// daemon/myna/summarize.py split_for_summary, so both backends see the same
// parts.
import Foundation

public enum SummaryChunker {

    /// Characters per token, rounded down on purpose: names, numbers and
    /// non-English words cost more tokens than plain English prose.
    static let charsPerToken = 3.0
    /// Tokens the instructions and the prompt wording take, with room to spare.
    static let promptReserveTokens = 400
    /// Tokens kept free for a summary's answer.
    static let answerReserveTokens = 500
    /// Largest part, whatever the window: the daemon's PART_CHARS and
    /// PLAIN_PART_CHARS. Smaller parts also keep a small model on track.
    static let maxPartChars = 16_000
    static let maxPlainPartChars = 9_000
    /// Below this a part is not split further when it still doesn't fit.
    public static let minPartChars = 400

    /// How many characters of text one call can take in `style`, given a
    /// model's context window.
    public static func partChars(contextTokens: Int, style: SummaryStyle) -> Int {
        let usable = Double(max(0, contextTokens - promptReserveTokens))
        if style == .plainEnglish {
            // A rewrite's answer is about as long as its input.
            return max(minPartChars, min(maxPlainPartChars, Int(usable / 2 * charsPerToken)))
        }
        let forText = usable - Double(answerReserveTokens)
        return max(minPartChars, min(maxPartChars, Int(forText * charsPerToken)))
    }

    /// Split `text` into parts no longer than `maxChars`, in order, losing
    /// nothing but the whitespace at the cuts.
    public static func split(_ text: String, maxChars: Int) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        guard text.count > maxChars else { return [text] }
        var pieces: [String] = []
        for paragraph in paragraphs(text) where !paragraph.isEmpty {
            if paragraph.count <= maxChars {
                pieces.append(paragraph)
                continue
            }
            for sentence in sentences(paragraph) {
                if sentence.count <= maxChars {
                    pieces.append(sentence)
                } else {
                    pieces.append(contentsOf: splitWords(sentence, maxChars: maxChars))
                }
            }
        }
        return pack(pieces, maxChars: maxChars, separator: "\n\n")
    }

    /// Two pieces, cut at the break nearest the middle that leaves neither
    /// over 60% of the text (three only when one sentence is that long).
    /// Used when a part turned out not to fit after all: the model reported
    /// the context overflowed.
    public static func halves(_ text: String) -> [String] {
        split(text, maxChars: max(minPartChars, text.count * 3 / 5))
    }

    // MARK: - private

    private static func paragraphs(_ text: String) -> [String] {
        splitting(text, pattern: #"\n\s*\n"#)
    }

    private static func sentences(_ paragraph: String) -> [String] {
        splitting(paragraph, pattern: #"(?<=[.!?])\s+"#)
    }

    private static func splitting(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        var out: [String] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            out.append(String(text[start..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = range.upperBound
        }
        out.append(String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return out.filter { !$0.isEmpty }
    }

    private static func splitWords(_ sentence: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if word.count > maxChars {
                if !current.isEmpty { out.append(current); current = "" }
                var rest = Substring(word)
                while !rest.isEmpty {
                    out.append(String(rest.prefix(maxChars)))
                    rest = rest.dropFirst(maxChars)
                }
                continue
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count <= maxChars {
                current = candidate
            } else {
                out.append(current)
                current = word
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func pack(_ pieces: [String], maxChars: Int, separator: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = current.isEmpty ? piece : current + separator + piece
            if candidate.count <= maxChars {
                current = candidate
            } else {
                if !current.isEmpty { parts.append(current) }
                current = piece
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
