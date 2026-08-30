import XCTest
import EQLog

/// The parser oracle: every fixture's NDJSON stream, byte for byte, against the Rust engine's.
/// Skips when `Goldens/` has not been generated (scripts/gen-goldens.sh).
final class GoldenEventsTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")
    static let fixtures = repo.appendingPathComponent("Resources/fixtures")

    func testTimestampsResolveLikeV8() {
        let la = Clock(identifier: "America/Los_Angeles")!
        XCTAssertEqual(la.parseEQTimestamp("Wed Aug 19 16:21:47 2026"), 1787181707000)
        XCTAssertEqual(la.parseEQTimestamp("Sun Mar 08 02:30:00 2026"), 1772965800000, "the skipped hour reads at PST")
        XCTAssertEqual(la.parseEQTimestamp("Sun Nov 01 01:30:00 2026"), 1793521800000, "the repeated hour reads at PDT")
        XCTAssertEqual(la.parseEQTimestamp("not a timestamp"), 0)
        XCTAssertEqual(la.parseEQTimestamp("Sat Zzz 01 13:00:28 2026"), 0)
        let c = la.civil(1787181707000)!
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 8, 19, 16, 21, 47])
        XCTAssertEqual(Clock(identifier: "UTC")!.civil(1787181707000)!.hour, 23)
    }

    func testJSONStringAndNumberSpelling() {
        XCTAssertEqual(JS.jsonString("a\"b\\c\u{1}\ttab/é"), "\"a\\\"b\\\\c\\u0001\\ttab/é\"")
        var s = ""; JS.writeNumber(&s, 3.0); XCTAssertEqual(s, "3")
        s = ""; JS.writeNumber(&s, 3.288); XCTAssertEqual(s, "3.288")
        XCTAssertEqual(JS.trim("\u{FEFF} x \u{85}"), "x \u{85}")
    }

    func testUnknownLineIsTheUnknownEnvelope() {
        let p = Parser(clock: Clock(identifier: "America/Los_Angeles")!, db: nil, character: "Primitive")
        let ev = Ev()
        XCTAssertTrue(p.parseEvent("[Wed Aug 19 16:21:47 2026] You are not currently assigned to an adventure.", seq: 0, into: ev))
        XCTAssertEqual(ev.finish(), #"{"kind":"unknown","seq":0,"ts":1787181707000,"raw":"[Wed Aug 19 16:21:47 2026] You are not currently assigned to an adventure."}"#)
        XCTAssertFalse(p.parseEvent("no bracket here", seq: 0, into: ev))
        XCTAssertFalse(p.parseEvent("[Sun Aug 16 20:09:40 2026] Velkator tells general2:1, 'rebaseline\rCount items from\r/outputfile inventory'", seq: 0, into: ev),
                       "a bare CR inside the message is no event at all")
    }

    /// Every fixture, byte for byte. Reports the per-kind mismatch table on failure.
    func testEveryFixtureIsByteIdentical() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.goldens.path) else { throw XCTSkip("no Goldens/ — run scripts/gen-goldens.sh") }
        let names = try fm.contentsOfDirectory(atPath: Self.goldens.path).filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }.sorted()
        var failures: [String] = []
        var kindTotals: [String: (Int, Int)] = [:]
        for n in names {
            let log = Self.fixtures.appendingPathComponent(n + ".log")
            guard let data = try? Data(contentsOf: log),
                  let gold = try? String(contentsOf: Self.goldens.appendingPathComponent(n).appendingPathComponent("events.ndjson"), encoding: .utf8) else { continue }
            let goldLines = gold.split(separator: "\n").map(String.init)
            let parser = Parser(clock: Clock(identifier: "America/Los_Angeles")!, db: SpellDb.shared(), character: "Primitive")
            var ours: [String] = []
            Scan.bytes(parser, data) { json, _ in ours.append(json) }
            var bad = 0
            for i in 0..<max(goldLines.count, ours.count) {
                let g = i < goldLines.count ? goldLines[i] : "", o = i < ours.count ? ours[i] : ""
                let k = g.isEmpty ? "?" : String(g.dropFirst(9).prefix { $0 != "\"" })
                var e = kindTotals[k] ?? (0, 0); e.0 += 1
                if g == o { e.1 += 1 } else if bad == 0 { bad += 1; failures.append("\(n) line \(i): \(g.prefix(160)) | \(o.prefix(160))") } else { bad += 1 }
                kindTotals[k] = e
            }
        }
        let table = kindTotals.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.1)/\($0.value.0)" }.joined(separator: ", ")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) fixtures diverge. Per kind: \(table)\nFirst diffs:\n" + failures.prefix(10).joined(separator: "\n"))
    }
}
