import XCTest
import EQCompanionCore
@testable import EQCompanion

final class PetBreakdownTests: XCTestCase {
    private let pet: JSONValue = ["kind": "pet", "name": "Kaber", "total": 900, "dps": 30.0,
                                  "skills": [["name": "Melee", "total": 700, "hits": 20, "crits": 2],
                                             ["name": "Lifedraw", "total": 200, "hits": 2, "crits": 0]]]
    private let log: JSONValue = [
        "casts": [["spell": "lifedraw", "casts": 3, "resisted": 1], ["spell": "Heat Blood", "casts": 1, "resisted": 0]],
        "taken": [["attacker": "A wan ghoul knight", "total": 400, "hits": 9, "misses": 3],
                  ["attacker": "a zol ghoul knight", "total": 150, "hits": 4, "misses": 0]],
        "healed": [["healer": "itself", "total": 18, "raw": 105], ["healer": "Zoddrick", "total": 300, "raw": 300]],
        "buffs": ["Augment Death"],
    ]

    func testItsLanesAndItsCastsAreOneListByName() {
        let b = petBreakdown(pet, log: log, mob: nil)
        XCTAssertEqual(b.abilities.map(\.name), ["Melee", "Lifedraw", "Heat Blood"])
        XCTAssertEqual(b.abilities[1].casts, 3, "matched without regard to case")
        XCTAssertEqual(b.abilities[1].resisted, 1)
        XCTAssertEqual(b.abilities[2].total, 0, "cast but landed nothing")
        XCTAssertEqual(b.takenTotal, 550)
        XCTAssertEqual(b.selfHealed, 18)
        XCTAssertEqual(b.healedByOthers, 300)
        XCTAssertEqual(b.buffs, ["Augment Death"])
    }

    func testOneMobOnScreenKeepsOnlyItsDamageToThePet() {
        let b = petBreakdown(pet, log: log, mob: "a wan ghoul knight")
        XCTAssertEqual(b.taken.map(\.name), ["A wan ghoul knight"])
    }

    func testTheSegmentsPetIsTheOneThatDidTheMost() {
        let seg: JSONValue = ["entities": [["kind": "you", "total": 5000], ["kind": "pet", "name": "a", "total": 10],
                                           ["kind": "pet", "name": "b", "total": 20]]]
        XCTAssertEqual(segmentPet(seg)?["name"].string, "b")
        XCTAssertNil(segmentPet(["entities": [["kind": "you"]]]))
    }
}
