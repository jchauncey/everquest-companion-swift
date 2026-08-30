// The Rust unit tests from the combat files this worker ported: encounter.rs, lifecycle.rs,
// world.rs, statetimeline.rs, petnudge.rs, charm.rs, ally.rs and others.rs.
import XCTest
@testable import EQFold
import EQLog
import EQCompanionCore

// MARK: - encounter.rs

final class CombatEncounterTests: XCTestCase {
    private func encWith(_ targets: [(String, Int64)]) -> Encounter {
        let e = Encounter(id: "e1", zone: nil, ts: 0)
        for (name, amount) in targets { e.agg.bumpTarget(name, name, amount) }
        return e
    }

    /// A fight with no target at all is `Combat`.
    func testAFightThatStruckNothingIsCalledCombat() {
        XCTAssertEqual(encounterName(Encounter(id: "e1", zone: nil, ts: 0), false), "Combat")
    }

    /// A finalized fight is named after the largest target and counts the others.
    func testAFinalizedFightIsNamedAfterTheLargestTarget() {
        let e = encWith([("a bat", 100), ("a spite golem", 500), ("a rat", 20)])
        XCTAssertEqual(encounterName(e, false), "a spite golem +2")
    }

    /// A tie keeps the order the targets were first struck in — the stable-sort property.
    func testATieIsBrokenByWhichTargetWasStruckFirst() {
        XCTAssertEqual(encounterName(encWith([("a bat", 100), ("a spite golem", 100)]), false), "a bat +1")
        XCTAssertEqual(encounterName(encWith([("a spite golem", 100), ("a bat", 100)]), false), "a spite golem +1")
    }

    /// A live fight is named after what you are swinging at, falling back to the largest target
    /// until something outgoing has landed.
    func testALiveFightIsNamedAfterTheCurrentTarget() {
        let e = encWith([("a bat", 100), ("a spite golem", 500)])
        XCTAssertEqual(encounterName(e, true), "a spite golem +1")
        e.lastOutTarget = "a bat"
        XCTAssertEqual(encounterName(e, true), "a bat +1")
        // …and the finalized name is unmoved by it.
        XCTAssertEqual(encounterName(e, false), "a spite golem +1")
    }
}

// MARK: - lifecycle.rs

func lifecycleHit(_ amount: Int64) -> DamageEvent {
    DamageEvent(ts: 0, attacker: "You", target: "a bat", amount: amount, dtype: "melee",
                dclass: nil, skill: "Melee", crit: false, category: "melee",
                modifiers: [], verb: nil)
}

func lifecycleYou() -> SourceRef { SourceRef(id: "you", name: "You", kind: .you) }

final class CombatLifecycleTests: XCTestCase {
    /// The one-second floor is the definition: a one-line fight's DPS is its total, not an infinity.
    func testAZeroSpanFightReportsItsTotalAsItsDps() {
        let e = Encounter(id: "e1", zone: nil, ts: 1_000)
        e.agg.addOut(lifecycleYou(), lifecycleHit(8_574), false)
        e.agg.bumpTarget("a bat#1", "a bat", 8_574)
        let s = encSummary(e, "fight", 0)
        XCTAssertEqual(s.durationSec, 1.0)
        XCTAssertEqual(s.dps, 8_574.0)
        XCTAssertEqual(s.activeDps, 8_574.0)
        XCTAssertEqual(s.activeSec, 0.0)
    }

    /// An empty encounter is dropped: a mez that landed on a mob somebody else killed leaves no
    /// 0-damage shell in the history.
    func testAnEncounterThatAccruedNothingIsDroppedAtFinalize() {
        let st = EngineState()
        ensureEncounter(st, 1_000)
        finalizeCurrent(st)
        XCTAssertTrue(st.history.isEmpty)
        XCTAssertEqual(st.zoneFinalizedMs, 0)
    }

