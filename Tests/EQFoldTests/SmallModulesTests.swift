// The ten small world-model modules, tested on the rules their headers state (fold/src/modules/
// {loot, turnins, class_unlocks, kills, output_files, character, leveling, item_tiers,
// observed_spell_ranks, spell_sets}.rs). Deep equality against the goldens is the parity bar;
// these pin the individual laws so a regression names itself.
import XCTest
import EQLog
import EQFold
import EQCompanionCore

private func ev(_ kind: String, seq: Int64 = 1, ts: Int64 = 0, _ fields: [String: JSONValue] = [:]) -> Event {
    var o: [String: JSONValue] = ["kind": .string(kind), "seq": .int(seq), "ts": .int(ts), "raw": ""]
    for (k, v) in fields { o[k] = v }
    return Event.fromValue(.object(o))
}

private extension EqModule {
    func fold(_ events: [Event]) { for e in events { onEvent(e, live: false) } }
    var state: JSONValue { snapshot()["state"] }
    var seqOf: Int64 { snapshot()["seq"].int64 ?? -1 }
}

final class SmallModulesTests: XCTestCase {
    // MARK: - loot

    func testALootRowCarriesTheZoneItWasFoldedInAndOmitsWhatTheLineDidNotSay() {
        let m = LootModule()
        m.fold([
            ev("loot", seq: 1, ts: 10, ["item": "Bone Chips"]),
            ev("zone", seq: 2, ts: 20, ["zone": "Befallen"]),
            ev("loot", seq: 3, ts: 30, ["item": "Rusty Sword", "source": "a skeleton", "count": 2,
                                        "disposition": "sold", "created": "Fine Steel"]),
        ])
        let rows = m.state.array ?? []
        XCTAssertEqual(rows.count, 2)
        // Folded before the scan reached a zone line: the key is ABSENT, not null.
        XCTAssertNil(rows[0].object?["zone"])
        XCTAssertNil(rows[0].object?["source"])
        XCTAssertNil(rows[0].object?["count"])
        XCTAssertEqual(rows[0], ["ts": 10, "item": "Bone Chips"])
        XCTAssertEqual(rows[1], ["ts": 30, "item": "Rusty Sword", "source": "a skeleton", "zone": "Befallen",
                                 "disposition": "sold", "count": 2, "created": "Fine Steel"])
        // The view layer's pull seam is the same JSON the snapshot carries, in append order.
        XCTAssertEqual(m.rows(), rows)
        XCTAssertEqual(m.seqOf, 3)
    }

    func testAnEpochClearsTheLootLedgerButKeepsTheZone() {
        let m = LootModule()
        m.fold([
            ev("zone", seq: 1, ts: 10, ["zone": "Befallen"]),
            ev("loot", seq: 2, ts: 20, ["item": "Bone Chips"]),
            ev("epoch", seq: 3, ts: 30),
            ev("loot", seq: 4, ts: 40, ["item": "Bone Chips"]),
        ])
        let rows = m.state.array ?? []
        XCTAssertEqual(rows.count, 1)
        // `zone` is world state, not character-scoped, so it survives the rebirth.
        XCTAssertEqual(rows[0]["zone"], "Befallen")
    }

    func testTheLootRevisionAndCursorMoveOnlyWhenTheLedgerCould() {
        let m = LootModule()
        m.reset()
        let afterReset = m.revision()
        m.fold([ev("zone", seq: 5, ts: 10, ["zone": "Befallen"])])
        XCTAssertEqual(m.revision(), afterReset, "a zone line is not a change to published state")
        XCTAssertEqual(m.publishedSeq, 0)
        m.fold([ev("loot", seq: 9, ts: 20, ["item": "Bone Chips"])])
        XCTAssertEqual(m.revision(), afterReset + 1)
        // The cursor lands strictly above the fold position.
        XCTAssertEqual(m.publishedSeq, 10)
    }

    // MARK: - turnins

