// SummaryPrompts.swift — the words Myna says to a model when it asks for a
// summary, and the clean-up of what comes back.
//
// The daemon's Ollama fallback uses exactly the same wording:
// daemon/myna/summarize.py (INSTRUCTIONS, _STYLE_PROMPTS, _PART_PROMPT,
// _PARTS_PREFACE, tidy). Change one, change the other, word for word, so a
// summary sounds the same whichever model wrote it.
//
// Every prompt says the output will be heard: no markdown, no symbol lists,
// no "Here is a summary" opener. Small models still slip now and then, so
// `tidy` removes those few things after the fact.
import Foundation

public enum SummaryPrompts {

    /// The session instructions (Python: INSTRUCTIONS).
    public static let instructions =
        "You write summaries that Myna will read aloud, so write for listening. "
        + "Use plain spoken sentences: no markdown, no headings, no bullet points, "
        + "no numbered lists, and no symbols such as asterisks, hashes or dashes. "
        + "Start with the content itself, never with a preamble such as "
        + "\"Here is a summary\". Use only what the text says, and add no facts or "
        + "opinions of your own."

    /// What to write (Python: _STYLE_PROMPTS).
    public static func stylePrompt(_ style: SummaryStyle) -> String {
        switch style {
        case .tldr:
            return "Summarize the text in two or three sentences, and no more. Lead with "
                + "the most important fact, then add only what a listener most needs to "
                + "know."
        case .keyPoints:
            return "Give the key points of the text as a short spoken list of three to "
                + "five points. Start each point with an ordinal word, in order: First, "
                + "Second, Third, and so on. Use one or two full sentences per point."
        case .actionItems:
            return "Tell the listener what the text asks them to do, speaking to them as "
                + "you, most important first. Give each action as one short sentence, "
                + "with any deadline, place or contact the text gives. Leave out things "
                + "that will simply happen to them. If the text asks nothing of them, "
                + "say only: There's nothing you need to do."
        case .plainEnglish:
            return "Rewrite the text in plain English so it is easy to follow by ear. "
                + "Use short sentences and everyday words, and explain any jargon in "
                + "passing. Keep all of the meaning and most of the detail: simplify, "
                + "but do not shorten it much."
        }
    }

    /// One pass over the whole text. The instructions go in the session, so
    /// this is the Python prompt minus its first paragraph.
    public static func prompt(_ style: SummaryStyle, text: String) -> String {
        "\(stylePrompt(style))\n\nTEXT:\n\(text)"
    }

    /// Map step: a digest of one part of a long text (Python: _PART_PROMPT).
    public static func partPrompt(_ text: String, index: Int, count: Int) -> String {
        "This is part \(index) of \(count) of a longer text. Write a compact digest "
            + "of this part in plain sentences. Keep every main point, fact, number, "
            + "name and decision, and anything the reader is asked to do.\n\nTEXT:\n\(text)"
    }

    /// Reduce step: the style, applied to the parts' digests in order
    /// (Python: build_reduce_prompt).
    public static func reducePrompt(_ digests: [String], style: SummaryStyle) -> String {
        "\(stylePrompt(style))\n\n"
            + "The text below joins digests of consecutive parts of one longer text, "
            + "in order. Treat it as one text.\n\nTEXT:\n"
            + digests.joined(separator: "\n\n")
    }

    /// The part of the prompt that is the same for every text in a style,
    /// for `prewarm(promptPrefix:)`.
    public static func promptPrefix(_ style: SummaryStyle) -> String {
        "\(stylePrompt(style))\n\nTEXT:\n"
    }

    // MARK: - tidy (Python: tidy)

    /// Drop what a model adds despite the prompt: a "Here is…:" opener,
    /// list markers and bold marks. Everything else is left alone.
    public static func tidy(_ summary: String) -> String {
        var out = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        out = replace(preamble, in: out, with: "", firstOnly: true)
        out = replace(lineMarker, in: out, with: "")
        out = out.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Same patterns as summarize.py's _PREAMBLE and _LINE_MARKER.
    private static let preamble = regex(
        #"^\s*(?:(?:sure|certainly|okay|ok)\b[,!.]?\s*)?here(?:'s|’s| is| are)\b[^\n:]{0,100}:\s*"#,
        options: [.caseInsensitive])
    private static let lineMarker = regex(
        #"^[ \t]*(?:[#>*•\-–]+|\d+[.)])[ \t]+"#, options: [.anchorsMatchLines])

    private static func regex(_ pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func replace(
        _ regex: NSRegularExpression?, in text: String, with template: String, firstOnly: Bool = false
    ) -> String {
        guard let regex else { return text }
        let whole = NSRange(text.startIndex..., in: text)
        if firstOnly {
            guard let match = regex.firstMatch(in: text, range: whole),
                  let range = Range(match.range, in: text) else { return text }
            return text.replacingCharacters(in: range, with: template)
        }
        return regex.stringByReplacingMatches(in: text, range: whole, withTemplate: template)
    }
}