    /// …and one that accrued anything at all is KEPT, with its wall span folded into the stay.
    func testAFightThatLandedAHitIsFrozenWithItsSpan() {
        let st = EngineState()
        ensureEncounter(st, 1_000)
        let enc = try! XCTUnwrap(st.current)
        enc.agg.addOut(lifecycleYou(), lifecycleHit(100), false)
        enc.lastTs = 5_000
        enc.activeMs = 2_000
        finalizeCurrent(st)
        XCTAssertEqual(st.history.count, 1)
        XCTAssertEqual(st.zoneFinalizedMs, 4_000)
        XCTAssertEqual(st.zoneActiveMs, 2_000)
        XCTAssertNotNil(st.history[0].summary)
    }

    /// The fallback is reachable through a hold: one unrefreshed mez may not pin a fight open past
    /// the idle window of total silence.
    func testAStaleCcHoldDoesNotDefeatTheIdleFallback() {
        let st = EngineState()
        ensureEncounter(st, 0)
        let enc = try! XCTUnwrap(st.current)
        enc.agg.addOut(lifecycleYou(), lifecycleHit(10), false)
        enc.engaged.insert("a bat#1")
        enc.ccActiveUntil.insert("a bat#1", 120_000)
        st.lastActivityTs = 0
        evalClosure(st, FALLBACK_IDLE_MS)
        XCTAssertNil(st.current, "the fallback must reach past the hold")
    }

    /// …and an unexpired hold does veto the death-close, which is the judgement it informs.
    func testALiveCcHoldVetoesTheDeathClose() {
        let st = EngineState()
        ensureEncounter(st, 0)
        let enc = try! XCTUnwrap(st.current)
        enc.agg.addOut(lifecycleYou(), lifecycleHit(10), false)
        enc.engaged.insert("a bat#1")
        enc.engagedSeen.insert("a bat#1", 0)
        enc.ccActiveUntil.insert("a bat#1", 120_000)
        st.lastActivityTs = 30_000
        // The mob is unseen past PRESENCE_GONE_MS and the linger has elapsed, so only the hold is
        // holding this open.
        evalClosure(st, 30_000)
        XCTAssertNotNil(st.current)
    }

    /// The live zone stay counts the OPEN fight's span, so a stay does not appear to stop while a
    /// fight is running.
    func testTheLiveStayIncludesTheOpenFightsSpan() {
        let st = EngineState()
        st.zoneFinalizedMs = 4_000
        ensureEncounter(st, 10_000)
        st.current?.lastTs = 16_000
        XCTAssertEqual(zoneDurationSec(st), 10.0)
    }

    /// The segment cap is a payload bound: the current fight is included regardless of it.
    func testTheCapNeverHidesTheOpenFight() {
        let st = EngineState()
        for _ in 0..<3 {
            ensureEncounter(st, 0)
            st.current?.agg.addOut(lifecycleYou(), lifecycleHit(1), false)
            finalizeCurrent(st)
        }
        ensureEncounter(st, 1_000)
        let segs = collectSegments(st, 1_000, 1)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].kind, "current")
        XCTAssertEqual(segs[1].id, "e3")
    }
}

// MARK: - world.rs

final class CombatWorldTests: XCTestCase {
    func testASecondSpawnOfANameLabelsItselfAndTheFirstKeepsTheBareName() {
        let w = WorldModel()
        let a = w.resolve("a spite golem", 1_000, false)
        XCTAssertEqual(a.instanceId, "a spite golem#1")
        XCTAssertEqual(a.label, "a spite golem")
        // Only a fresh spawn mints a gen — a second sighting inside the staleness window is the
        // same mob.
        XCTAssertEqual(w.resolve("a spite golem", 2_000, false).instanceId, "a spite golem#1")
        // …and past it, the slot is retired and the sighting spawns gen 2, which now labels itself.
        let b = w.resolve("a spite golem", 2_000 + INSTANCE_STALE_MS, false)
        XCTAssertEqual(b.instanceId, "a spite golem#2")
        XCTAssertEqual(b.label, "a spite golem (2)")
    }