    func testOffersAccumulateUntilTheMatchingTradeClosesTheGroup() {
        let m = TurnInsModule()
        m.fold([
            ev("offer", seq: 1, ts: 10, ["npc": "Terrorize", "item": "Bone Chips"]),
            ev("offer", seq: 2, ts: 11, ["npc": "Terrorize", "item": "Bone Chips"]),
            ev("trade", seq: 3, ts: 12, ["npc": "Terrorize"]),
        ])
        XCTAssertEqual(m.state, .array([["ts": 12, "npc": "Terrorize", "items": ["Bone Chips", "Bone Chips"]]]))
    }

    func testATradeWithADifferentNpcRecordsNothingAndStillDropsTheGroup() {
        let m = TurnInsModule()
        m.fold([
            ev("offer", seq: 1, ts: 10, ["npc": "Terrorize", "item": "Bone Chips"]),
            ev("trade", seq: 2, ts: 11, ["npc": "Guard Kane"]),
            ev("trade", seq: 3, ts: 12, ["npc": "Terrorize"]),
        ])
        XCTAssertEqual(m.state, .array([]))
        XCTAssertEqual(m.publishedSeq, 0, "nothing was ever published")
    }

    func testAnOfferToANewNpcStartsAFreshGroup() {
        let m = TurnInsModule()
        m.fold([
            ev("offer", seq: 1, ts: 10, ["npc": "Terrorize", "item": "Bone Chips"]),
            ev("offer", seq: 2, ts: 11, ["npc": "Guard Kane", "item": "Bone Chips"]),
            ev("trade", seq: 3, ts: 12, ["npc": "Guard Kane"]),
        ])
        XCTAssertEqual(m.state, .array([["ts": 12, "npc": "Guard Kane", "items": ["Bone Chips"]]]))
    }

    // MARK: - classUnlocks

    func testAClassIsRecordedOnceCaseFoldedWithTheFirstSpellingKept() {
        let m = ClassUnlocksModule()
        m.fold([
            ev("classUnlock", seq: 1, ts: 10, ["className": "Warrior"]),
            ev("classUnlock", seq: 2, ts: 20, ["className": "WARRIOR"]),
            ev("classUnlock", seq: 3, ts: 30, ["className": "Cleric"]),
        ])
        XCTAssertEqual(m.state, .array([["ts": 10, "className": "Warrior"], ["ts": 30, "className": "Cleric"]]))
        XCTAssertEqual(m.publishedSeq, 4, "the second Warrior line announced nothing")
    }

    // MARK: - kills

    func testTheKillScalarsAreFoldedFromTheTierRunsAndNeverIncremented() {
        let m = KillsModule()
        m.fold([
            ev("zone", seq: 1, ts: 10, ["zone": "Befallen"]),
            ev("death", seq: 2, ts: 20, ["name": "a skeleton"]),
            ev("zone", seq: 3, ts: 30, ["zone": "Befallen (Fused)"]),
            ev("death", seq: 4, ts: 40, ["name": "A Skeleton"]),
        ])
        let mob = m.state["mobs"]["a skeleton"]
        XCTAssertEqual(m.state["v"], 5)
        XCTAssertEqual(mob["count"], 2)
        // Open world is -1 and a `Fused` instance is d3; the best is the larger key.
        XCTAssertEqual(mob["bestTier"], 3)
        XCTAssertEqual(mob["firstTs"], 20)
        XCTAssertEqual(mob["lastTs"], 40)
        // The raw name of the FIRST sighting is the display; the key is the identity fold.
        XCTAssertEqual(mob["display"], "a skeleton")
        XCTAssertEqual(mob["tiers"]["-1"]["count"], 1)
        XCTAssertEqual(mob["tiers"]["3"]["count"], 1)
    }

