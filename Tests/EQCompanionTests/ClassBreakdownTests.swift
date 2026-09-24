import XCTest
import EQCompanionCore
@testable import EQCompanion

/// Your abilities by class: the lane's classes narrowed to your loadout, melee to the melee class,
/// the pet to its summoner.
final class ClassBreakdownTests: XCTestCase {
    private let r = ClassResolver(loadout: ["WAR", "SHM", "NEC"], lanes: [
        "melee|Kick": ["BER", "MNK", "RNG", "WAR"],
        "dot|Heat Blood": ["NEC"],
        "spell|Tagar's Insects": ["SHM"],
        "spell|Disempower": ["NEC", "SHM"],
        "melee|Melee": [],
    ])

    func testEachLaneGoesToTheClassThatLandsIt() {
        XCTAssertEqual(r.classOf(lane: "Kick", category: "melee"), "WAR")
        XCTAssertEqual(r.classOf(lane: "Melee", category: "melee"), "WAR", "a swing is the melee class's")
        XCTAssertEqual(r.classOf(lane: "Heat Blood", category: "dot"), "NEC")
        XCTAssertEqual(r.classOf(lane: "Tagar's Insects", category: "spell"), "SHM")
        XCTAssertEqual(r.classOf(lane: "Disempower", category: "spell"), otherClass, "two of your classes have it")
        XCTAssertEqual(r.classOf(lane: "Vampiric Embrace · proc", category: "spell"), otherClass, "unknown")
        XCTAssertEqual(r.petClass, "NEC")
    }

    func testTheBreakdownAddsUpYouAndYourPetByClass() {
        let you: JSONValue = ["kind": "you", "categories": [
            ["category": "melee", "skills": [["name": "Melee", "total": 600], ["name": "Kick", "total": 100]]],
            ["category": "dot", "skills": [["name": "Heat Blood", "total": 300]]],
            ["category": "spell", "skills": [["name": "Tagar's Insects", "total": 200]]],
        ]]
        let shares = classBreakdown(you: you, pets: [["kind": "pet", "total": 300]], resolver: r, durationSec: 20)
        XCTAssertEqual(shares.map(\.cls), ["WAR", "NEC", "SHM"])
        XCTAssertEqual(shares.map(\.total), [700, 600, 200])
        XCTAssertEqual(shares.first?.dps, 35)
        XCTAssertEqual(shares.map(\.pct).reduce(0, +), 100, accuracy: 0.001)
    }

    func testTheLoadoutIsTheOneYouHadWhenTheFightStarted() {
        let combo: JSONValue = [
            "current": ["slots": [["candidates": ["WAR"]], ["candidates": ["SHM"]], ["candidates": ["NEC"]]]],
            "intervals": [
                ["startTs": 1_000, "endTs": 5_000, "slots": [["candidates": ["WAR"]], ["candidates": ["NEC"]]]],
                ["startTs": 5_000, "endTs": .null, "slots": [["candidates": ["WAR"]], ["candidates": ["SHM"]],
                                                             ["candidates": ["NEC", "SHD"]]]],
            ],
        ]
        XCTAssertEqual(loadoutClasses(combo, at: 2_000), ["WAR", "NEC"])
        XCTAssertEqual(loadoutClasses(combo, at: 9_000), ["WAR", "SHM"], "an unsettled slot is left out")
        XCTAssertEqual(loadoutClasses(combo, at: nil), ["WAR", "SHM", "NEC"])
    }
}