    /// EQ's sentence-capitalization can never overwrite the spawn's true lowercase-article name.
    func testSentenceCasingNeverOverwritesTheTrueName() {
        let w = WorldModel()
        // First sighting is sentence-initial, so the spawn takes it verbatim…
        XCTAssertEqual(w.resolve("A zol ghoul knight", 1, false).label, "A zol ghoul knight")
        // …the first mid-sentence sighting flips it to canonical…
        XCTAssertEqual(w.resolve("a zol ghoul knight", 2, false).label, "a zol ghoul knight")
        // …and pins it there.
        XCTAssertEqual(w.resolve("A zol ghoul knight", 3, false).label, "a zol ghoul knight")
    }

    /// A pet is exempt from staleness — it is bound by explicit evidence and may stand quiet for
    /// minutes; only death, uncharm and zone retire one.
    func testAPetNeverAgesOutButAHostileTwinDoes() {
        let w = WorldModel()
        let pet = w.charm("a fire giant warrior", 0)
        w.noteTwinEvidence("a fire giant warrior", 0)
        let late = 10 * INSTANCE_STALE_MS
        w.resolve("a fire giant warrior", late, false)
        XCTAssertTrue(w.isLivePet(pet.instanceId))
        // The silent twin was retired and the sighting spawned a fresh generation.
        XCTAssertTrue(w.isRetired("a fire giant warrior#2"))
    }

    /// The single-pet invariant: claiming a new summoned pet retires the one you had.
    func testANewSummonedPetRetiresThePriorOne() {
        let w = WorldModel()
        let first = w.claim("Jaber", 0)
        let second = w.claim("Gonekn", 1_000)
        XCTAssertTrue(w.isRetired(first.instanceId))
        XCTAssertTrue(w.isLivePet(second.instanceId))
        // A charmed pet is untouched — the two kinds co-exist.
        let charmed = w.charm("a rock golem", 2_000)
        w.claim("Vebarn", 3_000)
        XCTAssertTrue(w.isLivePet(charmed.instanceId))
    }

    /// A repeat tell from the SAME pet converges on one entity and never reaches the succession.
    func testRepeatClaimsFromOnePetAreIdempotent() {
        let w = WorldModel()
        let a = w.claim("Jaber", 0)
        let b = w.claim("Jaber", 5_000)
        XCTAssertEqual(a.instanceId, b.instanceId)
        XCTAssertFalse(w.isRetired(a.instanceId))
    }

    /// The bias is always away from the pet: a foreign killer with no twin spawns and retires a
    /// ghost slot rather than killing the pet.
    func testAForeignKillerWithNoTwinRetiresAGhostAndKeepsThePet() {
        let w = WorldModel()
        let pet = w.charm("a fire giant warrior", 0)
        let res = w.death("a fire giant warrior", 1_000, "a fire giant wizard")
        XCTAssertFalse(res.wasPet)
        XCTAssertTrue(res.ambiguous)
        XCTAssertTrue(w.isLivePet(pet.instanceId))
    }

    /// …and the one case where the pet really does die: the same-named killer with nothing else live.
    func testASameNamedDeathWithOnlyThePetLiveIsARealPetDeath() {
        let w = WorldModel()
        let pet = w.charm("a fire giant warrior", 0)
        let res = w.death("a fire giant warrior", 1_000, "a fire giant warrior")
        XCTAssertTrue(res.wasPet)
        XCTAssertTrue(res.ambiguous)
        XCTAssertTrue(w.isRetired(pet.instanceId))
    }

    /// Only a summoned pet walks through the door with you.
    func testAZoneKeepsTheSummonedPetAndLeavesEverythingElse() {
        let w = WorldModel()
        let charmed = w.charm("a rock golem", 0)
        let summoned = w.claim("Vebarn", 0)
        let mob = w.resolve("a spite golem", 0, false)
        let survivors = w.zone(1_000)
        XCTAssertEqual(survivors.count, 1)
        XCTAssertEqual(survivors[0].instanceId, summoned.instanceId)
        XCTAssertTrue(w.isRetired(charmed.instanceId))
        XCTAssertTrue(w.isRetired(mob.instanceId))
    }

