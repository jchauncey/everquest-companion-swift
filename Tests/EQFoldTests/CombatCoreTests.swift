// The unit tests at the bottom of the seven Rust files the combat CORE is ported from:
// `combat/{state,mod,ingest,routing,aggregate,collate,spellfacts}.rs`.
import XCTest
@testable import EQFold
import EQLog
import EQCompanionCore

// MARK: - state.rs

final class CombatStateTests: XCTestCase {
    func testAnInstanceIdsNameKeyIsEverythingBeforeTheLastHash() {
        XCTAssertEqual(nameKeyOf("a spite golem#12"), "a spite golem")
        XCTAssertNil(nameKeyOf("you"))
        XCTAssertNil(nameKeyOf("#3"))
    }

    /// The three absolute refusals: a pet, a charmed name and something you have struck can never be
    /// filed as a player, whatever a heal line says.
    func testAPetACharmAndAMobYouStruckCanNeverBecomePlayers() {
        var st = EngineState()
        st.notePet("vebarn")
        st.notePlayer("vebarn")
        XCTAssertFalse(st.knownPlayers.contains("vebarn"))

        st = EngineState()
        _ = st.charm.charmBroadcast("a rock golem", "a rock golem", 0)
        st.notePlayer("a rock golem")
        XCTAssertFalse(st.knownPlayers.contains("a rock golem"))

        st = EngineState()
        st.noteStruck("lord of loathing")
        st.notePlayer("lord of loathing")
        XCTAssertFalse(st.knownPlayers.contains("lord of loathing"))
    }

    /// …and the one that DOES file: a stranger who healed you, with none of the three against them.
    func testAHealerWithNoRefusalAgainstThemIsFiledAPlayer() {
        let st = EngineState()
        st.notePlayer("sonista")
        XCTAssertTrue(st.isKnownPlayer("sonista"))
    }

    /// A retired pet leaves the attribution set and stays in `everPet`.
    func testSyncingPetNamesDropsTheRetiredAndKeepsTheHistory() {
        let st = EngineState()
        _ = st.world.claim("Jaber", 0)
        st.notePet("jaber")
        _ = st.world.claim("Gonekn", 1_000)
        st.notePet("gonekn")
        let dropped = st.syncPetNames()
        XCTAssertEqual(dropped, ["jaber"])
        XCTAssertFalse(st.petNames.contains("jaber"))
        XCTAssertTrue(st.everPet.contains("jaber"))
    }
}

// MARK: - collate.rs

final class CombatCollateTests: XCTestCase {
    /// A space is not ignorable, so it beats a letter.
    func testASpaceSortsBeforeALetter() {
        XCTAssertEqual(Collate.compareNames("a willowisp", "Asaka L`Rei"), .orderedAscending)
        XCTAssertEqual(Collate.compareNames("a b", "ab"), .orderedAscending)
    }

    /// The measured punctuation order — space before hyphen before backtick.
    func testTheMarksCarryTheMeasuredPrimaryOrder() {
        XCTAssertEqual(Collate.compareNames("a b", "a-b"), .orderedAscending)
        XCTAssertEqual(Collate.compareNames("a-b", "a`b"), .orderedAscending)
        XCTAssertEqual(Collate.compareNames("a1", "ab"), .orderedAscending)
    }

    /// Case is tertiary: it decides nothing until every primary weight ties, and then lowercase wins.
    func testCaseIsDecidedLastAndLowercaseWins() {
        XCTAssertEqual(Collate.compareNames("a", "A"), .orderedAscending)
        XCTAssertEqual(Collate.compareNames("Melee", "melee"), .orderedDescending)
        // `aB` before `Ab`: the primaries tie, and the tertiary run compares position 0 first.
        XCTAssertEqual(Collate.compareNames("aB", "Ab"), .orderedAscending)
        // …but a primary difference at position 1 outranks any case difference at position 0.
        XCTAssertEqual(Collate.compareNames("Ab", "aa"), .orderedDescending)
    }

    /// A total order: equal names compare equal, and nothing else does.
    func testIdenticalNamesCompareEqual() {
        XCTAssertEqual(Collate.compareNames("Rune", "Rune"), .orderedSame)
        XCTAssertNotEqual(Collate.compareNames("Rune", "Rune "), .orderedSame)
    }
}

// MARK: - aggregate.rs

final class CombatAggregateTests: XCTestCase {
    private func hit(_ skill: String, _ amount: Int64, _ crit: Bool) -> DamageEvent {
        DamageEvent(ts: 0, attacker: "You", target: "a bat", amount: amount, dtype: "melee",
                    dclass: nil, skill: skill, crit: crit, category: "melee", modifiers: [],
                    verb: nil)
    }

    private func you() -> SourceRef { SourceRef(id: "you", name: "You", kind: .you) }