    func testAnExperienceLineCreditsTheNextKillOnceAndEveryDeathConsumesIt() {
        let m = KillsModule()
        m.fold([
            ev("zone", seq: 1, ts: 0, ["zone": "Befallen"]),
            ev("expGain", seq: 2, ts: 1000),
            ev("death", seq: 3, ts: 1500, ["name": "a skeleton"]),
            ev("death", seq: 4, ts: 1600, ["name": "a skeleton"]),
        ])
        XCTAssertEqual(m.state["mobs"]["a skeleton"]["credited"], 1)
        XCTAssertEqual(m.state["mobs"]["a skeleton"]["tiers"]["-1"]["lastCreditedTs"], 1500)
    }

    func testAnExperienceLineOlderThanTheJoinWindowCreditsNothing() {
        let m = KillsModule()
        m.fold([
            ev("zone", seq: 1, ts: 0, ["zone": "Befallen"]),
            ev("expGain", seq: 2, ts: 1000),
            ev("death", seq: 3, ts: 1000 + 2501, ["name": "a skeleton"]),
        ])
        XCTAssertEqual(m.state["mobs"]["a skeleton"]["credited"], 0)
    }

    func testAKillYouDidNotLandIsNotCounted() {
        let m = KillsModule()
        m.fold([
            ev("zone", seq: 1, ts: 0, ["zone": "Befallen"]),
            ev("death", seq: 2, ts: 10, ["name": "a skeleton", "killer": "You"]),
            ev("death", seq: 3, ts: 20, ["name": "a skeleton", "killer": "Youngblood"]),
            ev("death", seq: 4, ts: 30, ["name": "a skeleton", "killer": ""]),
            ev("death", seq: 5, ts: 40, ["name": "a skeleton", "killer": "You", "bySelf": true]),
        ])
        // `Youngblood` is not the word `you`; an empty killer is falsy and does not disqualify;
        // a self-slain line always counts.
        XCTAssertEqual(m.state["mobs"]["a skeleton"]["count"], 3)
    }

    func testARememberedInstanceNoticeOverridesOpenWorldAndNothingElse() {
        let m = KillsModule()
        m.fold([
            ev("instanceCreate", seq: 1, ts: 1000, ["zone": "Befallen"]),
            ev("zone", seq: 2, ts: 1100, ["zone": "Befallen"]),
            ev("death", seq: 3, ts: 1200, ["name": "a skeleton"]),
        ])
        XCTAssertEqual(m.state["mobs"]["a skeleton"]["tiers"]["0"]["count"], 1)

        // Expired: the kill returns to the open world.
        let old = KillsModule()
        old.fold([
            ev("instanceCreate", seq: 1, ts: 0, ["zone": "Befallen"]),
            ev("zone", seq: 2, ts: 1, ["zone": "Befallen"]),
            ev("death", seq: 3, ts: 7 * 24 * 60 * 60 * 1000 + 1, ["name": "a skeleton"]),
        ])
        XCTAssertEqual(old.state["mobs"]["a skeleton"]["tiers"]["-1"]["count"], 1)

        // A kill with no zone line behind it is unknown, and a notice cannot rescue it.
        let unknown = KillsModule()
        unknown.fold([ev("death", seq: 1, ts: 10, ["name": "a skeleton"])])
        XCTAssertEqual(unknown.state["mobs"]["a skeleton"]["tiers"]["-2"]["count"], 1)
    }

    func testAnEpochClearsTheKillMapAndTheInstancesItStoodIn() {
        let m = KillsModule()
        m.fold([
            ev("instanceCreate", seq: 1, ts: 1000, ["zone": "Befallen"]),
            ev("zone", seq: 2, ts: 1100, ["zone": "Befallen"]),
            ev("death", seq: 3, ts: 1200, ["name": "a skeleton"]),
            ev("epoch", seq: 4, ts: 1300),
            ev("death", seq: 5, ts: 1400, ["name": "a skeleton"]),
        ])
        // The zone survives (it is world state), the notice does not.
        XCTAssertEqual(m.state["mobs"]["a skeleton"]["tiers"]["-1"]["count"], 1)
        XCTAssertNil(m.state["mobs"]["a skeleton"]["tiers"]["0"].object)
    }

    // MARK: - outputFiles