    /// Every retirement path announces itself exactly once, through the one recorder.
    func testEveryRetirementIsAnnouncedOnce() {
        let w = WorldModel()
        w.resolve("a spite golem", 0, false)
        w.death("a spite golem", 10, nil)
        XCTAssertEqual(w.retiredIds, ["a spite golem#1"])
        w.retiredIds.removeAll()
        w.resolve("a bat", 0, false)
        w.zone(20)
        XCTAssertEqual(w.retiredIds, ["a bat#1"])
    }

    /// An id nothing ever spawned is retired, not live — it cannot be a live engagement.
    func testAnUnknownInstanceIdIsRetired() {
        let w = WorldModel()
        XCTAssertTrue(w.isRetired("nobody#1"))
        XCTAssertFalse(w.isLivePet("nobody#1"))
    }
}

// MARK: - statetimeline.rs

final class CombatStateTimelineTests: XCTestCase {
    private func open(_ kind: StateKind, _ key: String, _ ts: Int64, _ group: String?) -> OpenState {
        OpenState(kind: kind, key: key, name: key, ts: ts, group: group)
    }

    /// A replacing sibling ends the previous span as `inferred` — the game prints no stance end.
    func testANewCommitInfersTheEndOfTheOneItReplaced() {
        let t = StateTimeline()
        t.noteState(open(.stance, "offensive", 1_000, "stance"))
        t.noteState(open(.stance, "defensive", 2_000, "stance"))
        let spans = t.spansOverlapping(0, 9_999)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].endTs, 2_000)
        XCTAssertEqual(spans[0].endEvidence, .inferred)
        XCTAssertEqual(spans[1].endEvidence, .open)
        XCTAssertEqual(t.active.count, 1)
        XCTAssertTrue(t.active.contains("stance:defensive"))
    }

    /// Venoms on different lines stack — the groups coexist, and a family close reaches both.
    func testCoatLinesStackAndAFamilyDryClosesTheWholeStack() {
        let t = StateTimeline()
        t.noteState(open(.coat, "asp venom", 1_000, "coat:combat:asp"))
        t.noteState(open(.coat, "stunning venom", 1_100, "coat:combat:stunning"))
        XCTAssertEqual(t.active.count, 2)
        t.closeGroupPrefix("coat:combat:", 5_000, .inferred)
        XCTAssertTrue(t.active.isEmpty)
        for s in t.spansOverlapping(0, 9_999) {
            XCTAssertEqual(s.endEvidence, .inferred)
        }
    }

    /// A close with nothing open is a no-op, never a fabricated zero-width span.
    func testClosingAStateThatWasNeverOpenedInventsNothing() {
        let t = StateTimeline()
        t.closeState(.buff, "instrument of nife", 1_000, .observed)
        XCTAssertTrue(t.spansOverlapping(0, 9_999).isEmpty)
    }

    /// An open span overlaps any window that ends after it started; a closed one only its own span.
    func testOverlapTreatsAnOpenSpanAsUnbounded() {
        let t = StateTimeline()
        t.noteState(open(.buff, "nife", 1_000, nil))
        XCTAssertEqual(t.spansOverlapping(50_000, 60_000).count, 1)
        t.censorAll(2_000)
        XCTAssertTrue(t.spansOverlapping(50_000, 60_000).isEmpty)
        XCTAssertEqual(t.spansOverlapping(0, 1_500)[0].endEvidence, .censored)
    }
}

// MARK: - petnudge.rs