    /// The per-lane minimum uses 0 as "nothing landed yet".
    func testTheLaneMinimumTreatsZeroAsNoLandedHitYet() {
        let a = Agg()
        a.addOut(you(), hit("Melee", 30, false), false)
        a.addOut(you(), hit("Melee", 12, false), false)
        let s = a.out["you"]!
        XCTAssertEqual(s.bySkill["Melee"]!.min, 12)
        XCTAssertEqual(s.bySkill["Melee"]!.max, 30)
    }

    /// A miss creates a row, which is why the drop rule reads map size and not a total.
    func testAnEncounterOfPureMissesIsNotEmpty() {
        let a = Agg()
        XCTAssertTrue(a.isEmpty)
        a.addOutMiss(you(), MissFold(mtype: .dodge, skill: "Melee", verb: nil, laneSkill: nil,
                                     modifiers: [], target: "a bat", ts: 0))
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(Agg.sum(a.out), 0)
        let s = a.out["you"]!
        XCTAssertEqual(s.misses, 1)
        XCTAssertEqual(s.miss[MissType.dodge.rawValue], 1)
    }

    /// A resist moves no damage total and still opens the lane it was resisted on.
    func testAResistOpensALaneAndMovesNoTotal() {
        let a = Agg()
        a.addOut(you(), hit("Melee", 30, false), false)
        a.addOutResist(you(), "Cajoling Whispers", "spell")
        let s = a.out["you"]!
        XCTAssertEqual(s.total, 30)
        XCTAssertEqual(s.resists, 1)
        XCTAssertEqual(s.bySkill["Cajoling Whispers"]!.hits, 0)
        XCTAssertEqual(s.bySkill["Cajoling Whispers"]!.resists, 1)
    }

    /// The one legal kind transition is `other` → `member`, and it is one-way.
    func testARecordedRowUpgradesToMemberAndNeverBack() {
        let a = Agg()
        let other = SourceRef(id: "member:dranix", name: "Dranix", kind: .other)
        let member = SourceRef(id: "member:dranix", name: "Dranix", kind: .member)
        a.addOut(other, hit("Melee", 10, false), false)
        XCTAssertEqual(a.out["member:dranix"]!.kind, .other)
        a.addOut(member, hit("Melee", 10, false), false)
        XCTAssertEqual(a.out["member:dranix"]!.kind, .member)
        a.addOut(other, hit("Melee", 10, false), false)
        XCTAssertEqual(a.out["member:dranix"]!.kind, .member)
        // …and the whole time it is one row, one id, one total.
        XCTAssertEqual(a.out.count, 1)
        XCTAssertEqual(Agg.sum(a.out), 30)
    }

    /// `incHeal` is the one named-total map that counts as well as sums.
    func testOnlyTheIncomingHealLedgerCountsItsLines() {
        let a = Agg()
        a.addIncHeal("dranix", "Dranix", 100)
        a.addIncHeal("dranix", "Dranix", 50)
        a.addEnemyHeal("a bat#1", "a bat", 20)
        XCTAssertEqual(a.incHeal["dranix"]!.count, 2)
        XCTAssertEqual(a.incHeal["dranix"]!.amount, 150)
        XCTAssertEqual(a.enemyHeal["a bat#1"]!.count, 0)
        XCTAssertEqual(Agg.sumHeal(a.enemyHeal), 20)
    }
}

// MARK: - spellfacts.rs

final class CombatSpellFactsTests: XCTestCase {
    /// The arm window tracks the spell's own cast time; a flat window would miss most real charms.
    func testTheArmWindowIsTheSpellsOwnCastTimePlusTheSlack() {
        XCTAssertEqual(armWindowMs("Charm"), 2_400 + CAST_SLACK_MS)
        XCTAssertEqual(armWindowMs("Cajoling Whispers III"), 5_500 + CAST_SLACK_MS)
        // A name the DB has no cast time for gets the most generous honest window.
        XCTAssertEqual(armWindowMs("Not A Spell At All"), DEFAULT_CAST_MS + CAST_SLACK_MS)
    }

    /// The bard's charm can never be what a charm broadcast resolved.
    func testTheBardsCharmIsACharmButNotABroadcastCharm() {
        XCTAssertTrue(isCharmSpell("Solon's Bewitching Bravura"))
        XCTAssertFalse(isCharmBroadcastSpell("Solon's Bewitching Bravura"))
        XCTAssertTrue(isCharmBroadcastSpell("Allure"))
        XCTAssertTrue(isCharmBroadcastSpell("Cajoling Whispers"))
    }

    /// Charm wins the overlap — `Boltran's Agacerie` is a charm and must never read as a mez.
    func testCharmWinsTheCcOverlap() {
        XCTAssertTrue(isCcSpell("Mesmerization VI"))
        XCTAssertFalse(isCcSpell("Boltran's Agacerie"))
        XCTAssertFalse(isCcSpell("Charm"))
    }

