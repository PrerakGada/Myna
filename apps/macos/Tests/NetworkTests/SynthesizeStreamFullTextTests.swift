// SynthesizeStreamFullTextTests.swift — the parser reads the whole chunk
// text (`X-Chunk-Text-Full`) that the sentence transcript is built from,
// and falls back to the 200-character preview for an older daemon; and the
// word times (`X-Chunk-Words`) the pill's live captions follow.
import XCTest

@testable import Myna

final class SynthesizeStreamFullTextTests: XCTestCase {
    private func encode(_ text: String) -> String {
        // The daemon uses urllib.parse.quote(text, safe=""): everything but
        // unreserved characters is escaped. alphanumerics plus "-._~" match.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        // swiftlint:disable:next force_unwrapping
        return text.addingPercentEncoding(withAllowedCharacters: allowed)!
    }

    private func part(index: Int, preview: String, full: String?, words: String? = nil) -> Data {
        var head = "--mynachunk\r\nContent-Type: audio/wav\r\n"
        head += "X-Chunk-Index: \(index)\r\nX-Chunk-Total-Estimate: 2\r\n"
        head += "X-Chunk-Text: \(encode(String(preview.prefix(200))))\r\n"
        if let full { head += "X-Chunk-Text-Full: \(encode(full))\r\n" }
        if let words { head += "X-Chunk-Timing: model\r\nX-Chunk-Words: \(words)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(Data("WAV\(index)\r\n".utf8))
        return data
    }

    private var trailer: Data {
        Data("--mynachunk\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}\r\n--mynachunk--\r\n".utf8)
    }

    private func chunks(from data: Data, feedingBytes step: Int) throws -> [SynthesizedChunk] {
        let parser = MultipartChunkParser()
        var out: [SynthesizedChunk] = []
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + step)
            parser.append(data.subdata(in: offset..<end))
            offset = end
            for case .audio(let chunk) in try parser.drain() { out.append(chunk) }
        }
        return out
    }

    func test_full_text_is_parsed_beyond_the_preview_cap() throws {
        let long = String(repeating: "Café au lait, s'il vous plaît. ", count: 20)
            + "Last line\nwith a newline and 100% — dashes."
        var body = part(index: 0, preview: "Opening words.", full: "Opening words.")
        body.append(part(index: 1, preview: long, full: long))
        body.append(trailer)

        // Byte-at-a-time and in larger slices: headers split mid-escape.
        for step in [1, 7, 4_096] {
            let parsed = try chunks(from: body, feedingBytes: step)
            XCTAssertEqual(parsed.count, 2, "step \(step)")
            XCTAssertEqual(parsed[1].fullText, long, "step \(step)")
            XCTAssertEqual(parsed[1].spokenText, long)
            XCTAssertEqual(parsed[1].textPreview, String(long.prefix(200)))
            XCTAssertGreaterThan(long.count, 200)
        }
    }

    func test_older_daemon_without_the_header_falls_back_to_the_preview() throws {
        var body = part(index: 0, preview: "Only a preview here.", full: nil)
        body.append(trailer)
        let parsed = try chunks(from: body, feedingBytes: 4_096)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertNil(parsed[0].fullText)
        XCTAssertEqual(parsed[0].spokenText, "Only a preview here.")
        XCTAssertEqual(parsed[0].words, [])
    }

    func test_word_times_ride_along_with_each_chunk() throws {
        let text = "Hotkey reads get word timings too."
        var body = part(
            index: 0, preview: text, full: text,
            words: "[[275,625,0,6],[625,975,7,12],[975,1125,13,16]]")
        body.append(trailer)
        for step in [1, 4_096] {
            let words = try chunks(from: body, feedingBytes: step)[0].words
            XCTAssertEqual(words.count, 3, "step \(step)")
            XCTAssertEqual(words[1].start, 0.625, accuracy: 0.0001)
            XCTAssertEqual((text as NSString).substring(with: words[1].range), "reads")
        }
    }
}
