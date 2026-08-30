// The three modules ported from fold/src/modules/{progression,event_feed,roster}.rs, tested at the
// laws their headers state. The event-feed cases are the Rust file's own unit tests, ported.
import XCTest
import EQLog
import EQFold
import EQCompanionCore

private func ev(_ json: String) -> Event {
    guard let e = Event.fromJSON(json) else { preconditionFailure("a JSON object") }
    return e
}

/// A lookup that answers from a table: only the SHAPE of the production answer matters here.
private final class Table: Knowledge, @unchecked Sendable {
    let rows: [(String, JSONValue)]
    init(_ rows: [(String, JSONValue)]) { self.rows = rows }

    func item(_ name: String) -> KnowledgeAnswer {
        if let hit = rows.first(where: { $0.0 == name }) { return KnowledgeAnswer(record: hit.1, found: true) }
        return KnowledgeAnswer(record: ["name": .string(name), "lore": false, "quest": false,
                                        "questUses": .array([]), "cached": false, "notFound": true],
                               found: false)
    }
    func identityKeys(_ mob: String) -> [String] { [mob.lowercased()] }
    func mob(_ name: String, loot: OwnLoot) -> KnowledgeAnswer {
        KnowledgeAnswer(record: ["name": .string(name), "cached": true], found: true)
    }
    /// Nothing on the feed's path asks this.
    func knownMob(_ name: String) -> Bool { true }
    func takeMisses() -> [KnowledgeMiss] { [] }
}

// MARK: - eventFeed

final class EventFeedModuleTests: XCTestCase {
    private func state(_ m: EventFeedModule) -> [JSONValue] { m.snapshot()["state"].array ?? [] }

    private func loot(_ seq: Int64, _ item: String) -> String {
        #"{"kind":"loot","item":"\#(item)","source":"a sand giant","seq":\#(seq),"ts":1787181707000,"raw":"x"}"#
    }

    private var runeTable: Table {
        Table([("Rune of Al'Kabor",
                ["name": "Rune of Al'Kabor", "lore": true, "quest": true, "questUses": .array([]),
                 "page": "Rune of Al'Kabor"])])
    }

    func testAHistoricalFoldAdmitsNothingHoweverNotableTheItem() {
        // The hydration rule, pinned against the one thing that could break it: a real lookup.
        let feed = EventFeedModule()
        feed.installKnowledge(runeTable)
        feed.onEvent(ev(loot(1, "Rune of Al'Kabor")), live: false)
        XCTAssertTrue(state(feed).isEmpty)
        XCTAssertEqual(feed.snapshot()["seq"].int64, 1, "the seq is still every event's")
    }

    func testALiveNotablePickupIsAdmittedAndAnOrdinaryOneIsNot() {
        let feed = EventFeedModule()
        feed.installKnowledge(runeTable)
        feed.onEvent(ev(loot(1, "Bone Chips")), live: true)
        XCTAssertTrue(state(feed).isEmpty, "vendor trash is not notable")
        feed.onEvent(ev(loot(2, "Rune of Al'Kabor")), live: true)
        let rows = state(feed)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"].string, "f1")
        XCTAssertEqual(rows[0]["kind"].string, "loot")
        XCTAssertEqual(rows[0]["detail"].string, "from a sand giant")
        XCTAssertEqual(rows[0]["page"].string, "Rune of Al'Kabor")
    }

    func testWithNoLookupInstalledTheLootSourceIsStructurallyOff() {
        let feed = EventFeedModule()
        feed.onEvent(ev(loot(1, "Rune of Al'Kabor")), live: true)
        XCTAssertTrue(state(feed).isEmpty)
    }

