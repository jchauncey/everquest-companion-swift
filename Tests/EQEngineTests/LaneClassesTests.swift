// Which classes can land a combat lane: a melee lane by its skill, anything else as a cast.
import XCTest
import EQCompanionCore
import EQFold
import EQLog
@testable import EQEngine

final class LaneClassesTests: XCTestCase {
    func testLanesResolveThroughTheComboTables() {
        let idx = Ops.spellClasses
        XCTAssertTrue(laneClassCandidates(idx, lane: "Kick", category: "melee").contains("WAR"))
        XCTAssertFalse(laneClassCandidates(idx, lane: "Kick", category: "melee").contains("NEC"))
        XCTAssertEqual(laneClassCandidates(idx, lane: "Melee", category: "melee"), [], "every class swings")
        XCTAssertTrue(laneClassCandidates(idx, lane: "Heat Blood", category: "dot").contains("NEC"))
        XCTAssertTrue(laneClassCandidates(idx, lane: "Tagar's Insects", category: "spell").contains("SHM"))
        XCTAssertEqual(laneClassCandidates(idx, lane: "Vampiric Embrace · proc", category: "spell"), ["NEC", "SHD"],
                       "a proc is its granting spell's")
        XCTAssertTrue(laneClassCandidates(idx, lane: "Venom of the Snake IV", category: "dot").contains("NEC"),
                      "a rank resolves to its spell")
    }
}