    func testOnlyTheNewestExportOfEachFileIsKeptKeyedByItsBareLowercasedName() {
        let m = OutputFilesModule()
        m.fold([
            ev("outputFile", seq: 1, ts: 100, ["file": "C:\\EQ\\Zoddrick_oggok-Inventory.txt"]),
            ev("outputFile", seq: 2, ts: 50, ["file": "zoddrick_oggok-inventory.txt"]),
            ev("outputFile", seq: 3, ts: 200, ["file": " /eq/zoddrick_oggok-inventory.txt "]),
        ])
        XCTAssertEqual(m.state, ["zoddrick_oggok-inventory.txt": 200])
        XCTAssertEqual(m.publishedSeq, 4, "the older stamp announced nothing")
    }

    func testAnEpochIsNotHandledByOutputFilesBecauseTheFileOnDiskOutlivesIt() {
        let m = OutputFilesModule()
        m.fold([
            ev("outputFile", seq: 1, ts: 100, ["file": "inventory.txt"]),
            ev("epoch", seq: 2, ts: 200),
        ])
        XCTAssertEqual(m.state, ["inventory.txt": 100])
    }

    // MARK: - character

    func testTheRefLandsOnTheFirstResetAndSpendsTwoRevisions() {
        let m = CharacterModule(character: ["name": "Zoddrick"])
        XCTAssertEqual(m.seqOf, 0)
        m.reset()
        // reset bumps, then the pending setCharacter bumps: the ORDER is observable.
        XCTAssertEqual(m.seqOf, 2)
        XCTAssertEqual(m.state["character"], ["name": "Zoddrick"])
        m.reset()
        XCTAssertEqual(m.seqOf, 3, "the ref lands once; a later reset spends one bump")
        XCTAssertEqual(m.state["character"], ["name": "Zoddrick"])
    }

    func testANullRefStillPublishesNullAndTheAbsentFieldsAreDropped() {
        let m = CharacterModule(character: nil)
        m.reset()
        XCTAssertEqual(m.state, ["character": .null])
        XCTAssertNil(m.state.object?["zone"])
        XCTAssertNil(m.state.object?["level"])
    }

    func testOnlyAZoneThatActuallyChangedMovesTheRevision() {
        let m = CharacterModule(character: nil)
        m.reset()
        let base = m.seqOf
        m.fold([ev("zone", seq: 1, ts: 10, ["zone": "Befallen"])])
        XCTAssertEqual(m.seqOf, base + 1)
        m.fold([ev("zone", seq: 2, ts: 20, ["zone": "Befallen"])])
        XCTAssertEqual(m.seqOf, base + 1)
        XCTAssertEqual(m.state["zone"], "Befallen")
    }

    func testTheLatestLevelStatementWinsAndWhoBreaksATie() {
        let m = CharacterModule(character: nil)
        m.reset()
        m.fold([
            ev("level", seq: 1, ts: 100, ["level": 41]),
            ev("selfWho", seq: 2, ts: 50, ["level": 39]),
        ])
        XCTAssertEqual(m.state["level"], ["level": 41, "ts": 100, "source": "ding"])
        // Same instant: `/who` breaks the tie.
        m.fold([ev("selfWho", seq: 3, ts: 100, ["level": 42])])
        XCTAssertEqual(m.state["level"], ["level": 42, "ts": 100, "source": "who"])
        // …and a ding does not take it back at the same instant.
        m.fold([ev("level", seq: 4, ts: 100, ["level": 43])])
        XCTAssertEqual(m.state["level"], ["level": 42, "ts": 100, "source": "who"])
    }

    func testAnEpochWipesTheZoneAndLevelButNotTheRef() {
        let m = CharacterModule(character: ["name": "Zoddrick"])
        m.reset()
        m.fold([
            ev("zone", seq: 1, ts: 10, ["zone": "Befallen"]),
            ev("level", seq: 2, ts: 20, ["level": 41]),
            ev("epoch", seq: 3, ts: 30),
        ])
        XCTAssertEqual(m.state, ["character": ["name": "Zoddrick"]])
    }