final class CombatPetNudgeTests: XCTestCase {
    /// The three windows, in order: nothing during the grace, the nudge during the show, nothing
    /// after the timeout. Every boundary is pinned because each is a deliberate `<` or `>=`.
    func testTheNudgeIsAbsentBeforeTheGraceAndAfterTheShow() {
        let n = PetNudgeState()
        n.noteSummonCast(1_000)
        XCTAssertNil(n.view(1_000), "nothing at the cast")
        XCTAssertNil(n.view(1_000 + NUDGE_GRACE_MS - 1), "nothing one ms before the grace closes")
        XCTAssertEqual(n.view(1_000 + NUDGE_GRACE_MS),
                       PetSummonNudge(summonedTs: 1_000,
                                      expiresTs: 1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS))
        XCTAssertNotNil(n.view(1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS - 1))
        XCTAssertNil(n.view(1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS),
                     "the expiry instant itself is off the screen")
    }

    /// A bind answers it and costs nothing: the arm clears, nothing was ignored, and the next summon
    /// may raise a nudge of its own.
    func testABindDismissesTheNudgeAndDoesNotStartTheQuietPeriod() {
        let n = PetNudgeState()
        n.noteSummonCast(1_000)
        n.noteBound()
        XCTAssertNil(n.view(1_000 + NUDGE_GRACE_MS))
        n.noteSummonCast(2_000)
        XCTAssertNotNil(n.view(2_000 + NUDGE_GRACE_MS), "a new question")
    }

    /// …and a nudge that TIMED OUT unheeded silences the next summon for NUDGE_QUIET_MS measured
    /// from the moment it left the screen, not from the cast that raised it.
    func testAnIgnoredNudgeSilencesTheNextSummonForTheQuietPeriod() {
        let n = PetNudgeState()
        n.noteSummonCast(1_000)
        let gone = 1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS
        n.sweep(gone)
        XCTAssertNil(n.view(gone))

        n.noteSummonCast(gone + NUDGE_QUIET_MS - 1)
        XCTAssertNil(n.view(gone + NUDGE_QUIET_MS - 1 + NUDGE_GRACE_MS),
                     "inside the quiet period nothing arms at all")
        n.noteSummonCast(gone + NUDGE_QUIET_MS)
        XCTAssertNotNil(n.view(gone + NUDGE_QUIET_MS + NUDGE_GRACE_MS))
    }

    /// One slot: a chain of summons is one question, so the second cast does not move the arm.
    func testChainSummoningDoesNotStackOrMoveTheArm() {
        let n = PetNudgeState()
        n.noteSummonCast(1_000)
        n.noteSummonCast(3_000)
        XCTAssertEqual(n.view(1_000 + NUDGE_GRACE_MS)?.summonedTs, 1_000)
    }

    /// A summon that fizzled summoned nothing, so there is no pet to nudge about.
    func testAFailedCastDisarmsIt() {
        let n = PetNudgeState()
        n.noteSummonCast(1_000)
        n.noteCastFailed()
        XCTAssertNil(n.view(1_000 + NUDGE_GRACE_MS))
    }

    /// A sweep inside the window changes nothing: only the deadline retires an arm.
    func testASweepBeforeTheDeadlineLeavesTheArmAlone() {
        let n = PetNudgeState()
        n.noteSummonCast(1_000)
        n.sweep(1_000 + NUDGE_GRACE_MS + NUDGE_SHOW_MS - 1)
        XCTAssertNotNil(n.view(1_000 + NUDGE_GRACE_MS))
    }
}

// MARK: - charm.rs

final class CombatCharmTests: XCTestCase {
    /// The arm window is the spell's own cast time: `Charm` is a 2400 ms cast, so a broadcast three
    /// seconds later is still ours and one at four is not.
    func testABroadcastBindsOnlyInsideTheSpellsOwnArmWindow() {
        let m = CharmModel()
        m.noteCastBegin("Charm", 0)
        XCTAssertEqual(m.charmBroadcast("a rock golem", "a rock golem", 3_000), .own)

        let m2 = CharmModel()
        m2.noteCastBegin("Charm", 0)
        XCTAssertEqual(m2.charmBroadcast("a rock golem", "a rock golem", 4_000), .foreign)
    }