    func testADestroySaysSoAndNeverBorrowsTheFromCaption() {
        let feed = EventFeedModule()
        feed.installKnowledge(Table([("Bone Chips",
                                      ["name": "Bone Chips", "lore": false, "quest": true,
                                       "questUses": .array([])])]))
        feed.onEvent(ev(#"{"kind":"loot","item":"Bone Chips","disposition":"destroyed","seq":3,"ts":1787181707000,"raw":"x"}"#), live: true)
        XCTAssertEqual(state(feed)[0]["detail"].string, "destroyed")
        XCTAssertTrue(state(feed)[0]["page"].isNull, "no page on a record that states none")
    }

    func testAReConInsideTheWindowAppendsNothing() {
        let feed = EventFeedModule()
        func con(_ seq: Int64, _ ts: Int64) -> String {
            #"{"kind":"consider","mob":"Guard V`Lex","rare":false,"level":38,"faction":"dubious","difficulty":"What would you like your tombstone to say?","seq":\#(seq),"ts":\#(ts),"raw":"x"}"#
        }
        feed.onEvent(ev(con(1, 1_000_000)), live: true)
        feed.onEvent(ev(con(2, 1_000_000 + considerFeedDedupeMs - 1)), live: true)
        XCTAssertEqual(state(feed).count, 1, "the burst is one row")
        feed.onEvent(ev(con(3, 1_000_000 + considerFeedDedupeMs)), live: true)
        let rows = state(feed)
        XCTAssertEqual(rows.count, 2, "a genuine re-con later in the pull is a row")
        XCTAssertEqual(rows[0]["detail"].string, "Lvl 38 · suicide")
        XCTAssertEqual(rows[0]["con"]["faction"].string, "dubious")
        XCTAssertEqual(rows[0]["con"]["level"].int64, 38)
        XCTAssertEqual(rows[1]["id"].string, "f2")
    }

    func testAnUnrecognizedDifficultyClauseFallsBackToTheVerbatimOne() {
        XCTAssertEqual(difficultyShort("Looks like SHE would wipe the floor with you!"), "wipes the floor",
                       "the gendered variants fold onto the neuter key")
        XCTAssertEqual(difficultyShort("  He appears to be quite formidable. "), "formidable")
        XCTAssertNil(difficultyShort("regards you with something new."))
    }

    func testNotabilityIsTheSharedPredicateAndARecipeIsNotNotable() {
        XCTAssertTrue(isNotable(["lore": true, "quest": false, "questUses": .array([])]))
        XCTAssertTrue(isNotable(["lore": false, "quest": true, "questUses": .array([])]))
        XCTAssertTrue(isNotable(["lore": false, "quest": false, "questUses": .array([["quest": "x"]])]))
        XCTAssertFalse(isNotable(["lore": false, "quest": false, "questUses": .array([]),
                                  "recipes": .array([["recipe": "Gnome Kabobs"]])]))
    }
}

// MARK: - progression

final class ProgressionModuleTests: XCTestCase {
    private func state(_ m: ProgressionModule) -> JSONValue { m.snapshot()["state"] }

    private func exp(_ seq: Int64, _ ts: Int64, pct: String = "1.5", party: Bool = false) -> String {
        #"{"kind":"expGain","pct":\#(pct),"party":\#(party),"seq":\#(seq),"ts":\#(ts),"raw":"x"}"#
    }
    private func selfKill(_ seq: Int64, _ ts: Int64, _ name: String = "a rat") -> String {
        #"{"kind":"death","name":"\#(name)","bySelf":true,"seq":\#(seq),"ts":\#(ts),"raw":"x"}"#
    }
    private func killBy(_ seq: Int64, _ ts: Int64, _ killer: String, _ name: String = "a rat") -> String {
        #"{"kind":"death","name":"\#(name)","bySelf":false,"killer":"\#(killer)","seq":\#(seq),"ts":\#(ts),"raw":"x"}"#
    }

    func testTheExperienceJoinLooksBackwardAndTheClaimConsumesTheLine() {
        let p = ProgressionModule()
        p.onEvent(ev(exp(1, 1000)), live: false)
        p.onEvent(ev(selfKill(2, 1500)), live: false)
        let rows = state(p)["recentKills"].array ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["expFlag"].int64, 0)
        XCTAssertEqual(rows[0]["expPct"].double, 1.5)
        XCTAssertEqual(state(p)["expPct"].array?.first?.double, 1.5)
        // The line is gone: a second kill inside the same window carries no experience at all.
        p.onEvent(ev(selfKill(3, 1600)), live: false)
        let after = state(p)["recentKills"].array ?? []
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after[1]["expFlag"].isNull, "absent, which is not the same sentence as 0")
        XCTAssertTrue(after[1]["expPct"].isNull)
    }

    func testAKillOutsideTheJoinWindowAndOneBeforeTheLineCarryNothing() {
        let p = ProgressionModule()
        p.onEvent(ev(exp(1, 1000)), live: false)
        p.onEvent(ev(selfKill(2, 1000 + 2501)), live: false)
        XCTAssertTrue((state(p)["recentKills"].array ?? [])[0]["expFlag"].isNull)
        let q = ProgressionModule()
        q.onEvent(ev(exp(1, 5000)), live: false)
        q.onEvent(ev(selfKill(2, 4000)), live: false)
        XCTAssertTrue((state(q)["recentKills"].array ?? [])[0]["expFlag"].isNull)
    }