    func testThePetOnlyAndPetSummonRostersAnswerTheirOwnFamilies() {
        XCTAssertTrue(isPetOnlySpell("Burnout III"))
        XCTAssertFalse(isPetOnlySpell("Charm"))
        XCTAssertTrue(isPetSummonSpell("Kintaz's Animation"))
        XCTAssertFalse(isPetSummonSpell("Burnout III"))
    }

    /// A single capitalized word passes; every article-led mob name is refused.
    func testThePlayerShapeRefusesEveryArticleLedName() {
        XCTAssertTrue(isPlayerShapedName("Scooba"))
        XCTAssertTrue(isPlayerShapedName("T`Kail"))
        XCTAssertFalse(isPlayerShapedName("a fire giant warrior"))
        XCTAssertFalse(isPlayerShapedName("A fire giant warrior"))
        XCTAssertFalse(isPlayerShapedName("The Hand of Veeshan"))
        XCTAssertFalse(isPlayerShapedName(""))
    }
}

// MARK: - routing.rs

final class CombatRoutingTests: XCTestCase {
    private func dmg(_ attacker: String, _ target: String, _ amount: Int64, _ ts: Int64) -> DamageEvent {
        DamageEvent(ts: ts, attacker: attacker, target: target, amount: amount, dtype: "melee",
                    dclass: nil, skill: "Melee", crit: false, category: "melee", modifiers: [],
                    verb: "slash")
    }

    private func stWithPet(_ pet: String) -> EngineState {
        let st = EngineState()
        st.setPlayerName("Primitive")
        _ = st.world.claim(pet, 0)
        st.notePet(Names.idKey(pet))
        return st
    }

    /// You → a pet name is outgoing to a hostile twin, never dropped as friendly fire.
    func testYouHittingAPetNameIsOutgoing() {
        let st = stWithPet("a fire giant warrior")
        XCTAssertEqual(classify(st, "You", "a fire giant warrior"), .outYou)
    }

    /// A pet hitting a same-named target is the pet's, and ambiguous.
    func testASameNamedPetHitIsThePetsAndFlagged() {
        let st = stWithPet("a fire giant warrior")
        XCTAssertEqual(classify(st, "a fire giant warrior", "a fire giant warrior"),
                       .outPet(petKey: "a fire giant warrior", petName: "a fire giant warrior",
                               ambiguous: true))
    }

    /// A pet swinging at a known player is not our fight.
    func testAPetSwingingAtAPlayerIsIgnored() {
        let st = stWithPet("Vebarn")
        st.notePlayer("scooba")
        XCTAssertEqual(classify(st, "Vebarn", "Scooba"), .ignore)
        XCTAssertEqual(classify(st, "Vebarn", "a rock golem"),
                       .outPet(petKey: "vebarn", petName: "Vebarn", ambiguous: false))
    }

