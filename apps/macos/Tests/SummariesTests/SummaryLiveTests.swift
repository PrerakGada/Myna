// SummaryLiveTests.swift — real summaries from Apple's on-device model,
// in every style, with timings. Skipped unless asked for:
//
//   TEST_RUNNER_MYNA_SUMMARY_LIVE=1 just test-swift-only SummaryLiveTests
//
// Needs Apple Intelligence turned on. Prints each summary and its timings
// ("LIVE-SUMMARY" lines) for a person to read; it asserts only that each
// style produced listenable text.
import XCTest

@testable import Myna

final class SummaryLiveTests: XCTestCase {

    private func requireLive() throws -> AppleFoundationModel {
        guard ProcessInfo.processInfo.environment["MYNA_SUMMARY_LIVE"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_MYNA_SUMMARY_LIVE=1 to run Apple's on-device model")
        }
        let model = AppleFoundationModel()
        guard model.status.isReady else {
            throw XCTSkip("Apple's on-device model isn't ready here: \(model.status.statusLine)")
        }
        return model
    }

    func test_live_every_style_on_a_600_word_article() async throws {
        let model = try requireLive()
        print("LIVE-SUMMARY article: \(ReadEvent.wordCount(of: Self.article)) words, "
            + "\(Self.article.count) characters; context \(model.contextTokens) tokens")

        // Cold: nothing prewarmed.
        let cold = try await MapReduceSummarizer(model: model).summarize(Self.article, style: .tldr)
        print("LIVE-SUMMARY [tldr, cold] \(SummaryService.describe(cold.timing))\n\(cold.text)\n")

        for style in SummaryStyle.allCases {
            // What the summary key does: prewarm on the press, then summarize.
            model.prewarm(instructions: SummaryPrompts.instructions, promptPrefix: SummaryPrompts.promptPrefix(style))
            try await Task.sleep(nanoseconds: 300_000_000)  // roughly the selection capture
            let output = try await MapReduceSummarizer(model: model).summarize(Self.article, style: style)
            print("LIVE-SUMMARY [\(style.rawValue), prewarmed] \(SummaryService.describe(output.timing))\n\(output.text)\n")
            XCTAssertFalse(output.text.isEmpty, style.rawValue)
            XCTAssertFalse(output.text.contains("**"), style.rawValue)
            XCTAssertFalse(output.text.lowercased().hasPrefix("here is"), style.rawValue)
        }
    }

    func test_live_long_text_goes_through_map_reduce() async throws {
        let model = try requireLive()
        // Five different framings of the article make ~3,300 words, past one
        // window on macOS 26 (4,096 tokens) and past one 16,000-character part.
        let long = (1...5).map { "Report \($0) of 5.\n\n" + Self.article }.joined(separator: "\n\n")
        let output = try await MapReduceSummarizer(model: model).summarize(long, style: .keyPoints)
        print("LIVE-SUMMARY [key_points, \(ReadEvent.wordCount(of: long)) words] "
            + "\(SummaryService.describe(output.timing))\n\(output.text)\n")
        XCTAssertGreaterThan(output.timing.calls, 1)
        XCTAssertFalse(output.text.isEmpty)
    }

    /// About 600 words of local news: a decision, numbers, dates, a
    /// disagreement and things residents are asked to do.
    static let article = """
        Riverside Council approved its street-lighting plan on Tuesday night after almost two hours of \
        debate, ending a consultation that began last spring. Over the next eighteen months, all 4,200 of \
        the town's sodium street lamps will be replaced with LED fittings. The council expects the change to \
        cut the lighting bill by about sixty percent, saving roughly £310,000 a year once the work is \
        finished, and to reduce the network's carbon emissions by around 700 tonnes a year.

        The work will happen in three phases. The first, starting on 3 March, covers the town centre and the \
        four main roads into it. The second, from July, moves through the residential streets north of the \
        river. The third, planned for early next year, covers the southern estates and the industrial park. \
        Each street should take no more than two days, and crews will work between 8 in the morning and 6 in \
        the evening. Short stretches of pavement will be closed while columns are replaced, and some parking \
        bays will be suspended for a day at a time. Residents on affected streets will receive a letter at \
        least ten days before work begins.

        Not everyone was persuaded. Several residents who spoke at the meeting said the white light from LED \
        lamps can feel harsh and makes it harder to sleep when a lamp sits directly outside a bedroom window. \
        Councillor Mei Tanaka, who chairs the environment committee, said the new fittings use a warmer colour \
        temperature of 3,000 kelvin rather than the bluer lamps some towns installed a decade ago, and that \
        each lamp can be fitted with a shield to stop light spilling into homes. Anyone who wants a shield \
        should request one through the council website or by calling the highways team before their street's \
        phase begins; shields fitted later will cost the council more and may take several months.

        The plan also introduces part-night dimming. Between midnight and 5 in the morning, lamps on \
        residential streets will run at half brightness. Main roads, pedestrian crossings, the train station \
        and the hospital approach will stay at full brightness all night. Councillor Tanaka said the police \
        had been consulted and did not object, but the council will review crime and road-safety figures \
        after twelve months and has committed to restoring full brightness on any street where there is \
        evidence of harm.

        Funding comes from two sources. A government efficiency grant covers £1.1 million of the £2.9 million \
        cost, and the rest will be borrowed and repaid from the energy savings over about six years. \
        Councillor Paul Okafor, the finance lead, warned that the savings depend on electricity prices and \
        that the repayment period could stretch to eight years if prices fall sharply.

        For wildlife, the council has agreed to leave a stretch of the riverside path unlit between the \
        footbridge and the old mill, where a survey found several bat roosts. Cyclists who use that path after \
        dark are advised to carry lights.

        The council is also asking residents to report faulty lamps during the changeover, since old and new \
        systems will run side by side for months and some faults may be missed. Reports can be made online, \
        through the council app, or by phone, and the council aims to fix any reported fault within five \
        working days. A public drop-in session, where residents can see the new lamps and the shields, will be \
        held at the library on 18 February from 4 to 7 in the evening.
        """
}