    /// Charm consumes the arm (single-target); CC does not (one AE mez prints one line per mob).
    func testCharmConsumesTheArmAndCcDoesNot() {
        let m = CharmModel()
        m.noteCastBegin("Charm", 0)
        XCTAssertEqual(m.charmBroadcast("a", "a", 1_000), .own)
        XCTAssertEqual(m.charmBroadcast("b", "b", 1_000), .foreign)

        let m2 = CharmModel()
        m2.noteCastBegin("Mesmerization VI", 0)
        XCTAssertTrue(m2.ccBroadcast(1_000))
        XCTAssertTrue(m2.ccBroadcast(1_000))
    }

    /// A cast that resolved to nothing cannot be what a broadcast resolved, but only the ARMED spell
    /// disarms.
    func testOnlyTheArmedSpellsFailureDisarms() {
        let m = CharmModel()
        m.noteCastBegin("Charm", 0)
        m.noteCastFailed("Beguile", 500)
        XCTAssertEqual(m.charmBroadcast("a", "a", 1_000), .own)

        let m2 = CharmModel()
        m2.noteCastBegin("Charm", 0)
        m2.noteCastFailed("Charm", 500)
        XCTAssertEqual(m2.charmBroadcast("a", "a", 1_000), .foreign)
    }

    /// An unrelated cast clears a stale arm — you cast one spell at a time.
    func testAnUnrelatedCastClearsTheArm() {
        let m = CharmModel()
        m.noteCastBegin("Charm", 0)
        m.noteCastBegin("Minor Healing", 100)
        XCTAssertEqual(m.charmBroadcast("a", "a", 500), .foreign)
    }

    /// The demotion horizon is the spell's own duration, and evidence ends the wait early.
    func testAnUncorroboratedBindDemotesAtItsSpellsDurationAndEvidenceStopsIt() {
        let m = CharmModel()
        m.noteCastBegin("Charm", 0)
        m.charmBroadcast("a rock golem", "a rock golem", 1_000)
        let horizon = 1_000 + provisionalWindowMs("Charm")
        XCTAssertTrue(m.sweep(horizon - 1).isEmpty)
        let out = m.sweep(horizon)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].nameKey, "a rock golem")

        let m2 = CharmModel()
        m2.noteCastBegin("Charm", 0)
        m2.charmBroadcast("a rock golem", "a rock golem", 1_000)
        m2.notePetEvidence("a rock golem")
        XCTAssertTrue(m2.idle())
        XCTAssertTrue(m2.sweep(horizon + 1_000_000).isEmpty)
    }

    /// A foreign broadcast is remembered, and a later Master tell promotes it inside PROMOTE_MS.
    func testAForeignSightingIsPromotableByTheTellForTenMinutes() {
        let m = CharmModel()
        m.charmBroadcast("a rock golem", "a rock golem", 0)
        XCTAssertTrue(m.everCharmed("a rock golem"))
        XCTAssertFalse(m.claimIsCharmed("a rock golem", PROMOTE_MS + 1))

        let m2 = CharmModel()
        m2.charmBroadcast("a rock golem", "a rock golem", 0)
        XCTAssertTrue(m2.claimIsCharmed("a rock golem", PROMOTE_MS))
        // …and only once.
        XCTAssertFalse(m2.claimIsCharmed("a rock golem", PROMOTE_MS))
    }

    /// A zone keeps only the pets that walked through with you.
    func testAZoneKeepsOnlyTheSurvivors() {
        let m = CharmModel()
        m.notePetEvidence("vebarn")
        m.notePetEvidence("a rock golem")
        m.zone(["vebarn"])
        XCTAssertTrue(m.confirmed.contains("vebarn"))
        XCTAssertFalse(m.confirmed.contains("a rock golem"))
    }
}

// MARK: - ally.rs

final class CombatAllyTests: XCTestCase {
    private func cast(_ caster: String, _ key: String, _ spell: String, _ ts: Int64) -> AllyCastLine {
        AllyCastLine(caster: caster, casterKey: key, spell: spell, ts: ts, allowed: true)
    }