    /// A landed hit opens a fight, engages the target, names the fight and moves BOTH aggregates.
    func testOneLandedHitOpensEngagesAndBooks() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        route(st, dmg("You", "a spite golem", 42, 1_000))
        let enc = st.current!
        XCTAssertEqual(enc.id, "e1")
        XCTAssertEqual(enc.startTs, 1_000)
        XCTAssertTrue(enc.engaged.contains("a spite golem#1"))
        XCTAssertEqual(enc.lastOutTarget, "a spite golem")
        XCTAssertEqual(Agg.sum(enc.agg.out), 42)
        XCTAssertEqual(Agg.sum(st.zoneAgg.out), 42)
        XCTAssertEqual(st.zoneStartTs, 1_000)
        // …and your own swing is the one signal that files a mob.
        XCTAssertTrue(st.everStruck.contains("a spite golem"))
    }

    /// Active time is the capped gap: the first hit adds nothing and a long lull adds at most one
    /// tick.
    func testActiveTimeCapsTheGapBetweenHits() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        route(st, dmg("You", "a bat", 10, 0))
        XCTAssertEqual(st.current!.activeMs, 0)
        route(st, dmg("You", "a bat", 10, 1_000))
        XCTAssertEqual(st.current!.activeMs, 1_000)
        route(st, dmg("You", "a bat", 10, 20_000))
        XCTAssertEqual(st.current!.activeMs, 1_000 + ACTIVE_MS)
    }

    /// A group member never engages, but their target does.
    func testAMembersTargetEngagesAndTheMemberNeverDoes() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        st.roster.admitted.insert("dranix")
        st.roster.members.insert("dranix")
        route(st, dmg("Dranix", "a spite golem", 30, 1_000))
        let enc = st.current!
        XCTAssertTrue(enc.engaged.contains("a spite golem#1"))
        XCTAssertFalse(enc.engaged.contains { $0.hasPrefix("dranix") })
        // …and the row is the member's own, keyed by name.
        XCTAssertTrue(enc.agg.out.containsKey("member:dranix"))
    }

    /// A mob-vs-mob line neither of your models claims is recorded under its own row — and that row
    /// engages nothing and opens nothing.
    func testAStrangerFightingAMobGetsARowAndNothingElse() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        // No fight is open, so the line books to the zone lane and nowhere else.
        route(st, dmg("Scooba", "a spite golem", 25, 1_000))
        XCTAssertNil(st.current, "an 'other' row may not open a fight")
        XCTAssertTrue(st.zoneAgg.out.containsKey("member:scooba"))
        XCTAssertEqual(Agg.sum(st.zoneAgg.out), 25)
        // …and the target ledger is untouched.
        XCTAssertTrue(st.zoneAgg.targets.isEmpty)
    }

    /// An article-named mob is never recorded as a combatant of its own — the shape gate.
    func testMobVersusMobBetweenTwoArticleNamesStaysDropped() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        route(st, dmg("a fire giant warrior", "a spite golem", 25, 1_000))
        XCTAssertTrue(st.zoneAgg.out.isEmpty)
    }

    /// Something you have been killing is never recorded as a person either.
    func testAProperNamedMobYouHaveStruckNeverEarnsItsOwnRow() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        route(st, dmg("You", "Drelzna", 40, 1_000))
        route(st, dmg("Drelzna", "a spite golem", 25, 2_000))
        XCTAssertFalse(st.zoneAgg.out.containsKey("member:drelzna"))
    }

    /// A heal on an engaged hostile is enemy healing and refreshes its presence; one on a mob we have
    /// never touched is neither.
    func testEnemyHealingNeedsTheTargetToBeEngaged() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        route(st, dmg("You", "a spite golem", 40, 1_000))
        routeHeal(st, HealLine(ts: 2_000, target: "a spite golem", healer: "a spite golem",
                               amount: 15, rawAmount: nil, spell: nil, crit: false))
        let enc = st.current!
        XCTAssertEqual(Agg.sumHeal(enc.agg.enemyHeal), 15)
        XCTAssertEqual(enc.engagedSeen["a spite golem#1"], 2_000)

        routeHeal(st, HealLine(ts: 3_000, target: "a bat", healer: "a bat", amount: 15,
                               rawAmount: nil, spell: nil, crit: false))
        XCTAssertEqual(Agg.sumHeal(st.current!.agg.enemyHeal), 15)
    }

    /// A miss neither opens nor extends a fight, and it still counts toward the zone lane.
    func testAMissNeverOpensAFight() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        routeMiss(st, MissLine(ts: 1_000, attacker: "You", target: "a spite golem", mtype: .dodge,
                               verb: "slash", verbSkill: "Melee", modifiers: []))
        XCTAssertNil(st.current)
        XCTAssertEqual(st.zoneAgg.out["you"]!.misses, 1)
    }

    /// The special-attack lane renames a miss's ROUND lane and never its aggregation lane, and only
    /// for your swings — the state line is first-person-only.
    func testTheSpecialLaneRenamesOnlyYourRoundLane() {
        let st = EngineState()
        st.setPlayerName("Primitive")
        _ = st.specials.note("Dragon Punch")
        let line = MissLine(ts: 1_000, attacker: "You", target: "a spite golem", mtype: .miss,
                            verb: "strike", verbSkill: "Strike", modifiers: [])
        let mine = missFold(st, line, true)
        XCTAssertEqual(mine.skill, "Melee")
        XCTAssertEqual(mine.laneSkill, "Dragon Punch")
        let theirs = missFold(st, line, false)
        XCTAssertEqual(theirs.laneSkill, "Strike")
    }
}

// MARK: - mod.rs (the engine's own surface)

final class CombatEngineTests: XCTestCase {
    private func fold(_ lines: [String]) -> CombatEngine {
        let e = CombatEngine()
        e.setPlayerName("Primitive")
        for line in lines {
            let ev = Event.fromJSON(line)!
            e.onEvent(ev, live: false, roster: nil)
        }
        return e
    }

    /// The same fold, then the handover the tail makes.
    private func foldThenGoLive(_ lines: [String]) -> CombatEngine {
        let e = fold(lines)
        e.setLive()
        return e
    }

    /// One outgoing hit, as the parser emits it.
    private func hit(_ seq: Int64, _ ts: Int64, _ amount: Int64) -> String {
        "{\"kind\":\"damage\",\"seq\":\(seq),\"ts\":\(ts),\"raw\":\"d\",\"attacker\":\"You\",\"target\":\"a kodiak\",\"amount\":\(amount),\"dtype\":\"spell\",\"skill\":\"Smiting Strike\",\"crit\":false}"
    }

    private let zoneNajena = "{\"kind\":\"zone\",\"seq\":0,\"ts\":0,\"raw\":\"z\",\"zone\":\"Najena\"}"

