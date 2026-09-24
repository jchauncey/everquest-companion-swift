import XCTest
import EQCompanionCore
@testable import EQCompanion

/// Which mob of a fight earned which kill, experience line, drop and coin.
final class FightPayoutTests: XCTestCase {
    private let end: Int64 = 100_000

    private var raw: JSONValue {
        ["deaths": [["ts": 90_000, "name": "a gloom spider"], ["ts": 99_000, "name": "A gloom widow"],
                    ["ts": 300_000, "name": "a gloom spider"]],
         // The widow's experience is logged a line before its kill.
         "exp": [["ts": 90_000, "party": false, "pct": 1.25], ["ts": 99_000, "party": false, "pct": 2.0],
                 ["ts": 200_000, "party": false, "pct": 9.0]],
         "aa": [["ts": 99_000, "amount": 1]],
         "loot": [["ts": 110_000, "item": "Spider Silk", "count": 2, "source": "a gloom spider"],
                  ["ts": 111_000, "item": "Spider Silk", "count": 1, "source": "a gloom spider", "disposition": "sold"],
                  ["ts": 112_000, "item": "Widow Venom", "count": 1, "source": "A gloom widow"],
                  ["ts": 310_000, "item": "Spider Silk", "count": 5, "source": "a gloom spider"]],
         "coin": [["ts": 113_000, "copper": 500], ["ts": 310_000, "copper": 900]]]
    }

    func testEachMobOfAPullGetsItsOwnKillExperienceAndCorpse() {
        let spider = fightPayout(raw, mobs: ["A gloom spider"], fightEnd: end, coin: false)
        XCTAssertEqual(spider.kills, 1, "the same name killed minutes later is the next camp")
        XCTAssertEqual(spider.expPct, 1.25)
        XCTAssertEqual(spider.loot, [.init(item: "Spider Silk", count: 2, sold: false),
                                     .init(item: "Spider Silk", count: 1, sold: true)],
                       "the next camp's silk is not this corpse's")
        XCTAssertEqual(spider.copper, 0, "coin names no corpse, so a pull's mob gets none")

        let widow = fightPayout(raw, mobs: ["a gloom widow"], fightEnd: end, coin: false)
        XCTAssertEqual(widow.expPct, 2.0)
        XCTAssertEqual(widow.aa, 1)
        XCTAssertEqual(widow.loot.map(\.item), ["Widow Venom"])
    }

    func testAOneMobFightCountsTheCorpseCoinUntilTheNextKill() {
        let p = fightPayout(raw, mobs: ["a gloom widow"], fightEnd: end, coin: true)
        XCTAssertEqual(p.copper, 500)
    }

    func testNoKillNoPayout() {
        let p = fightPayout(raw, mobs: ["a gloom matriarch"], fightEnd: end, coin: true)
        XCTAssertEqual(p, FightPayout())
    }

    func testTheFightNameLosesItsLevelAndExtraMobs() {
        XCTAssertEqual(fightMobName("A revultant rat (3) +5"), "A revultant rat")
        XCTAssertEqual(fightMobName("an evil little imp"), "an evil little imp")
    }

    func testOwnDamageIsYouAndYourPet() {
        let seg: JSONValue = ["entities": [["kind": "you", "total": 300], ["kind": "pet", "total": 120],
                                           ["kind": "member", "total": 999]]]
        XCTAssertEqual(ownDamage(seg).you, 300)
        XCTAssertEqual(ownDamage(seg).pet, 120)
    }
}
