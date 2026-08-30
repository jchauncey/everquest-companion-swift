// NDJSON framing: one JSON document per line, LF-terminated. The engine's transport
// (`protocol::transport::ndjson`) and nothing else in this package knows what a newline means.
import Foundation

/// Accumulates bytes off a socket and hands back complete lines. A trailing partial line is held
/// undecoded until its newline arrives, so a read boundary inside a multi-byte character never
/// yields a broken document.
public struct LineFramer: Sendable {
    private var buffer = Data()

    public init() {}

    /// Append a chunk and return every complete line it finishes, in order, without the newline
    /// (and without a trailing CR, should one ever appear).
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if end > start { lines.append(buffer[start..<end]) }
            start = nl + 1
        }
        if start > buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        return lines
    }

    /// Bytes held back as an unfinished line.
    public var pendingBytes: Int { buffer.count }
}

public enum NDJSON {
    /// Encode one message as the bytes that go on the wire: the document and its LF.
    public static func frame(_ value: JSONValue) -> Data {
        var d = value.serialized()
        d.append(0x0A)
        return d
    }
}
