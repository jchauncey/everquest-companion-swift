import XCTest
import EQCompanionCore
@testable import EQCompanion

/// A multi-mob pull shown one mob at a time: the picker's rows, the mobs, and the one-mob segment.
final class MobSplitTests: XCTestCase {
    private func ev(_ kind: String, _ target: String?, _ lane: String, _ amount: Int, t: Int, crit: Bool = false,
                    outcome: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind), "lane": .string(lane),
                                      "category": .string(lane == "Mana Shock" ? "spell" : "melee"),
                                      "amount": .int(Int64(amount)), "crit": .bool(crit), "t": .int(Int64(t))]
        if let target { o["target"] = .string(target) }
        if let outcome { o["outcome"] = .string(outcome) }
        return .object(o)
    }

    private var timeline: JSONValue {
        ["durationMs": 20_000, "events": .array([
            ev("you", "Estrella of Gloomwater", "Melee", 100, t: 0, crit: true),
            ev("you", "Estrella of Gloomwater", "Mana Shock", 400, t: 5_000),
            ev("pet", "Estrella of Gloomwater", "Puma Maw", 50, t: 6_000),
            ev("you", "Estrella of Gloomwater", "Melee", 0, t: 7_000, outcome: "miss"),
            ev("member", "Shellara Ebbhunter", "Melee", 70, t: 12_000),
            ev("you", "Shellara Ebbhunter", "Melee", 30, t: 15_000),
            ev("enemy", nil, "Crush", 186, t: 3_000),
        ])]
    }

    private var fight: JSONValue {
        ["kind": "fight", "name": "Estrella of Gloomwater (3) +1", "durationSec": 20.0,
         "entities": [["kind": "pet", "name": "Garn (2)"]],
         "incoming": [["name": "Estrella of Gloomwater", "total": 500], ["name": "Shellara Ebbhunter", "total": 200]]]
    }

    func testTheMobsOfAPullLargestFirst() {
        XCTAssertEqual(pullMobs(timeline).map(\.name), ["Estrella of Gloomwater", "Shellara Ebbhunter"])
        XCTAssertEqual(pullMobs(timeline).first?.total, 550, "a miss adds nothing")
    }

    func testOneMobsSegmentIsBuiltFromItsOwnEvents() {
        let s = mobSegment(fight, timeline: timeline, mob: "estrella of gloomwater")
        XCTAssertEqual(s["name"].string, "estrella of gloomwater")
        XCTAssertEqual(s["outTotal"].double, 550)
        XCTAssertEqual(s["durationSec"].double, 8, "first to last event on it, plus a second")
        XCTAssertEqual(s["inTotal"].double, 500, "its own row of the incoming list")
        let entities = s["entities"].array ?? []
        XCTAssertEqual(entities.map { $0["name"].string ?? "" }, ["You", "Garn (2)"])
        let you = entities[0]
        XCTAssertEqual(you["total"].double, 500)
        XCTAssertEqual(you["misses"].int, 1)
        XCTAssertEqual((you["skills"].array ?? []).map { $0["name"].string ?? "" }, ["Mana Shock", "Melee"])
        XCTAssertEqual(flattenSkills(you).map(\.category).sorted(), ["melee", "spell"], "a spell stays a spell")
        let other = mobSegment(fight, timeline: timeline, mob: "Shellara Ebbhunter")
        XCTAssertEqual((other["entities"].array ?? []).map { $0["name"].string ?? "" }, ["Group", "You"])
    }

    func testTheCutTimelineKeepsOnlyThatMobsOutgoingEvents() {
        let cut = mobTimeline(timeline, mob: "Shellara Ebbhunter")
        XCTAssertEqual(cut["events"].array?.count, 2)
    }

    func testAMobIsFoundByNameEvenWhenTheInstanceNumbersDisagree() {
        let mobs = ["an Evangelist of Hate", "an elite dragoon", "Cleric of Innoruuk"]
        XCTAssertEqual(pickMob(mobs, want: "Cleric of Innoruuk (118)"), "Cleric of Innoruuk",
                       "the list numbered the spawn; the rebuilt fight did not")
        XCTAssertEqual(pickMob(["a mermaid (7)", "a mermaid (8)"], want: "a mermaid (8)"), "a mermaid (8)", "exact first")
        XCTAssertEqual(pickMob(mobs, want: "AN ELITE DRAGOON"), "an elite dragoon")
        XCTAssertEqual(pickMob(mobs, want: "a rat"), "an Evangelist of Hate", "unknown: the biggest")
        XCTAssertEqual(pickMob(mobs, want: nil), "an Evangelist of Hate")
    }

    func testThePickerListsAPullMobByMob() {
        let segs: [JSONValue] = [
            ["kind": "fight", "id": "e2", "name": "a rat", "dps": 10.0, "startTs": 2_000, "durationSec": 10.0],
            ["kind": "fight", "id": "e1", "name": "Estrella of Gloomwater (3) +1", "dps": 50.0, "startTs": 1_000,
             "durationSec": 20.0, "zone": "Kedge Keep",
             "targets": [["name": "Estrella of Gloomwater", "total": 800], ["name": "Shellara Ebbhunter", "total": 200]]],
        ]
        let rest = fightScopeOptions(segs).rest
        XCTAssertEqual(rest.map(\.value), ["e1#Estrella of Gloomwater", "e1#Shellara Ebbhunter"],
                       "the head is the last fight; the pull behind it is two rows")
        XCTAssertEqual(rest.first?.dps, 40, "that mob's damage over the pull's length")
        XCTAssertEqual(rest.first?.pull, 2)
        XCTAssertEqual(splitMobSelection("e1#Estrella of Gloomwater").fight, "e1")
        XCTAssertNil(splitMobSelection("e1").mob)
    }
}