    /// A historical fold never leaves hydration, and the whole snapshot-time sweep block hangs off
    /// that one flag.
    func testAHistoricalFoldStaysHydratingAndRecordsNoLines() {
        let e = fold(["{\"kind\":\"zone\",\"seq\":0,\"ts\":10,\"raw\":\"z\",\"zone\":\"Innothule Swamp\"}"])
        let snap = e.snapshot(now: 10, opts: .full(), roster: nil)
        XCTAssertEqual(snap["hydrating"], .bool(true))
        XCTAssertEqual(snap["recent"], .array([]))
    }

    /// …and the handover is the only thing that changes it.
    func testHydratingIsTrueUntilTheHandoverAndFalseAfterIt() {
        let lines = ["{\"kind\":\"zone\",\"seq\":0,\"ts\":10,\"raw\":\"z\",\"zone\":\"Najena\"}"]
        var e = fold(lines)
        XCTAssertTrue(e.hydrating)
        XCTAssertEqual(e.snapshot(now: 10, opts: .full(), roster: nil)["hydrating"], .bool(true))

        e.setLive()
        XCTAssertFalse(e.hydrating)
        XCTAssertEqual(e.snapshot(now: 10, opts: .full(), roster: nil)["hydrating"], .bool(false))

        // …and the fallback path, with no `setLive()` at all: one event the tail delivered says the
        // same thing, before the rest of that event is folded.
        e = fold(lines)
        e.onEvent(Event.fromJSON(hit(1, 1_000, 10))!, live: true, roster: nil)
        XCTAssertFalse(e.hydrating, "a live event is a live world")
    }

    /// A live fight closes on elapsed time at the snapshot.
    func testALiveSnapshotClosesAFightTheLogStoppedTalkingAbout() {
        let e = foldThenGoLive([zoneNajena, hit(1, 1_000, 500)])
        let now = 1_000 + PRESENCE_GONE_MS
        let snap = e.snapshot(now: now, opts: .full(), roster: nil)
        XCTAssertEqual(snap["segments"][0]["kind"].string, "fight")
        XCTAssertEqual(snap["inCombat"], .bool(false))
        // Finalized at the fight's own clock, never at `now`.
        XCTAssertEqual(snap["segments"][0]["startTs"].int64, 1_000)
        XCTAssertEqual(snap["segments"][0]["durationSec"].double, 1.0)
        XCTAssertEqual(snap["segments"][0]["active"], .bool(false))
        XCTAssertEqual(snap["segments"][0]["total"].int64, 500)
        XCTAssertNil(snap.object?["currentTarget"], "a fight that just closed reports no target")
    }

    /// …and a mid-fold snapshot never does any of that.
    func testAMidFoldSnapshotSweepsNothingAndCannotSplitAFight() {
        let e = fold([zoneNajena, hit(1, 1_000, 43_504)])
        // The host clock, weeks past every timestamp in the log.
        let snap = e.snapshot(now: 1_800_000_000_000, opts: .full(), roster: nil)
        XCTAssertEqual(snap["segments"][0]["kind"].string, "current")

        e.onEvent(Event.fromJSON(hit(2, 2_000, 10_073))!, live: false, roster: nil)
        let after = e.snapshot(now: 2_000, opts: .full(), roster: nil)
        XCTAssertEqual(after["segments"][0]["total"].int64, 53_577, "the poll split the fight")
        XCTAssertEqual((after["segments"].array ?? []).filter { $0["kind"] != .string("zone") }.count,
                       1, "one fight, not two")
    }

    /// An uncorroborated charm bind expires at the snapshot.
    func testALiveSnapshotSweepsACharmBindWhoseWindowClosed() {
        let lines = ["{\"kind\":\"castBegin\",\"seq\":0,\"ts\":0,\"raw\":\"c\",\"spell\":\"Charm\"}",
                     "{\"kind\":\"charm\",\"seq\":1,\"ts\":1000,\"raw\":\"c\",\"mob\":\"a rock golem\"}"]
        let horizon = 1_000 + provisionalWindowMs("Charm")

        var e = foldThenGoLive(lines)
        XCTAssertTrue(e.st.petNames.contains("a rock golem"),
                      "the broadcast resolved our own cast, so it bound")
        _ = e.snapshot(now: horizon - 1, opts: .full(), roster: nil)
        XCTAssertTrue(e.st.petNames.contains("a rock golem"), "one ms early is early")
        _ = e.snapshot(now: horizon, opts: .full(), roster: nil)
        XCTAssertFalse(e.st.petNames.contains("a rock golem"),
                       "the corroboration window closed and the bind is gone")

        // …and the replay is untouched however late the poll.
        e = fold(lines)
        _ = e.snapshot(now: horizon + 1_000_000, opts: .full(), roster: nil)
        XCTAssertTrue(e.st.petNames.contains("a rock golem"))
    }