    func testAWitnessedKillConsumesTheLineToo() {
        let p = ProgressionModule()
        p.onEvent(ev(exp(1, 1000)), live: false)
        p.onEvent(ev(killBy(2, 1100, "Dranix")), live: false)
        p.onEvent(ev(selfKill(3, 1200)), live: false)
        XCTAssertEqual(state(p)["witnessTs"].array?.count, 1)
        XCTAssertEqual(state(p)["killTs"].array?.count, 1)
        XCTAssertTrue((state(p)["recentKills"].array ?? [])[0]["expFlag"].isNull,
                      "the group-mate's party experience is not handed to your own next kill")
    }

    func testALineThatStatedNoPercentageIsMinusOneAndFlagBitOne() {
        let p = ProgressionModule()
        p.onEvent(ev(#"{"kind":"expGain","party":true,"seq":1,"ts":1000,"raw":"x"}"#), live: false)
        XCTAssertEqual(state(p)["expPct"].array?.first?.double, -1.0)
        XCTAssertEqual(state(p)["expFlag"].array?.first?.int64, 3)
        p.onEvent(ev(selfKill(2, 1000)), live: false)
        XCTAssertEqual((state(p)["recentKills"].array ?? [])[0]["expFlag"].int64, 3)
        XCTAssertTrue((state(p)["recentKills"].array ?? [])[0]["expPct"].isNull)
    }

    func testTheThirdPersonTwinOfYourOwnKillIsNotCountedTwice() {
        let p = ProgressionModule()
        p.onEvent(ev(killBy(1, 1000, "You")), live: false)
        p.onEvent(ev(killBy(2, 1100, "")), live: false)
        XCTAssertEqual(state(p)["killTs"].array?.count, 0)
        XCTAssertEqual(state(p)["witnessTs"].array?.count, 0)
    }

    func testCharmDiesAtAZoneLineAndAClaimForACharmedNameOnlyReArmsIt() {
        let p = ProgressionModule()
        p.onEvent(ev(#"{"kind":"charm","mob":"a pixie","seq":1,"ts":1000,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"petClaim","name":"a pixie","seq":2,"ts":1010,"raw":"x"}"#), live: false)
        p.onEvent(ev(killBy(3, 1100, "a pixie")), live: false)
        XCTAssertEqual(state(p)["killCredit"].array?.first?.int64, 1, "a bound pet's blow is credited")
        p.onEvent(ev(#"{"kind":"zone","zone":"Innothule Swamp","seq":4,"ts":1200,"raw":"x"}"#), live: false)
        p.onEvent(ev(killBy(5, 1300, "a pixie")), live: false)
        XCTAssertEqual(state(p)["killTs"].array?.count, 1, "the claim never promoted a charmed mob")
        XCTAssertEqual(state(p)["witnessTs"].array?.count, 1)
    }

    func testASummonedPetFollowsYouThroughAZoneLine() {
        let p = ProgressionModule()
        p.onEvent(ev(#"{"kind":"petClaim","name":"Xarok","seq":1,"ts":1000,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"zone","zone":"Innothule Swamp","seq":2,"ts":1100,"raw":"x"}"#), live: false)
        p.onEvent(ev(killBy(3, 1200, "Xarok")), live: false)
        XCTAssertEqual(state(p)["killCredit"].array?.first?.int64, 1)
        XCTAssertEqual(state(p)["killZone"].array?.first?.int64, 0, "the zone the kill happened in")
    }

    func testTheZoneTimelineClosesTheOpenIntervalAndAKillBeforeAnyZoneIsMinusOne() {
        let p = ProgressionModule()
        p.onEvent(ev(selfKill(1, 900)), live: false)
        p.onEvent(ev(#"{"kind":"zone","zone":"Nagafen's Lair","seq":2,"ts":1000,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"zone","zone":"Innothule Swamp","seq":3,"ts":2000,"raw":"x"}"#), live: false)
        p.onEvent(ev(selfKill(4, 2100)), live: false)
        XCTAssertEqual(state(p)["zoneStart"].array?.map { $0.int64 }, [1000, 2000])
        XCTAssertEqual(state(p)["zoneEnd"].array?.map { $0.int64 }, [2000, 0])
        XCTAssertEqual(state(p)["zoneName"].array?.map { $0.string }, ["Nagafen's Lair", "Innothule Swamp"])
        XCTAssertEqual(state(p)["killZone"].array?.map { $0.int64 }, [-1, 1])
        let rows = state(p)["recentKills"].array ?? []
        XCTAssertEqual(rows[0]["zone"].string, "", "unknown, never fabricated")
        XCTAssertEqual(rows[1]["zone"].string, "Innothule Swamp")
    }

    func testOfflineGapsAreFoldedVerbatimAndANonPositiveSpanIsDropped() {
        let p = ProgressionModule()
        p.onEvent(ev(#"{"kind":"offlineGap","fromTs":1000,"toTs":2000,"camped":true,"seq":1,"ts":2000,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"offlineGap","fromTs":3000,"toTs":3000,"camped":false,"seq":2,"ts":3000,"raw":"x"}"#), live: false)
        XCTAssertEqual(state(p)["offlineStart"].array?.map { $0.int64 }, [1000])
        XCTAssertEqual(state(p)["offlineEnd"].array?.map { $0.int64 }, [2000])
        XCTAssertEqual(state(p)["offlineCamped"].array?.map { $0.int64 }, [1])
    }

    func testLootIsATimestampOnlyActivitySignalAndTheLevelColumnsMirrorTheDings() {
        let p = ProgressionModule()
        p.onEvent(ev(#"{"kind":"loot","item":"Bone Chips","seq":1,"ts":1000,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"loot","item":"Bone Chips","disposition":"destroyed","seq":2,"ts":1100,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"level","level":42,"seq":3,"ts":1200,"raw":"x"}"#), live: false)
        p.onEvent(ev(#"{"kind":"aaGain","amount":3,"seq":4,"ts":1300,"raw":"x"}"#), live: false)
        XCTAssertEqual(state(p)["lootTs"].array?.map { $0.int64 }, [1000, 1100])
        XCTAssertEqual(state(p)["levelTs"].array?.map { $0.int64 }, [1200])
        XCTAssertEqual(state(p)["levelValue"].array?.map { $0.int64 }, [42])
        XCTAssertEqual(state(p)["aaGainAmount"].array?.map { $0.int64 }, [3])
        XCTAssertEqual(state(p)["lastTs"].int64, 1300)
    }

    func testARebirthWipesEveryColumnAndDoesNotAdvanceLastTs() {
        let p = ProgressionModule()
        p.onEvent(ev(selfKill(1, 1000)), live: false)
        p.onEvent(ev(#"{"kind":"epoch","reason":"launch","seq":2,"ts":9000,"raw":"x"}"#), live: false)
        XCTAssertEqual(state(p)["killTs"].array?.count, 0)
        XCTAssertEqual(state(p)["recentKills"].array?.count, 0)
        XCTAssertEqual(state(p)["lastTs"].int64, 0, "the boundary event does not advance the clock")
        XCTAssertEqual(p.snapshot()["seq"].int64, 2)
    }

    func testTheRecentKillsRingIsCappedByCountAndNeverMovesDropped() {
        let p = ProgressionModule()
        for i in 1...60 { p.onEvent(ev(selfKill(Int64(i), Int64(1000 + i * 10), "mob\(i)")), live: false) }
        let rows = state(p)["recentKills"].array ?? []
        XCTAssertEqual(rows.count, 50)
        XCTAssertEqual(rows[0]["name"].string, "mob11", "oldest first, drop-oldest by count")
        XCTAssertEqual(state(p)["killTs"].array?.count, 60, "the column itself is untouched")
        XCTAssertEqual(state(p)["dropped"].int64, 0)
        XCTAssertEqual(state(p)["windowStart"].int64, 0)
    }
}

// MARK: - roster

final class RosterModuleTests: XCTestCase {
    private func members(_ m: RosterModule) -> [JSONValue] { m.snapshot()["state"]["members"].array ?? [] }

    private func group(_ seq: Int64, _ ts: Int64, _ change: String, _ name: String? = nil) -> String {
        let n = name.map { ",\"name\":\"\($0)\"" } ?? ""
        return "{\"kind\":\"group\",\"change\":\"\(change)\"\(n),\"seq\":\(seq),\"ts\":\(ts),\"raw\":\"x\"}"
    }
    private func heal(_ seq: Int64, _ ts: Int64, _ target: String, spell: String = "Quick Heal") -> String {
        #"{"kind":"heal","healer":"You","target":"\#(target)","spell":"\#(spell)","overTime":false,"amount":10,"seq":\#(seq),"ts":\#(ts),"raw":"x"}"#
    }
    private let partyExp = #"{"kind":"expGain","pct":1.0,"party":true,"seq":1,"ts":900,"raw":"x"}"#

    func testAJoinLineNamesAMemberAndAnInviteOnlySaysAGroupIsInPlay() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "invite", "Dranix")), live: false)
        XCTAssertTrue(members(r).isEmpty, "an invite may be declined")
        XCTAssertEqual(r.snapshot()["state"]["seen"].bool, true)
        XCTAssertEqual(r.snapshot()["state"]["lastSignalTs"].int64, 1000)
        r.onEvent(ev(group(2, 2000, "join", "Dranix")), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["dranix"])
        XCTAssertEqual(members(r)[0]["source"].string, "joined")
        XCTAssertEqual(members(r)[0]["sinceTs"].int64, 2000)
        XCTAssertEqual(members(r)[0]["stale"].bool, false)
    }

    func testProvenanceOnlyEverMovesUpTheLadder() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        r.onEvent(ev(group(2, 2000, "confirm", "Dranix")), live: false)
        XCTAssertEqual(members(r)[0]["source"].string, "joined", "a weaker signal never overwrites")
        XCTAssertEqual(members(r)[0]["lastConfirmedTs"].int64, 2000)
        r.onEvent(ev(group(3, 3000, "leader", "dranix")), live: false)
        XCTAssertEqual(members(r)[0]["source"].string, "joined")
        XCTAssertEqual(members(r)[0]["name"].string, "Dranix", "the log's own spelling, not the key")
    }

    func testALeaveHidesTheRowAndASelfLeaveEndsTheGroup() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        r.onEvent(ev(group(2, 2000, "leave", "Dranix")), live: false)
        XCTAssertTrue(members(r).isEmpty)
        XCTAssertEqual(r.admitted(), ["dranix"], "their recorded damage stays real")
        r.onEvent(ev(group(3, 3000, "join", "Kaelen")), live: false)
        r.onEvent(ev(group(4, 4000, "selfLeave")), live: false)
        XCTAssertTrue(members(r).isEmpty)
        XCTAssertTrue(r.admitted().isEmpty, "only a self-leave or an epoch resets admission")
        XCTAssertEqual(r.snapshot()["state"]["seen"].bool, true)
    }

    func testTheBuffedRungNeedsBothTheBurstAndThePartyExperienceGate() {
        let cold = RosterModule(selfName: "Primitive")
        cold.onEvent(ev(heal(2, 1000, "Dranix")), live: false)
        cold.onEvent(ev(heal(3, 1000, "Kaelen")), live: false)
        XCTAssertTrue(members(cold).isEmpty, "a burst with no group stated is a townside hand-out")

        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(partyExp), live: false)
        XCTAssertTrue(members(r).isEmpty, "the party-exp line names nobody")
        XCTAssertEqual(r.snapshot()["state"]["seen"].bool, false)
        r.onEvent(ev(heal(2, 1000, "Dranix")), live: false)
        XCTAssertTrue(members(r).isEmpty, "one target is not a fan-out")
        r.onEvent(ev(heal(3, 1000, "Kaelen")), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["dranix", "kaelen"], "arrival order")
        XCTAssertEqual(members(r)[0]["source"].string, "buffed")
        XCTAssertEqual(r.snapshot()["state"]["lastSignalTs"].int64, 1000)
    }

    func testASecondSpellInTheSameSecondIsASecondCastAndAHotTickIsNoBurst() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(partyExp), live: false)
        r.onEvent(ev(heal(2, 1000, "Dranix", spell: "Quick Heal")), live: false)
        r.onEvent(ev(heal(3, 1000, "Kaelen", spell: "Other Heal")), live: false)
        XCTAssertTrue(members(r).isEmpty, "two spells in one second are two casts")
        r.onEvent(ev(#"{"kind":"heal","healer":"Dranix","target":"Kaelen","spell":"Quick Heal","overTime":false,"seq":4,"ts":2000,"raw":"x"}"#), live: false)
        r.onEvent(ev(#"{"kind":"heal","healer":"Dranix","target":"Zed","spell":"Quick Heal","overTime":false,"seq":5,"ts":2000,"raw":"x"}"#), live: false)
        XCTAssertTrue(members(r).isEmpty, "another player's group buff enumerates THEIR group")
        r.onEvent(ev(#"{"kind":"heal","healer":"You","target":"Kaelen","spell":"Regen","overTime":true,"seq":6,"ts":3000,"raw":"x"}"#), live: false)
        r.onEvent(ev(#"{"kind":"heal","healer":"You","target":"Zed","spell":"Regen","overTime":true,"seq":7,"ts":3000,"raw":"x"}"#), live: false)
        XCTAssertTrue(members(r).isEmpty, "a tick is cast-detached")
    }

    func testAPetIsRefusedFromTheWeakestRungRetroactively() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(partyExp), live: false)
        r.onEvent(ev(heal(2, 1000, "Xarok")), live: false)
        r.onEvent(ev(heal(3, 1000, "Dranix")), live: false)
        XCTAssertEqual(members(r).count, 2)
        r.onEvent(ev(#"{"kind":"petClaim","name":"Xarok","seq":4,"ts":1100,"raw":"x"}"#), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["dranix"], "the claim reaches backward")
        XCTAssertEqual(r.admitted(), ["dranix"])
    }

    func testAStatedMemberSurvivesThePetRefusal() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Xarok")), live: false)
        r.onEvent(ev(#"{"kind":"charm","mob":"Xarok","seq":2,"ts":1100,"raw":"x"}"#), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["xarok"],
                       "what the game said outright is not overruled")
    }

    func testTheTailedCharacterIsNeverAMember() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(partyExp), live: false)
        r.onEvent(ev(heal(2, 1000, "Primitive")), live: false)
        r.onEvent(ev(heal(3, 1000, "Dranix")), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["dranix"])
    }

    func testAnOfflineGapStalesRatherThanEmpties() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        r.onEvent(ev(#"{"kind":"offlineGap","fromTs":1500,"toTs":9000,"camped":true,"seq":2,"ts":9000,"raw":"x"}"#), live: false)
        XCTAssertEqual(members(r).count, 1, "hiding a real member is the worse error")
        XCTAssertEqual(members(r)[0]["stale"].bool, true)
        XCTAssertEqual(r.members(), ["dranix"], "a stale member STILL PASSES the allowlist")
        r.onEvent(ev(group(3, 10000, "confirm", "Dranix")), live: false)
        XCTAssertEqual(members(r)[0]["stale"].bool, false, "any fresh signal ends staleness")
    }

    func testARebirthClearsTheGroupAndDatesTheUserEditsOut() {
        let r = RosterModule(selfName: "Primitive")
        r.define(.array([["action": "add", "key": "zed", "name": "Zed", "setAt": 500]]))
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["dranix", "zed"])
        r.onEvent(ev(#"{"kind":"epoch","reason":"launch","seq":2,"ts":2000,"raw":"x"}"#), live: false)
        XCTAssertTrue(members(r).isEmpty, "the edit described a character that no longer exists")
        XCTAssertEqual(r.snapshot()["state"]["seen"].bool, false)
    }

    func testUserEditsAreALayerOverTheLog() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        r.define(.array([["action": "remove", "key": "dranix", "name": "Dranix", "setAt": 1500],
                         ["action": "add", "key": "zed", "name": "Zed", "setAt": 1500],
                         ["action": "sideways", "key": "nope", "name": "Nope", "setAt": 1500]]))
        XCTAssertEqual(members(r).map { $0["key"].string }, ["zed"], "a malformed edit is refused whole")
        XCTAssertEqual(members(r)[0]["source"].string, "user")
        XCTAssertEqual(r.admitted(), ["dranix", "zed"],
                       "a user ADD joins admission and a user REMOVE does not leave it")
        r.onEvent(ev(group(2, 2000, "join", "Dranix")), live: false)
        XCTAssertEqual(members(r).map { $0["key"].string }, ["zed"], "a later join cannot undo a remove")
    }

    func testAUserAddOverAKnownMemberKeepsTheirJoinTimeAndGainsTheTopRung() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        r.define(.array([["action": "add", "key": "dranix", "name": "Dranix", "setAt": 1500]]))
        XCTAssertEqual(members(r)[0]["sinceTs"].int64, 1000)
        XCTAssertEqual(members(r)[0]["source"].string, "user")
    }

    func testTheSeamAnswersTheSameListTheSnapshotPublishes() {
        let r = RosterModule(selfName: "Primitive")
        r.onEvent(ev(group(1, 1000, "join", "Dranix")), live: false)
        let snap = r.snap()
        XCTAssertEqual(snap.members.map(\.key), ["dranix"])
        XCTAssertEqual(snap.members[0].source, "joined")
        XCTAssertEqual(snap.seen, true)
        XCTAssertEqual(snap.lastSignalTs, 1000)
        XCTAssertEqual(r.nameOf("dranix"), "Dranix")
        XCTAssertNil(r.nameOf("kaelen"))
    }
}
