// A window of the log file itself: the lines written between two instants, read back from disk.
// NOT A PORT: the engine keeps its classification ring only while it follows the game live, so a
// fight from before this launch has no combat log in memory. The file still has every line, so the
// Combat tab asks for the fight's own window (`log.window`) and draws that.
//
// The log is chronological, so the window's start is found by binary search on the timestamps at
// byte offsets (a few dozen small reads on a 100 MB log), then read forward to the window's end.
// Each line is parsed with the engine's own parser and kept when it is a fight line — anything the
// parser recognises; `unknown` (chat, flavour) is left out.
import Foundation
import EQCompanionCore
import EQLog

enum LogWindow {
    /// Read the fight lines stamped within [from, to] (epoch ms), at most `limit` of them.
    static func read(log: URL, from: Int64, to: Int64, limit: Int, clock: Clock,
                     character: String?) -> (lines: [JSONValue], truncated: Bool)? {
        guard let fh = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return ([], false) }

        /// The first timestamped line at or after `offset`: its start and its ts.
        func stamp(at offset: UInt64) -> (start: UInt64, ts: Int64)? {
            var pos = offset
            try? fh.seek(toOffset: pos)
            guard var chunk = try? fh.read(upToCount: 8192), !chunk.isEmpty else { return nil }
            if offset > 0 {
                guard let nl = chunk.firstIndex(of: 0x0A) else { return nil }
                pos += UInt64(nl - chunk.startIndex + 1)
                chunk = chunk[(nl + 1)...]
            }
            var lineStart = pos
            for line in chunk.split(separator: 0x0A, omittingEmptySubsequences: false) {
                let ts = stampOf(Data(line))
                if ts > 0 { return (lineStart, ts) }
                lineStart += UInt64(line.count + 1)
            }
            return nil
        }
        func stampOf(_ line: Data) -> Int64 {
            guard line.first == UInt8(ascii: "["), let close = line.firstIndex(of: UInt8(ascii: "]")) else { return 0 }
            return clock.parseEQTimestamp(String(decoding: line[(line.startIndex + 1)..<close], as: UTF8.self))
        }

        // The last line start whose stamp is before `from`, by bisection over byte offsets.
        var lo: UInt64 = 0, hi = size
        while hi - lo > 8192 {
            let mid = lo + (hi - lo) / 2
            if let s = stamp(at: mid), s.ts < from { lo = mid } else { hi = mid }
        }

        let parser = Parser(clock: clock, db: SpellDb.shared(), character: character)
        let ev = Ev(json: false)
        var out: [JSONValue] = []
        var truncated = false
        try? fh.seek(toOffset: lo)
        var carry = Data()
        var first = lo > 0
        reading: while let chunk = try? fh.read(upToCount: 1 << 16), !chunk.isEmpty {
            carry.append(chunk)
            while let nl = carry.firstIndex(of: 0x0A) {
                let raw = carry[carry.startIndex..<nl]
                carry = Data(carry[(nl + 1)...])
                if first { first = false; continue }  // began mid-line
                var bytes = Data(raw)
                if bytes.last == 0x0D { bytes.removeLast() }
                let ts = stampOf(bytes)
                if ts == 0 || ts < from { continue }
                if ts > to { break reading }
                let line = String(decoding: bytes, as: UTF8.self)
                guard parser.parseEvent(line, seq: 0, into: ev), ev.payload.kind != .unknown else { continue }
                if out.count >= limit { truncated = true; break reading }
                out.append(entry(line, ts: ts, payload: ev.payload))
            }
        }
        return (out, truncated)
    }

    /// One line in the shape the combat log card reads (`ts`, `cat`, `role`, `text`).
    private static func entry(_ line: String, ts: Int64, payload: Payload) -> JSONValue {
        let text = line.firstIndex(of: "]").map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? line
        let attacker = payload.str(.attacker).map(Names.idKey)
        let target = payload.str(.target).map(Names.idKey)
        let role: String
        if attacker == "you" || text.hasPrefix("You ") { role = "you" }
        else if target == "you" { role = "enemy" }
        else { role = "info" }
        return ["ts": .int(ts), "cat": .string(payload.kind.rawValue), "role": .string(role), "text": .string(text)]
    }
}
