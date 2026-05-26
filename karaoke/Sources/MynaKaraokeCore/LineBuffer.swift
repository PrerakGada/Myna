// LineBuffer.swift — accumulates socket reads, emits whole NDJSON lines.
//
// Socket reads return arbitrary byte chunks. NDJSON is one JSON object per
// line, terminated by '\n'. We buffer partial lines, emit completed ones.
//
// Codable JSON never embeds bare newlines (escapes them), so '\n' is a
// safe delimiter.

import Foundation

public final class LineBuffer {
    private var buffer = Data()
    /// Cap on a single line. Anything longer is dropped (defensive — prevents
    /// memory exhaustion if the peer goes haywire). 1 MiB is ~25k words.
    public let maxLineBytes: Int

    public init(maxLineBytes: Int = 1 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// Append a chunk and emit any complete lines.
    /// Returned lines do NOT include the trailing '\n'.
    public func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        while let newlineIdx = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineIdx)
            lines.append(line)
            // +1 to skip the newline itself
            buffer.removeSubrange(buffer.startIndex...newlineIdx)
        }
        // Drop overlong partial lines defensively.
        if buffer.count > maxLineBytes {
            buffer.removeAll(keepingCapacity: false)
        }
        return lines
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    public var pendingBytes: Int { buffer.count }
}