    /// The pet nudge is live-only, and this pins the gate rather than the model.
    func testThePetNudgeArmsOnlyOnceTheTailIsRunning() {
        let summon = "{\"kind\":\"castBegin\",\"seq\":0,\"ts\":1000,\"raw\":\"c\",\"spell\":\"Kintaz's Animation\"}"

        var e = fold([])
        e.setLive()
        e.onEvent(Event.fromJSON(summon)!, live: false, roster: nil)
        let shown = 1_000 + NUDGE_GRACE_MS
        XCTAssertEqual(e.snapshot(now: shown, opts: .full(), roster: nil)["petNudge"],
                       ["summonedTs": .int(1_000),
                        "expiresTs": .int(1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS)])
        // Absent, never null, in every state but the one.
        XCTAssertNil(e.snapshot(now: 1_000, opts: .full(), roster: nil).object?["petNudge"])
        let gone = 1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS
        XCTAssertNil(e.snapshot(now: gone, opts: .full(), roster: nil).object?["petNudge"])

        // A historical fold arms nothing.
        e = fold([summon])
        XCTAssertNil(e.snapshot(now: shown, opts: .full(), roster: nil).object?["petNudge"])
    }

    /// `zone` is absent — never null — until the first `You have entered X.` line.
    func testTheZoneIsAbsentUntilAZoneLineNamesOne() {
        var e = fold(["{\"kind\":\"unknown\",\"seq\":0,\"ts\":1,\"raw\":\"x\"}"])
        var snap = e.snapshot(now: 1, opts: .full(), roster: nil)
        XCTAssertNil(snap.object?["zone"])
        XCTAssertEqual(snap["zoneSessions"][0]["zone"].string, "Session")

        e = fold(["{\"kind\":\"zone\",\"seq\":0,\"ts\":10,\"raw\":\"z\",\"zone\":\"Najena\"}"])
        snap = e.snapshot(now: 10, opts: .full(), roster: nil)
        XCTAssertEqual(snap["zone"].string, "Najena")
        XCTAssertEqual(snap["segments"][0]["name"].string, "Najena - overall")
    }

    /// Re-asserting the stance you are already in moves nothing.
    func testReAssertingTheSameStanceDoesNotMoveItsTimestamp() {
        let e = fold([
            "{\"kind\":\"stanceChange\",\"seq\":0,\"ts\":1000,\"raw\":\"s\",\"stance\":\"offensive\"}",
            "{\"kind\":\"stanceChange\",\"seq\":1,\"ts\":2000,\"raw\":\"s\",\"stance\":\"offensive\"}",
            "{\"kind\":\"invocationChange\",\"seq\":2,\"ts\":3000,\"raw\":\"i\",\"invocation\":\"inversion\"}",
            "{\"kind\":\"stanceChange\",\"seq\":3,\"ts\":4000,\"raw\":\"s\",\"stance\":\"defensive\"}",
        ])
        let snap = e.snapshot(now: 4000, opts: .full(), roster: nil)
        XCTAssertEqual(snap["stance"], ["stance": "defensive", "stanceTs": 4000,
                                        "invocation": "inversion", "invocationTs": 3000])
    }

    /// The stance pair is session-scoped: it survives a zone line.
    func testTheStandingChoicesSurviveAZoneLine() {
        let e = fold([
            "{\"kind\":\"stanceChange\",\"seq\":0,\"ts\":1000,\"raw\":\"s\",\"stance\":\"offensive\"}",
            "{\"kind\":\"zone\",\"seq\":1,\"ts\":2000,\"raw\":\"z\",\"zone\":\"The Plane of Sky\"}",
        ])
        let snap = e.snapshot(now: 2000, opts: .full(), roster: nil)
        XCTAssertEqual(snap["stance"]["stance"].string, "offensive")
        XCTAssertEqual(snap["stance"]["stanceTs"].int64, 1000)
    }

    /// The live stay's floor: a stay with no finalized encounter behind it spans one second.
    func testAnUnstartedStayReportsAOneSecondSpan() {
        let e = fold(["{\"kind\":\"zone\",\"seq\":0,\"ts\":10,\"raw\":\"z\",\"zone\":\"Najena\"}"])
        let snap = e.snapshot(now: 10, opts: .full(), roster: nil)
        XCTAssertEqual(snap["segments"][0]["durationSec"].double, 1.0)
        XCTAssertEqual(snap["segments"][0]["dps"].double, 0.0)
        XCTAssertEqual(snap["zoneSessions"].array?.count, 1)
        XCTAssertEqual(snap["zoneSessions"][0]["live"], .bool(true))
        // Absent on the live entry, which has not ended at all.
        XCTAssertNil(snap["zoneSessions"][0].object?["closedBy"])
    }

    /// With no landed sample every statistic is absent rather than 0.
    func testASlowRollupWithNoSamplesStatesNoStatistics() {
        let e = fold([])
        let snap = e.snapshot(now: 0, opts: .full(), roster: nil)
        XCTAssertEqual(snap["poison"]["slow"],
                       ["pulls": 0, "landed": 0, "noLand": 0, "window": 25])
    }

