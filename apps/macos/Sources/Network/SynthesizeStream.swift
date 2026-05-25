// SynthesizeStream.swift — incremental parser for the `multipart/mixed;
// boundary=mynachunk` response stream returned by POST /v2/synthesize.
//
// The parser is *stateful*. Callers feed in byte chunks of arbitrary size
// (possibly splitting headers, boundaries, or even the boundary marker
// itself in two) and pull out fully-assembled parts. The final part is a
// JSON sentinel describing total chunk count.
//
// Wire format (per docs/native-app/API_CONTRACT.md § 2):
//
//   --mynachunk\r\n
//   Content-Type: audio/wav\r\n
//   X-Chunk-Index: 0\r\n
//   X-Chunk-Total-Estimate: 8\r\n
//   X-Chunk-Text: First 200 chars...\r\n
//   \r\n
//   <WAV bytes>\r\n
//   --mynachunk\r\n
//   ...
//   --mynachunk--\r\n
import Foundation

/// One parsed multipart section. Either an audio chunk or the trailing JSON.
public enum MultipartPart: Sendable, Equatable {
    case audio(chunk: SynthesizedChunk)
    case trailer(json: Data)
}

/// Incremental parser. Not thread-safe — use one per response stream.
public final class MultipartChunkParser {
    /// The boundary as it appears on the wire (with the leading "--").
    private let boundaryLine: Data
    /// The closing boundary "--mynachunk--".
    private let closingBoundary: Data
    /// CRLF.
    private static let crlf = Data([0x0D, 0x0A])
    /// Double CRLF — separates headers from body within a part.
    private static let doubleCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])

    /// Buffer of bytes seen so far that haven't yet been consumed.
    private var buffer = Data()
    /// True once we've seen the closing boundary.
    private var finished = false

    public init(boundary: String = "mynachunk") {
        let prefix = "--\(boundary)"
        self.boundaryLine = Data(prefix.utf8)
        self.closingBoundary = Data((prefix + "--").utf8)
    }

    /// Append more bytes from the network.
    public func append(_ data: Data) {
        buffer.append(data)
    }

    /// Drain as many complete parts as the buffer contains right now.
    /// Returns parts in wire order. Caller keeps calling until the
    /// `trailer` sentinel arrives or the stream ends.
    public func drain() throws -> [MultipartPart] {
        var out: [MultipartPart] = []
        while let part = try takeNextPart() {
            out.append(part)
            if case .trailer = part {
                finished = true
                break
            }
        }
        return out
    }

    public var isFinished: Bool { finished }

    /// Pop one part from the buffer if a complete one is present.
    /// Returns nil if more bytes are needed.
    private func takeNextPart() throws -> MultipartPart? {
        // Find the first boundary in the buffer.
        guard let boundaryStart = range(of: boundaryLine, in: buffer) else {
            return nil
        }

        // Closing boundary present? Then this is end-of-stream.
        // Closing is "--mynachunk--"; we already matched "--mynachunk".
        // Peek at the next two bytes to see if they're "--".
        let afterBoundary = boundaryStart.upperBound
        let hasClosingDash =
            afterBoundary + 1 < buffer.count
            && buffer[afterBoundary] == 0x2D  // '-'
            && buffer[afterBoundary + 1] == 0x2D
        if hasClosingDash {
            // Drop everything up to and including the closing boundary.
            // Returning nil here signals end-of-stream cleanly (trailer
            // part is emitted before we get here, so this is the truly
            // final boundary).
            buffer.removeAll(keepingCapacity: false)
            finished = true
            return nil
        }

        // We're at "--mynachunk" of part N. Need a CRLF after the
        // boundary (or "\r\n" then headers + CRLFCRLF + body).
        // Skip past boundary + optional CRLF.
        var headerStart = afterBoundary
        let hasCRLFAfterBoundary =
            headerStart + 1 < buffer.count
            && buffer[headerStart] == 0x0D
            && buffer[headerStart + 1] == 0x0A
        if hasCRLFAfterBoundary {
            headerStart += 2
        }

        // Find end of headers (\r\n\r\n).
        guard let headerEnd = range(of: Self.doubleCRLF, in: buffer, from: headerStart) else {
            // Don't have a complete header block yet.
            return nil
        }

        let bodyStart = headerEnd.upperBound

        // Find the NEXT boundary — that bounds this part's body.
        guard let nextBoundary = range(of: boundaryLine, in: buffer, from: bodyStart) else {
            // Body not complete yet (no following boundary in buffer).
            return nil
        }

        // The body runs from bodyStart up to (but not including) the CRLF
        // that precedes the next boundary. The wire format puts a CRLF
        // immediately before "--boundary".
        var bodyEnd = nextBoundary.lowerBound
        let hasCRLFBeforeBoundary =
            bodyEnd >= 2
            && buffer[bodyEnd - 2] == 0x0D
            && buffer[bodyEnd - 1] == 0x0A
        if hasCRLFBeforeBoundary {
            bodyEnd -= 2
        }

        let headerData = buffer.subdata(in: headerStart..<headerEnd.lowerBound)
        let bodyData = buffer.subdata(in: bodyStart..<bodyEnd)

        // Drop everything up to (but not including) the next boundary.
        buffer.removeSubrange(0..<nextBoundary.lowerBound)

        let headers = parseHeaders(headerData)
        let part = try buildPart(headers: headers, body: bodyData)
        return part
    }

    private func buildPart(headers: [String: String], body: Data) throws -> MultipartPart {
        let contentType = headers["content-type"] ?? ""
        if contentType.hasPrefix("application/json") {
            return .trailer(json: body)
        }
        guard contentType.hasPrefix("audio/wav") else {
            throw DaemonError.decode(
                "multipart part missing audio/wav or application/json content-type; got '\(contentType)'")
        }
        let index = Int(headers["x-chunk-index"] ?? "") ?? 0
        let estimate = Int(headers["x-chunk-total-estimate"] ?? "") ?? 0
        let preview = (headers["x-chunk-text"] ?? "").removingPercentEncoding ?? headers["x-chunk-text"] ?? ""
        return .audio(
            chunk: SynthesizedChunk(
                index: index,
                totalEstimate: estimate,
                textPreview: preview,
                wavData: body
            )
        )
    }

    private func parseHeaders(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)..<line.endIndex]
                .trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out
    }

    /// Find first occurrence of needle in haystack starting at `from`.
    private func range(of needle: Data, in haystack: Data, from start: Int = 0) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= start + needle.count else { return nil }
        let end = haystack.count - needle.count
        if end < start { return nil }
        // swiftlint:disable:next force_unwrapping
        let first = needle.first!
        var index = start
        while index <= end {
            if haystack[index] == first {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched {
                    return index..<(index + needle.count)
                }
            }
            index += 1
        }
        return nil
    }
}
