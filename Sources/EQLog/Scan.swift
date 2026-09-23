// The byte-accurate line splitter and the seq discipline (eqlog/src/scan.rs): split on `\n`, strip
// a trailing `\r` as a byte, decode each line once (lossily), drop empty lines, and let a line with
// no timestamp take no seq. A trailing partial line is not folded.
import Foundation

public enum Scan {
    /// Fold a complete file, calling `emit` with each event's JSON and payload. Returns the count.
    /// `json: false` hands `emit` an empty line and builds the payload alone.
    @discardableResult
    public static func bytes(_ parser: Parser, _ data: Data, json: Bool = true,
                             _ emit: (String, Payload) -> Void) -> Int64 {
        var seq: Int64 = 0
        let ev = Ev(json: json)
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let base = buf.bindMemory(to: UInt8.self)
            var start = 0
            let n = base.count
            while start < n {
                guard let nlOff = memchr(base.baseAddress! + start, 0x0A, n - start) else { break }
                let nl = UnsafePointer<UInt8>(nlOff.assumingMemoryBound(to: UInt8.self)) - base.baseAddress!
                var end = nl
                if end > start, base[end - 1] == 0x0D { end -= 1 }
                if end > start {
                    let line = String(decoding: UnsafeBufferPointer(start: base.baseAddress! + start, count: end - start), as: UTF8.self)
                    if parser.parseEvent(line, seq: seq, into: ev) {
                        seq += 1
                        emit(ev.finish(), ev.payload)
                    }
                }
                start = nl + 1
            }
        }
        return seq
    }
}
