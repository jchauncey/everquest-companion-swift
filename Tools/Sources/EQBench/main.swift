// eqbench — parse one log and report the parser's own speed. `eqbench <log> [--tz Zone] [--profile]`
import Foundation
import EQLog
import EQEngine

let args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else { print("usage: eqbench <log> [--tz Zone] [--golden path] [--fold]"); exit(2) }
let tz = args.firstIndex(of: "--tz").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil } ?? "America/New_York"
let data = try! Data(contentsOf: URL(fileURLWithPath: path))
let name = URL(fileURLWithPath: path).lastPathComponent
let character = Parser.characterOf(name) ?? "Zoddrick"
let t0 = Date()
let db = SpellDb.shared()
let tDb = Date()
let parser = Parser(clock: Clock(identifier: tz)!, db: db, character: character)
var n: Int64 = 0
var bytes = 0
let goldenPath = args.firstIndex(of: "--golden").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
var golden: [Substring] = []
if let g = goldenPath { golden = (try! String(contentsOfFile: g, encoding: .utf8)).split(separator: "\n", omittingEmptySubsequences: true) }
var mismatches = 0
var firstDiff: (Int, String, String)? = nil
let t1 = Date()
n = Scan.bytes(parser, data) { json, _ in
    bytes += json.utf8.count
    if goldenPath != nil {
        let i = bytes == 0 ? 0 : Int(n)
        _ = i
    }
}
if let g = goldenPath {
    var i = 0
    Scan.bytes(parser, data) { json, _ in
        if i < golden.count, golden[i] != json { mismatches += 1; if firstDiff == nil { firstDiff = (i, String(golden[i]), json) } }
        else if i >= golden.count { mismatches += 1; if firstDiff == nil { firstDiff = (i, "<beyond golden>", json) } }
        i += 1
    }
    print("golden \(g): \(golden.count) lines, ours \(i), mismatches \(mismatches)" + (firstDiff.map { "\n  first at \($0.0):\n  G: \($0.1.prefix(200))\n  O: \($0.2.prefix(200))" } ?? ""))
}
let t2 = Date()
let mb = Double(data.count) / 1_000_000
print(String(format: "spell db %.0f ms · %lld events · %.1f MB in %.0f ms = %.2f MB/s · %d B of JSON", tDb.timeIntervalSince(t0) * 1000, n, mb, t2.timeIntervalSince(t1) * 1000, mb / t2.timeIntervalSince(t1), bytes))

// `--fold`: the same bytes through the parser AND the whole fold (every module + combat), the way
// an attach's historical scan runs it — the number plan §2 is about. No state dir, so nothing
// persisted is read or written.
if args.contains("--fold") {
    let foldParser = Parser(clock: Clock(identifier: tz)!, db: db, character: character)
    let sink = FoldSink(SinkInputs(log: URL(fileURLWithPath: path), character: character, db: db,
                                   clock: foldParser.clock, attachedAtMs: 0, stateDir: nil))
    let f0 = Date()
    var seq: Int64 = 0
    Scan.bytes(foldParser, data, json: false) { json, payload in
        sink.event(IngestEvent(json: json, payload: payload, seq: seq, live: false))
        seq += 1
    }
    let f1 = Date()
    print(String(format: "fold: %lld events in %.0f ms (parse + fold) = %.2f MB/s",
                 seq, f1.timeIntervalSince(f0) * 1000, mb / f1.timeIntervalSince(f0)))
}