    // MARK: - leveling

    func testTheFourLedgersAppendInLogOrderAndAnAbsentRankIsOmitted() {
        let m = LevelingModule()
        m.fold([
            ev("level", seq: 1, ts: 10, ["level": 41]),
            ev("aaGain", seq: 2, ts: 20, ["amount": 1, "nowHave": 3]),
            ev("aaSpend", seq: 3, ts: 30, ["ability": "Innate Strength", "cost": 2]),
            ev("aaSpend", seq: 4, ts: 40, ["ability": "Innate Strength", "cost": 3, "rank": 2]),
            ev("aaPotion", seq: 5, ts: 50),
        ])
        XCTAssertEqual(m.state, [
            "levels": [["ts": 10, "level": 41]],
            "aaGains": [["ts": 20, "amount": 1, "nowHave": 3]],
            "aaSpends": [["ts": 30, "ability": "Innate Strength", "cost": 2],
                         ["ts": 40, "ability": "Innate Strength", "cost": 3, "rank": 2]],
            "aaPotions": [["ts": 50]],
        ])
        XCTAssertNil((m.state["aaSpends"].array?[0]).flatMap { $0.object?["rank"] })
    }

    func testALineThatIsNoneOfTheFiveArmsLeavesTheLevelingCursorAlone() {
        let m = LevelingModule()
        m.fold([ev("damage", seq: 900, ts: 10)])
        XCTAssertEqual(m.publishedSeq, 0)
        XCTAssertEqual(m.seqOf, 900, "the module still followed the fold position")
    }

    // MARK: - itemTiers

    func testTheHighestTierEverObservedIsKeptAndTheLatestIsReportedBeside() {
        let m = ItemTiersModule()
        m.fold([
            ev("itemMerge", seq: 1, ts: 10, ["item": "Azure Sleeves +4"]),
            ev("itemMerge", seq: 2, ts: 20, ["item": "Azure Sleeves +3"]),
        ])
        XCTAssertEqual(m.state["azure sleeves"], ["key": "azure sleeves", "name": "Azure Sleeves",
                                                  "tier": 4, "lastTier": 3, "merges": 2,
                                                  "firstAt": 10, "lastAt": 20])
    }

    func testATierlessMergeIsCountedWithNoTierAtAll() {
        let m = ItemTiersModule()
        m.fold([ev("itemMerge", seq: 1, ts: 10, ["item": "Cannibalize III"])])
        let row = m.state["cannibalize iii"]
        XCTAssertEqual(row["merges"], 1)
        XCTAssertNil(row.object?["tier"], "absent means unknown, never tier 0")
        XCTAssertNil(row.object?["lastTier"])
    }

    func testAHeldSightingMakesNoRowWithoutATierAndNeverCountsAsAMerge() {
        let m = ItemTiersModule()
        m.fold([ev("itemMergeFailed", seq: 1, ts: 10, ["reason": "mismatch", "target": "Azure Sleeves"])])
        XCTAssertEqual(m.state, .object([:]))
        m.fold([
            ev("itemMergeFailed", seq: 2, ts: 20, ["reason": "mismatch", "target": "Azure Sleeves +2"]),
            ev("itemMergeFailed", seq: 3, ts: 30, ["reason": "noRoom", "target": "Azure Sleeves +9"]),
        ])
        XCTAssertEqual(m.state["azure sleeves"]["tier"], 2)
        XCTAssertEqual(m.state["azure sleeves"]["merges"], 0)
        XCTAssertEqual(m.state["azure sleeves"]["lastAt"], 20, "only the mismatch shape names items")
    }

    func testTheAutoMergeOnPickupLineIsReadOffItsCreatedName() {
        let m = ItemTiersModule()
        m.fold([
            ev("loot", seq: 1, ts: 10, ["item": "Azure Sleeves +1", "disposition": "combined", "created": "Azure Sleeves +2"]),
            ev("loot", seq: 2, ts: 20, ["item": "Azure Sleeves +9"]),
        ])
        // Ordinary loot of a ` +N` drop is not evidence.
        XCTAssertEqual(m.state["azure sleeves"]["tier"], 2)
        XCTAssertEqual(m.state["azure sleeves"]["merges"], 1)
    }