    /// A non-player-shaped caster never arms the join: the log holds `A fire giant warrior begins
    /// singing Solon's Bewitching Bravura.`, which a rule without the name shape would file as a
    /// charm.
    func testAMobShapedCasterNeverArmsTheJoin() {
        let a = AllyCharms()
        a.noteCast(cast("a fire giant warrior", "a fire giant warrior", "Allure", 0))
        guard case .none = a.broadcast("a rock golem", "a rock golem", 1_000) else {
            return XCTFail("expected no verdict")
        }
    }

    func testOneArmedPlayerCasterBindsTheBroadcastToThem() {
        let a = AllyCharms()
        a.noteCast(cast("Scooba", "scooba", "Allure", 0))
        guard case .bind(let b) = a.broadcast("a rock golem", "a rock golem", 3_000) else {
            return XCTFail("expected a bind")
        }
        XCTAssertEqual(b.charmer, "Scooba")
        XCTAssertEqual(b.kind, .charm)
        XCTAssertTrue(a.isFriendly("scooba"))
    }

    /// Two casters armed over one broadcast is refused, and both arms are consumed so the next
    /// broadcast cannot ride a spent cast in.
    func testATwoCasterTieIsRefusedAndSpendsBothArms() {
        let a = AllyCharms()
        a.noteCast(cast("Paladrial", "paladrial", "Cajoling Whispers III", 0))
        a.noteCast(cast("Satya", "satya", "Cajoling Whispers III", 0))
        guard case .refuse = a.broadcast("a lava duct crawler", "a lava duct crawler", 3_000) else {
            return XCTFail("expected a refusal")
        }
        guard case .none = a.broadcast("a lava duct crawler", "a lava duct crawler", 3_000) else {
            return XCTFail("expected no verdict")
        }
    }

    /// The bard's charm can never be the cast a broadcast resolved.
    func testABardCharmDoesNotArmTheJoin() {
        let a = AllyCharms()
        a.noteCast(cast("Enzee", "enzee", "Solon's Bewitching Bravura", 0))
        guard case .none = a.broadcast("a rock golem", "a rock golem", 1_000) else {
            return XCTFail("expected no verdict")
        }
        // …but the caster is still remembered as a friendly, the other half of `noteCast`.
        XCTAssertTrue(a.isFriendly("enzee"))
    }

    /// The hold slides on evidence: a pet still swinging keeps its row past the DB's figure.
    func testActivitySlidesTheHoldAndSilenceReapsIt() {
        let a = AllyCharms()
        a.noteCast(cast("Scooba", "scooba", "Allure", 0))
        a.broadcast("a rock golem", "a rock golem", 3_000)
        let window = provisionalWindowMs("Allure")
        a.noteActivity("a rock golem", window)
        XCTAssertTrue(a.sweep(3_000 + window).isEmpty)
        XCTAssertEqual(a.sweep(window + window).count, 1)
    }

    /// A `summon` bind has no clock and no break rule; a `charm` bind has both.
    func testASummonBindIsExemptFromTheClockAndTheBreak() {
        let a = AllyCharms()
        a.noteCast(cast("Wemby", "wemby", "Kintaz's Animation", 0))
        a.bindByLeader(AllyLeaderLine(petKey: "gasarn", pet: "Gasarn", owner: "Wemby",
                                      ownerKey: "wemby", ts: 1_000, everCharmed: false))
        XCTAssertEqual(a.bindOf("gasarn")?.kind, .summon)
        XCTAssertNil(a.softHostile("gasarn"))
        XCTAssertTrue(a.sweep(Int64.max - 1).isEmpty)
    }

