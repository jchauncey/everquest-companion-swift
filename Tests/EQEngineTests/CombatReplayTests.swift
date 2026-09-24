// A finished fight's timeline rebuilt from the log: it must be the fight the full fold built.
import XCTest
import EQCompanionCore
import EQLog
@testable import EQEngine

final class CombatReplayTests: XCTestCase {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/fixtures")

    func testAReplayedFightIsTheFightTheFullFoldBuilt() throws {
        let clock = Clock(identifier: "America/Los_Angeles")!
        var checked = 0
        for name in ["e2e-combat", "jos437-finishing-blow", "w59-proc-cast-split", "p4-pet-buff-kill-credit", "w44-foreign-charm-player-hostile"] {
            let log = Self.fixtures.appendingPathComponent("\(name).log")
            guard let data = try? Data(contentsOf: log) else { continue }
            let parser = Parser(clock: clock, db: SpellDb.shared(), character: "Primitive")
            let sink = FoldSink(SinkInputs(log: log, character: "Primitive", db: SpellDb.shared(), clock: clock,
                                           attachedAtMs: 0, stateDir: nil))
            var seq: Int64 = 0
            Scan.bytes(parser, data, json: false) { _, p in
                sink.event(IngestEvent(json: "", payload: p, seq: seq, live: false)); seq += 1
            }
            let fights = (sink.combatSnapshot(CombatOpts(maxSegments: 1_000_000))?.state["segments"].array ?? [])
                .filter { $0["kind"].string == "fight" }
            for s in fights.prefix(3) {
                guard let id = s["id"].string, let start = s["startTs"].int64 else { continue }
                let orig = sink.combatSnapshot(CombatOpts(selectedId: id, maxSegments: 1, timeline: true))!.state["timeline"]
                guard !orig.isNull else { continue }
                let end = start + Int64((s["durationSec"].double ?? 0) * 1000)
                let re = try XCTUnwrap(CombatReplay.timeline(log: log, startTs: start, endTs: end, clock: clock,
                                                             character: "Primitive"), "\(name) \(id)")
                func lanes(_ t: JSONValue) -> [String] {
                    (t["lanes"].array ?? []).map { "\($0["lane"].string ?? ""):\($0["total"].int64 ?? 0)" }.sorted()
                }
                XCTAssertEqual(lanes(re), lanes(orig), "\(name) \(s["name"].string ?? id)")
                XCTAssertEqual(re["events"].array?.count, orig["events"].array?.count, "\(name) \(s["name"].string ?? id)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "no fixture fight was replayed")
    }

    func testATimeWithNoFightReplaysToNothing() throws {
        let log = Self.fixtures.appendingPathComponent("w1-current-session.log")
        let clock = Clock(identifier: "America/Los_Angeles")!
        XCTAssertNil(CombatReplay.timeline(log: log, startTs: 1_000, endTs: 2_000, clock: clock, character: "Primitive"))
    }
}