    // MARK: - observedSpellRanks

    func testAMergeNeedsTheCatalogAndACastDoesNot() {
        let m = ObservedSpellRanksModule(knownSpell: ["lifedraw"])
        m.fold([
            ev("itemMerge", seq: 1, ts: 10, ["item": "Lifedraw IV"]),
            ev("itemMerge", seq: 2, ts: 20, ["item": "Sword of Kings II"]),
            ev("castBegin", seq: 3, ts: 30, ["spell": "Lay on Hands III"]),
        ])
        XCTAssertNil(m.state.object?["sword of kings"], "an item ending in a numeral need not be a spell")
        XCTAssertEqual(m.state["lifedraw"], ["key": "lifedraw", "name": "Lifedraw", "rank": 4, "merges": 1,
                                             "firstAt": 10, "lastAt": 10, "mergedRank": 4])
        XCTAssertEqual(m.state["lay on hands"]["castRank"], 3)
        XCTAssertNil(m.state["lay on hands"].object?["mergedRank"])
    }

    func testAnUnsuffixedNameIsNotEvidence() {
        let m = ObservedSpellRanksModule(knownSpell: ["clarity"])
        m.fold([
            ev("castBegin", seq: 1, ts: 10, ["spell": "Clarity"]),
            ev("itemMerge", seq: 2, ts: 20, ["item": "Clarity"]),
        ])
        XCTAssertEqual(m.state, .object([:]))
    }

    func testTheUnionTakesTheHighestAndALaterLowerSightingLowersNothing() {
        let m = ObservedSpellRanksModule(knownSpell: ["lifedraw"])
        m.fold([
            ev("castBegin", seq: 1, ts: 10, ["spell": "Lifedraw II"]),
            ev("itemMerge", seq: 2, ts: 20, ["item": "Lifedraw IV"]),
            ev("castBegin", seq: 3, ts: 30, ["spell": "Lifedraw I"]),
        ])
        XCTAssertEqual(m.state["lifedraw"], ["key": "lifedraw", "name": "Lifedraw", "rank": 4, "merges": 1,
                                             "firstAt": 10, "lastAt": 30, "mergedRank": 4, "castRank": 2])
    }

    func testOnlyYourOwnOutgoingResistNamesASpellYouOwn() {
        let m = ObservedSpellRanksModule(knownSpell: [])
        m.fold([
            ev("resist", seq: 1, ts: 10, ["caster": "you", "spell": "Lifedraw IV"]),
            ev("resist", seq: 2, ts: 20, ["caster": "Nagafen", "spell": "Ancient Breath II"]),
            ev("resist", seq: 3, ts: 30, ["caster": "you", "spell": "Cold Blast III", "incoming": true]),
        ])
        XCTAssertEqual(m.state["lifedraw"]["castRank"], 4)
        XCTAssertNil(m.state.object?["ancient breath"])
        XCTAssertNil(m.state.object?["cold blast"])
    }

    // MARK: - spellSets