    /// Charm evidence for the pet outranks summon evidence for the owner.
    func testAPetABroadcastHasNamedIsACharmBindEvenBesideASummonSighting() {
        let a = AllyCharms()
        a.noteCast(cast("Wemby", "wemby", "Kintaz's Animation", 0))
        let b = a.bindByLeader(AllyLeaderLine(petKey: "a rock golem", pet: "a rock golem",
                                              owner: "Wemby", ownerKey: "wemby", ts: 1_000,
                                              everCharmed: true))
        XCTAssertEqual(b.kind, .charm)
        XCTAssertNotNil(a.softHostile("a rock golem"))
    }

    /// A later broadcast contradicts a summon lifecycle, one direction only.
    func testABroadcastUpgradesASummonBindToTheCharmLifecycle() {
        let a = AllyCharms()
        a.noteCast(cast("Wemby", "wemby", "Kintaz's Animation", 0))
        a.bindByLeader(AllyLeaderLine(petKey: "a rock golem", pet: "a rock golem", owner: "Wemby",
                                      ownerKey: "wemby", ts: 1_000, everCharmed: false))
        // No arm is live, so this resolves to nothing — and still moves the lifecycle.
        a.broadcast("a rock golem", "a rock golem", 2_000)
        XCTAssertEqual(a.bindOf("a rock golem")?.kind, .charm)
    }

    /// The twin refusal is sticky, and a re-charm by the same charmer does not clear it.
    func testAmbiguitySurvivesARecharmByTheSameCharmer() {
        let a = AllyCharms()
        a.noteCast(cast("Scooba", "scooba", "Allure", 0))
        a.broadcast("a rock golem", "a rock golem", 3_000)
        XCTAssertTrue(a.markAmbiguous("a rock golem"))
        XCTAssertFalse(a.markAmbiguous("a rock golem"))
        XCTAssertNil(a.creditable("a rock golem"))
        a.noteCast(cast("Scooba", "scooba", "Allure", 10_000))
        a.broadcast("a rock golem", "a rock golem", 13_000)
        XCTAssertNil(a.creditable("a rock golem"))
    }
}

// MARK: - others.rs

final class CombatOthersTests: XCTestCase {
    func testTheLadderRemembersARowOnceAndGivesTheLogsOwnSpelling() {
        let o = OtherCombatants()
        o.note("scooba", "Scooba")
        o.note("scooba", "SCOOBA")
        XCTAssertEqual(o.nameOf("scooba"), "Scooba")
        XCTAssertTrue(o.isRecorded("scooba"))
        o.forget("scooba")
        XCTAssertFalse(o.isRecorded("scooba"))
    }

    /// A stronger model claiming the name reports the first claim only, so the caller retracts once.
    func testAPetClaimReportsItselfExactlyOnce() {
        let o = OtherCombatants()
        XCTAssertTrue(o.notePet("vebarn"))
        XCTAssertFalse(o.notePet("vebarn"))
        XCTAssertFalse(o.notePet(""))
        XCTAssertTrue(o.isPet("vebarn"))
    }

    /// The hostile rung yields to the heal stream — a heal landing on you cannot come from a mob.
    func testAHealOutranksASwingAtYou() {
        let o = OtherCombatants()
        o.noteHostile("sonista")
        XCTAssertTrue(o.isHostile("sonista"))
        o.clearHostile("sonista")
        XCTAssertFalse(o.isHostile("sonista"))
    }

    /// A lane is silent until the log states one, and the special's own name is what it then says.
    func testALaneAnswersNothingUntilTheLogStatesIt() {
        let s = SpecialAttacks()
        XCTAssertNil(s.laneSkill("strike"))
        XCTAssertEqual(s.note("Dragon Punch"), "strike")
        XCTAssertEqual(s.laneSkill("strike"), "Dragon Punch")
        // Tail Rake shares Dragon Punch's seat rather than following it, so it is the same lane.
        XCTAssertEqual(s.note("Tail Rake"), "strike")
        XCTAssertEqual(s.laneSkill("strike"), "Tail Rake")
        // Slam belongs to no lane the evidence supports.
        XCTAssertNil(s.note("Slam"))
        XCTAssertNil(s.laneSkill("bash"))
    }
}
