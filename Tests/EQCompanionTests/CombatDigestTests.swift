import XCTest
import EQCompanionCore
@testable import EQCompanion

/// An older fight read through its engine digest: the curve, damage by mob, the drill, and which
/// procs are worth a card.
final class CombatDigestTests: XCTestCase {
    private let digest: JSONValue = [
        "bucketMs": 1000,
        "curve": [[400, 0, 0, 0], [0, 50, 0, 0], [200, 0, 40, 80]],
        "rows": [
            ["target": "a gloomwater mermaid", "category": "melee", "lane": "Melee", "total": 650, "hits": 4,
             "crits": 1, "misses": 1, "resists": 0, "maxHit": 300, "minHit": 50],
            ["target": "A gloomwater mermaid", "category": "spell", "lane": "Ice Comet", "total": 0, "hits": 0,
             "crits": 0, "misses": 0, "resists": 1, "maxHit": 0, "minHit": 0],
            ["target": "a piercer swordfish", "category": "melee", "lane": "Melee", "total": 40, "hits": 1,
             "crits": 0, "misses": 0, "resists": 0, "maxHit": 40, "minHit": 40],
        ],
        "truncated": false,
    ]

    func testTheCurveBecomesTimelineEventsBySide() throws {
        let tl = try XCTUnwrap(digestTimeline(digest, durationSec: 3))
        let events = tl["events"].array ?? []
        XCTAssertEqual(events.count, 5, "one per side per bucket that had damage")
        XCTAssertEqual(events.first?["kind"].string, "you")
        XCTAssertEqual(events.first?["t"].int64, 500, "at the bucket's middle")
        XCTAssertEqual(events.map { $0["kind"].string ?? "" }, ["you", "pet", "you", "member", "enemy"])
        let series = buildDpsSeries(tl)
        XCTAssertFalse(series.you.isEmpty, "the DPS card draws from it")
        XCTAssertGreaterThan(series.you.max() ?? 0, 0)
        XCTAssertGreaterThan(series.pet.max() ?? 0, 0)
        XCTAssertGreaterThan(series.group.max() ?? 0, 0)
        XCTAssertNil(digestTimeline(.null, durationSec: 3), "no digest, no timeline")
    }

    func testDamageByMobComesFromTheRowsNotTheCurve() throws {
        let tl = try XCTUnwrap(digestTimeline(digest, durationSec: 3))
        let mobs = groupByTarget(tl)
        XCTAssertEqual(mobs.rows.map(\.target), ["a gloomwater mermaid", "a piercer swordfish"],
                       "targets case-fold into one row; the curve adds no 'unknown' row")
        XCTAssertEqual(mobs.rows.first?.total, 650)
        XCTAssertEqual(mobs.rows.first?.hits, 4)
        XCTAssertEqual(mobs.rows.first?.resists, 1)
        XCTAssertEqual(mobs.total, 690)
    }

    func testTheDrillListsThatTargetsLanes() throws {
        let tl = try XCTUnwrap(digestTimeline(digest, durationSec: 3))
        let d = skillsForTarget(tl, target: "A GLOOMWATER MERMAID")
        XCTAssertEqual(Set(d.rows.map(\.name)), ["Melee", "Ice Comet"])
        XCTAssertEqual(d.total, 650)
        XCTAssertEqual(d.resists, 1)
    }

    func testPoisonDamageIsAProcOnlyWithACoatOnRecord() {
        let caster: JSONValue = ["poisonDamage": [["name": "Envenomed Bolt", "total": 164, "count": 3]],
                                 "coats": [], "combatAtEngage": [], "strikes": []]
        XCTAssertFalse(procsShowPoison(caster))
        XCTAssertFalse(procsHaveContent(caster), "a caster's poison spell is not a proc")
        let rogue: JSONValue = ["poisonDamage": [["name": "Spider Venom", "total": 90, "count": 4]],
                                "coats": [["poison": "Spider Venom", "tMs": 0]], "combatAtEngage": [], "strikes": []]
        XCTAssertTrue(procsShowPoison(rogue))
        XCTAssertTrue(procsHaveContent(rogue))
    }
}