    func testASaveIsAPhotographOfTheBarRightNow() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellMemorize", seq: 1, ts: 10, ["spell": "Clarity", "done": true]),
            ev("spellMemorize", seq: 2, ts: 20, ["spell": "Lifedraw", "done": true]),
            ev("spellSet", seq: 3, ts: 30, ["set": "combat", "action": "saved"]),
        ])
        XCTAssertEqual(m.state["memorized"], ["Clarity", "Lifedraw"])
        XCTAssertEqual(m.state["sets"]["combat"], ["spells": ["Clarity", "Lifedraw"], "observedAt": 30, "source": "saved"])
        XCTAssertEqual(m.state["v"], 1)
    }

    func testALoadTakesTheDefinitionWhenTheBurstSettles() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellSet", seq: 1, ts: 0, ["set": "dam", "action": "loaded"]),
            ev("spellMemorize", seq: 2, ts: 1000, ["spell": "Lifedraw", "done": true]),
            // A quiet line eleven seconds on proves the burst is over.
            ev("damage", seq: 3, ts: 12_000),
        ])
        XCTAssertEqual(m.state["sets"]["dam"], ["spells": ["Lifedraw"], "observedAt": 12_000, "source": "loaded"])
    }

    func testTheNextSpellSetLineClosesAnOpenLoadFirst() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellMemorize", seq: 1, ts: 0, ["spell": "Clarity", "done": true]),
            ev("spellSet", seq: 2, ts: 100, ["set": "dam", "action": "loaded"]),
            ev("spellSet", seq: 3, ts: 200, ["set": "buffs", "action": "saved"]),
        ])
        // The load settled at the second line's instant, before the save did its own work.
        XCTAssertEqual(m.state["sets"]["dam"]["observedAt"], 200)
        XCTAssertEqual(m.state["sets"]["dam"]["source"], "loaded")
        XCTAssertEqual(m.state["sets"]["buffs"]["source"], "saved")
    }

    func testAnUnfinishedMemorizeOnlyHoldsTheWindowOpen() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellSet", seq: 1, ts: 0, ["set": "dam", "action": "loaded"]),
            ev("spellMemorize", seq: 2, ts: 9000, ["spell": "Lifedraw", "done": false]),
            ev("damage", seq: 3, ts: 12_000),
        ])
        XCTAssertEqual(m.state["memorized"], .array([]), "a begin line loads no gem")
        XCTAssertNil(m.state["sets"].object?["dam"], "…and the window was still open at 12 s")
    }

    func testAForgetClosesTheGapAndADeleteDropsTheSet() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellMemorize", seq: 1, ts: 10, ["spell": "Clarity", "done": true]),
            ev("spellMemorize", seq: 2, ts: 11, ["spell": "  lifedraw  ", "done": true]),
            ev("spellForget", seq: 3, ts: 12, ["spell": "CLARITY"]),
            ev("spellSet", seq: 4, ts: 13, ["set": "combat", "action": "saved"]),
            ev("spellSet", seq: 5, ts: 14, ["set": "combat", "action": "deleted"]),
        ])
        // The memo key is case- and whitespace-folded; the display keeps the trimmed spelling.
        XCTAssertEqual(m.state["memorized"], ["lifedraw"])
        XCTAssertEqual(m.state["sets"], .object([:]))
    }

    func testTheWallClockSettlesAQuietLoad() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellMemorize", seq: 1, ts: 0, ["spell": "Clarity", "done": true]),
            ev("spellSet", seq: 2, ts: 100, ["set": "dam", "action": "loaded"]),
        ])
        XCTAssertNil(m.state["sets"].object?["dam"])
        m.onTick(nowMs: 100 + 10_000, timerRows: [])
        XCTAssertEqual(m.state["sets"]["dam"]["observedAt"], 10_100)
        // A settle with no event behind it still announces.
        XCTAssertEqual(m.publishedSeq, 3)
    }

    func testTheEpochZeroesTheSpellSetsSeqUntilTheNextLine() {
        let m = SpellSetsModule()
        m.fold([
            ev("spellMemorize", seq: 40, ts: 10, ["spell": "Clarity", "done": true]),
            ev("epoch", seq: 41, ts: 20),
        ])
        // Ported verbatim: `reset()` zeroes `seq` after the assignment at the top of onEvent.
        XCTAssertEqual(m.seqOf, 0)
        XCTAssertEqual(m.state["memorized"], .array([]))
        // …and the cursor still lands above the event's own position, not above the zeroed field.
        XCTAssertEqual(m.publishedSeq, 42)
        m.fold([ev("damage", seq: 42, ts: 30)])
        XCTAssertEqual(m.seqOf, 42)
    }
}