    /// The walk visits every zone session and every finalized fight, zone sessions first.
    func testTheScopeWalkCoversTheZoneSessionsAndSkipsTheZoneSegment() {
        let e = fold(["{\"kind\":\"zone\",\"seq\":0,\"ts\":10,\"raw\":\"z\",\"zone\":\"Najena\"}"])
        let scopes = e.walkScopes(now: 10, roster: nil)
        XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes[0]["kind"].string, "zoneSession")
        XCTAssertEqual(scopes[0]["id"].string, "zone")
    }

    /// Every classified line a snapshot carries, as `<role>|<cat>|<text>`.
    private func lines(_ snap: JSONValue) -> [String] {
        (snap["recent"].array ?? []).map {
            "\($0["role"].string ?? "")|\($0["cat"].string ?? "")|\($0["text"].string ?? "")"
        }
    }

    /// A historical fold writes nothing: the gate is `recording`.
    func testAReplayLeavesTheClassificationRingEmpty() {
        let e = fold([zoneNajena, hit(1, 1_000, 500)])
        XCTAssertEqual(e.snapshot(now: 1_000, opts: .full(), roster: nil)["recent"], .array([]))
    }

    /// …and a live one carries real rows. Every line here is the app's own sentence, verbatim.
    func testALiveFoldClassifiesTheLinesItFolds() {
        let e = CombatEngine()
        e.setPlayerName("Primitive")
        e.setLive()
        for line in [
            zoneNajena,
            hit(1, 1_000, 500),
            "{\"kind\":\"damage\",\"seq\":2,\"ts\":1500,\"raw\":\"d\",\"attacker\":\"a kodiak\",\"target\":\"You\",\"amount\":42,\"dtype\":\"melee\",\"skill\":\"bite\",\"crit\":false}",
            "{\"kind\":\"stanceChange\",\"seq\":3,\"ts\":1600,\"raw\":\"s\",\"stance\":\"offensive\"}",
            "{\"kind\":\"death\",\"seq\":4,\"ts\":2000,\"raw\":\"d\",\"name\":\"a kodiak\",\"bySelf\":true}",
        ] {
            e.onEvent(Event.fromJSON(line)!, live: true, roster: nil)
        }
        let ls = lines(e.snapshot(now: 2_000, opts: .full(), roster: nil))
        XCTAssertTrue(ls.contains("info|zone|▸ entered Najena"), "\(ls)")
        // The lane name is the routed one, `· proc` marker and all.
        XCTAssertTrue(ls.contains("you|spell|You → a kodiak  500  Smiting Strike · proc"), "\(ls)")
        XCTAssertTrue(ls.contains("enemy|melee|a kodiak → You  42  bite"), "\(ls)")
        XCTAssertTrue(ls.contains("info|stance|▸ stance: offensive"), "\(ls)")
        // A death names why the world resolved it the way it did.
        XCTAssertTrue(ls.contains("info|death|☠ a kodiak died - plain hostile death"), "\(ls)")
        // The order is the fold's: newest last.
        let zone = ls.firstIndex { $0.contains("entered Najena") }
        let death = ls.firstIndex { $0.contains("died") }
        XCTAssertNotNil(zone); XCTAssertNotNil(death)
        XCTAssertLessThan(zone!, death!, "\(ls)")
    }

    /// A crit is a star and an ambiguous hit is a tilde.
    func testACritIsMarkedAndARefusalIsSaidOutLoud() {
        let e = CombatEngine()
        e.setPlayerName("Primitive")
        e.setLive()
        for line in [
            zoneNajena,
            "{\"kind\":\"damage\",\"seq\":1,\"ts\":1000,\"raw\":\"d\",\"attacker\":\"You\",\"target\":\"a kodiak\",\"amount\":900,\"dtype\":\"spell\",\"skill\":\"Smiting Strike\",\"crit\":true}",
            // A caster-less other-player DoT: not our fight, and the raw line is what the ring keeps.
            "{\"kind\":\"damage\",\"seq\":2,\"ts\":1200,\"raw\":\"Somebody's tick hits a kodiak for 9 points of damage.\",\"target\":\"a kodiak\",\"amount\":9,\"dtype\":\"dot\",\"skill\":\"tick\",\"crit\":false}",
        ] {
            e.onEvent(Event.fromJSON(line)!, live: true, roster: nil)
        }
        let ls = lines(e.snapshot(now: 1_200, opts: .full(), roster: nil))
        XCTAssertTrue(ls.contains("you|spell|You → a kodiak  900*  Smiting Strike · proc"), "\(ls)")
        XCTAssertTrue(ls.contains("dropped|other|Somebody's tick hits a kodiak for 9 points of damage."), "\(ls)")
    }

    /// The ring is bounded drop-oldest, and a snapshot carries at most the newest 150.
    func testTheRingIsBoundedAndThePayloadIsBoundedTighter() {
        let e = CombatEngine()
        e.setPlayerName("Primitive")
        e.setLive()
        for seq in 0..<Int64(RECENT_CAP + 50) {
            e.onEvent(Event.fromJSON(hit(seq, 1_000 + seq * 10, 1))!, live: true, roster: nil)
        }
        let snap = e.snapshot(now: 9_999_999, opts: .full(), roster: nil)
        XCTAssertEqual(snap["recent"].array?.count, RECENT_VIEW)
    }

    /// `showUnparsed` filters before it slices, and the order is not interchangeable.
    func testTheUnparsedFilterRunsBeforeTheCap() {
        let e = CombatEngine()
        e.setPlayerName("Primitive")
        e.setLive()
        e.onEvent(Event.fromJSON(zoneNajena)!, live: true, roster: nil)
        // `unparsed` is not a category this fold emits, so both answers agree.
        let with = e.snapshot(now: 0, opts: .full(), roster: nil)
        var opts = SnapshotOpts.full()
        opts.showUnparsed = false
        let without = e.snapshot(now: 0, opts: opts, roster: nil)
        XCTAssertEqual(with["recent"], without["recent"])
        XCTAssertEqual(lines(with).count, 1)
    }

    /// A mark mid-live splits the accounting and leaves the room alone.
    func testAMarkMidLiveSplitsTheStayAndKeepsTheRoom() {
        let e = foldThenGoLive([zoneNajena, hit(1, 1_000, 500)])
        XCTAssertTrue(e.sessionMark(2_000), "a live engine takes the mark")

        e.onEvent(Event.fromJSON(hit(2, 3_000, 70))!, live: true, roster: nil)
        let snap = e.snapshot(now: 3_000, opts: .full(), roster: nil)

        // The room did not change.
        XCTAssertEqual(snap["zone"].string, "Najena")
        XCTAssertEqual(snap["zoneSessions"][0]["zone"].string, "Najena")
        XCTAssertEqual(snap["zoneSessions"][0]["live"], .bool(true))
        // …and it accounts only for what happened after the press.
        XCTAssertEqual(snap["zoneSessions"][0]["total"].int64, 70)
        // The frozen record behind it is the pre-mark half, tagged by what closed it.
        XCTAssertEqual(snap["zoneSessions"][1]["closedBy"].string, "mark")
        XCTAssertEqual(snap["zoneSessions"][1]["total"].int64, 500)
        XCTAssertEqual(snap["zoneSessions"][1]["zone"].string, "Najena")
    }

    /// The open fight is closed by the press.
    func testAMarkClosesTheOpenFight() {
        let e = foldThenGoLive([zoneNajena, hit(1, 1_000, 500)])
        XCTAssertEqual(e.snapshot(now: 1_000, opts: .full(), roster: nil)["segments"][0]["kind"].string,
                       "current", "the fight is open before the press")
        e.sessionMark(2_000)
        e.onEvent(Event.fromJSON(hit(2, 3_000, 70))!, live: true, roster: nil)
        let snap = e.snapshot(now: 3_000, opts: .full(), roster: nil)
        // The open fight is the post-mark one: the 500 is behind the boundary.
        XCTAssertEqual(snap["segments"][0]["kind"].string, "current")
        XCTAssertEqual(snap["segments"][0]["total"].int64, 70)
    }

    /// Refused while hydrating, and the refusal changes nothing at all.
    func testAMarkIsRefusedWhileHydratingAndMovesNothing() {
        let e = fold([zoneNajena, hit(1, 1_000, 500)])
        let before = e.snapshot(now: 1_000, opts: .full(), roster: nil)
        XCTAssertFalse(e.sessionMark(2_000), "a replaying engine refuses")
        let after = e.snapshot(now: 1_000, opts: .full(), roster: nil)
        XCTAssertEqual(before, after, "a refused mark is not a mark")
        XCTAssertEqual(after["zoneSessions"].array?.count, 1, "no record was minted")
    }

    /// An empty stay mints nothing, which is what makes a double-click harmless.
    func testASecondMarkWithNothingBetweenMintsNoRecord() {
        let e = foldThenGoLive([zoneNajena, hit(1, 1_000, 500)])
        e.sessionMark(2_000)
        e.sessionMark(2_000)
        let snap = e.snapshot(now: 2_000, opts: .full(), roster: nil)
        XCTAssertEqual(snap["zoneSessions"].array?.count, 2, "the live stay plus ONE frozen record")
        XCTAssertEqual(snap["zoneSessions"][1]["closedBy"].string, "mark")
    }

    /// The empty roster is what an engine with no roster module registered publishes.
    func testAnUnwiredRosterSeamPublishesTheEmptyRoster() {
        let e = fold([])
        let snap = e.snapshot(now: 0, opts: .full(), roster: nil)
        XCTAssertEqual(snap["roster"], ["members": .array([]), "seen": false, "lastSignalTs": 0])
    }
}
