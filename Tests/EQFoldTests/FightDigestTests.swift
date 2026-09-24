// The fight digest: what an older fight keeps once its event ring is dropped.
import XCTest
import EQCompanionCore
@testable import EQFold

final class FightDigestTests: XCTestCase {
    private func encounter() -> Encounter {
        let e = Encounter(id: "e1", zone: "Kedge Keep", ts: 1_000_000)
        e.lastTs = 1_000_000 + 60_000
        func ev(_ dt: Int64, _ kind: String, _ amount: Int64, target: String? = "a gloomwater mermaid",
                lane: String = "Melee", crit: Bool = false, outcome: String? = nil) -> TimelineRaw {
            TimelineRaw(ts: 1_000_000 + dt, lane: lane, category: "melee", amount: amount, crit: crit,
                        modifiers: [], kind: kind, outcome: outcome, target: target)
        }
        e.events = [
            ev(0, "you", 100), ev(500, "you", 300, crit: true), ev(1_500, "pet", 50),
            ev(2_000, "you", 0, outcome: "miss"), ev(2_500, "you", 0, lane: "Ice Comet", outcome: "resist"),
            ev(30_000, "you", 200, target: "A gloomwater mermaid"), ev(30_000, "enemy", 80, target: "You"),
            ev(59_000, "member", 40, target: "a piercer swordfish"),
        ]
        e.eventsTotal = 8
        return e
    }

    func testTheDigestKeepsTheCurveAndTheRowsTheDamagePanelsRead() {
        let d = FightDigest.build(encounter())
        XCTAssertEqual(d.bucketMs, 1_000, "a one-minute fight buckets per second")
        XCTAssertEqual(d.curve[0], [400, 0, 0, 0], "you: 100 + 300 in the first second")
        XCTAssertEqual(d.curve[1], [0, 50, 0, 0], "pet")
        XCTAssertEqual(d.curve[30], [200, 0, 0, 80], "the incoming hit is on the curve")
        XCTAssertEqual(d.curve.last, [0, 0, 40, 0], "a group-mate's damage; trailing empties trimmed")
        let melee = d.rows.first { $0.lane == "Melee" && $0.target.lowercased() == "a gloomwater mermaid" }
        XCTAssertEqual(melee?.total, 650, "case-folded target, and the pet's melee with yours, as the panel groups: 100 + 300 + 50 + 200")
        XCTAssertEqual(melee?.hits, 4)
        XCTAssertEqual(melee?.crits, 1)
        XCTAssertEqual(melee?.misses, 1)
        XCTAssertEqual(melee?.maxHit, 300)
        XCTAssertEqual(melee?.minHit, 50)
        XCTAssertEqual(d.rows.first { $0.lane == "Ice Comet" }?.resists, 1)
        XCTAssertFalse(d.rows.contains { $0.target == "You" }, "incoming damage is not a damage-by-mob row")
        XCTAssertFalse(d.truncated)
    }

    func testALongFightIsCappedAtTheBucketCount() {
        let e = encounter()
        e.lastTs = e.startTs + 3_600_000
        let d = FightDigest.build(e)
        XCTAssertGreaterThanOrEqual(d.bucketMs, 30_000)
        XCTAssertLessThanOrEqual(d.curve.count, FightDigest.maxBuckets + 1)
    }

    func testATruncatedRingSaysSo() {
        let e = encounter()
        e.eventsTotal = 50
        XCTAssertTrue(FightDigest.build(e).truncated)
    }

    func testTheDigestRidesTheEncounterCheckpoint() {
        let e = encounter()
        e.digest = FightDigest.build(e)
        e.events.removeAll()
        let back = Encounter.fromCheckpoint(e.checkpointState())
        XCTAssertEqual(back?.digest, e.digest)
        let plain = encounter()
        XCTAssertNil(Encounter.fromCheckpoint(plain.checkpointState())?.digest, "no digest, no key, nil back")
    }
}
