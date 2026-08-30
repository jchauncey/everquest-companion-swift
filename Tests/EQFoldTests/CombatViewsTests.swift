// The Rust unit tests of the combat view half, ported verbatim: rounds.rs, healing.rs,
// procwindows.rs, procdetect.rs and poisons.rs.
import XCTest
import EQLog
import EQCompanionCore
@testable import EQFold

// MARK: - poisons.rs

final class CombatPoisonsTests: XCTestCase {
    /// Three lines, and the two upgrade venoms sit on the lines they replace.
    func testTheCombatStackIsKeyedOnTheReplacementLine() {
        XCTAssertEqual(coatLineKey("Asp Venom"), "asp")
        XCTAssertEqual(coatLineKey("Cobra Venom"), "asp")
        XCTAssertEqual(coatLineKey("Blood Siphon Venom"), "blood")
        XCTAssertEqual(coatLineKey("Blood Draw Venom"), "blood")
        XCTAssertEqual(coatLineKey("Stunning Venom"), "stunning")
        // A utility poison has no line, so it is its own key — the utility slot is exclusive anyway.
        XCTAssertEqual(coatLineKey("Neurotoxic Poison"), "neurotoxic poison")
        // …and so is anything the roster does not know.
        XCTAssertEqual(coatLineKey("Some New Venom"), "some new venom")
    }

    /// Four poisons grant the slow Strike, which is why a slow landing never names one.
    func testSlowCapabilityIsAPropertyOfFourPoisons() {
        for name in ["Weakening Poison", "Binding Poison", "Neurotoxic Poison", "Paralytic Poison"] {
            XCTAssertTrue(isSlowCapable(name), name)
        }
        XCTAssertFalse(isSlowCapable("Asp Venom"))
        XCTAssertFalse(isSlowCapable("unknown"))
    }
}

// MARK: - rounds.rs

final class CombatRoundsTests: XCTestCase {
    private func swing(_ ts: Int64, _ verb: String, _ target: String, _ amount: Int64,
                       _ modifiers: [String] = []) -> SwingRecord {
        SwingRecord(ts: ts, verb: verb, skill: "Melee", target: target, amount: amount,
                    avoided: false, modifiers: modifiers)
    }

    /// The fan-out collapse: one double-attack round printed against two defenders is one round with
    /// two targets, never two rounds and never a quadruple.
    func testOneRoundFannedAcrossTwoDefendersCollapsesToOne() {
        var a = RoundAccum()
        a.add(swing(0, "backstab", "Warlord Skarlon", 45))
        a.add(swing(0, "backstab", "a fire giant wizard", 45))
        a.add(swing(0, "backstab", "Warlord Skarlon", 31))
        a.add(swing(0, "backstab", "a fire giant wizard", 31))
        let lanes = a.snapshot()
        XCTAssertEqual(lanes.count, 1)
        XCTAssertEqual(lanes[0].rounds, 1)
        XCTAssertEqual(lanes[0].fannedRounds, 1)
        XCTAssertEqual(lanes[0].buckets, [0, 1, 0, 0])
    }

    /// …and two different verbs with the same signature in one second stay two rounds, which is why
    /// the signature is keyed by verb.
    func testTwoVerbsWithOneSignatureStayTwoRounds() {
        var a = RoundAccum()
        a.add(swing(0, "backstab", "a bat", 163))
        a.add(swing(0, "slash", "a bat", 163))
        let lanes = a.snapshot()
        XCTAssertEqual(lanes.count, 2)
        XCTAssertEqual(lanes.map(\.rounds).reduce(0, +), 2)
    }

    /// An excluded swing is tallied, never dropped silently.
    func testAnExtraSwingIsCountedOutOfTheRoundsAndIntoTheExclusions() {
        var a = RoundAccum()
        a.add(swing(0, "slash", "a bat", 20, ["Riposte"]))
        a.add(swing(0, "frenzy", "a bat", 20))
        XCTAssertTrue(a.snapshot().isEmpty)
        XCTAssertEqual(a.excluded[RoundExclusion.riposte.slot], 1)
        XCTAssertEqual(a.excluded[RoundExclusion.frenzy.slot], 1)
    }

    /// The snapshot includes the still-open second and does not close it: repeatable, identical.
    func testASnapshotSeesTheOpenSecondWithoutClosingIt() {
        var a = RoundAccum()
        a.add(swing(1_500, "slash", "a bat", 10))
        XCTAssertEqual(a.snapshot()[0].rounds, 1)
        XCTAssertEqual(a.snapshot()[0].rounds, 1)
        a.add(swing(1_600, "slash", "a bat", 12))
        XCTAssertEqual(a.snapshot()[0].buckets, [0, 1, 0, 0])
    }

    /// The dual-wield confound, made explicit.
    func testAReuseTimerVerbReadsPerEventAndAWeaponVerbDoesNot() {
        XCTAssertEqual(roundConfidence("Backstab"), "perEvent")
        XCTAssertEqual(roundConfidence("slash"), "aggregate")
    }
}

// MARK: - healing.rs

final class CombatHealingTests: XCTestCase {
    private func heal(_ amount: Int64, _ raw: Int64?, _ spell: String) -> HealInput {
        HealInput(amount: amount, rawAmount: raw, spell: spell, crit: false)
    }

    /// Overheal is a floor: only the parenthesised form contributes, a plain line contributes 0.
    func testOverhealComesOnlyFromTheParenthesisedForm() {
        var a = HealAccum()
        a.addFriendly("you", "You", .you, heal(100, nil, "Healing"))
        a.addFriendly("you", "You", .you, heal(40, 120, "Healing"))
        let v = buildHealingView(a, 10.0)
        XCTAssertEqual(v.healers[0].overheal, 80)
        XCTAssertEqual(v.healers[0].total, 140)
        XCTAssertEqual(v.overheal, 80)
    }

    /// A rune is absorption, not restoration: it ranks in the total, rides an `absorbed` lane, and
    /// never touches the row's heal stats.
    func testARuneLaneRidesTheSelfRowWithoutMovingItsHealStats() {
        var a = HealAccum()
        a.addRune(394)
        let v = buildHealingView(a, 10.0)
        XCTAssertEqual(v.healers.count, 1)
        let row = v.healers[0]
        XCTAssertEqual(row.id, "you")
        XCTAssertEqual(row.count, 0)
        XCTAssertEqual(row.total, 394)
        XCTAssertEqual(row.absorbedTotal, 394)
        XCTAssertEqual(v.restoredTotal, 0)
        XCTAssertEqual(row.spells[0].classification, "absorbed")
        // …and the row's own `min` is ABSENT, because nothing was restored.
        XCTAssertNil(row.min)
    }

    /// An unstated heal is a count and nothing else: total 0, no min, and it enters no sum.
    func testAnUnstatedLaneCarriesACountAndNoMeasurement() {
        var a = HealAccum()
        a.addUnstated("Mend")
        let v = buildHealingView(a, 10.0)
        let row = v.healers[0]
        XCTAssertEqual(row.unstatedCount, 1)
        XCTAssertEqual(row.total, 0)
        XCTAssertEqual(v.total, 0)
        let lane = row.spells[0]
        XCTAssertEqual(lane.classification, "unstated")
        XCTAssertEqual(lane.count, 1)
        XCTAssertNil(lane.min)
    }

    /// A spell-less line falls to one shared lane, and so does a whitespace-only name.
    func testANamelessHealFallsToTheOneSharedLane() {
        var a = HealAccum()
        a.addFriendly("you", "You", .you, HealInput(amount: 10))
        a.addFriendly("you", "You", .you, HealInput(amount: 5, spell: "   "))
        let v = buildHealingView(a, 10.0)
        XCTAssertEqual(v.healers[0].spells.count, 1)
        XCTAssertEqual(v.healers[0].spells[0].name, UNSPECIFIED_SPELL)
        XCTAssertEqual(v.healers[0].spells[0].count, 2)
    }

    /// A fully overhealed tick still LANDED, so it moves `min` to 0 — the opposite of the damage
    /// model's rule, and deliberately so.
    func testAZeroEffectiveHealStillCountsAsALandedLine() {
        var a = HealAccum()
        a.addFriendly("you", "You", .you, heal(20, nil, "Regeneration"))
        a.addFriendly("you", "You", .you, heal(0, 20, "Regeneration"))
        let v = buildHealingView(a, 10.0)
        XCTAssertEqual(v.healers[0].min, 0)
        XCTAssertEqual(v.healers[0].fullOverheal, 1)
    }
}

// MARK: - procwindows.rs

final class CombatProcWindowsTests: XCTestCase {
    /// Every rate is absent below its floor — one proc in a two-second pull is not 30 ppm.
    func testARateBelowItsSampleFloorIsAbsentRatherThanHuge() {
        let v = procRate(RateInput(count: 1, activeSec: 2.0, durationSec: 2.0, swings: 3))
        XCTAssertNil(v.ppmActive)
        XCTAssertNil(v.ppmWall)
        XCTAssertNil(v.per100Swings)
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v.swings, 3)
    }

    /// The source window is declared even when it fails the floor, so the absence message can quote
    /// it.
    func testAShortSourceWindowIsStatedAndStillYieldsNoRate() {
        let v = procRate(RateInput(count: 3, activeSec: 600.0, durationSec: 600.0, swings: 100,
                                   source: ProcSourceWindow(activeSec: 4.0, name: "Neurotoxic Poison"),
                                   sourceUnknown: false))
        XCTAssertEqual(v.sourceSec, 4.0)
        XCTAssertEqual(v.sourceName, "Neurotoxic Poison")
        XCTAssertNil(v.ppmActive)
        XCTAssertNotNil(v.per100Swings)
    }

    /// Concentration alone never reaches `exclusive`; the fixtures are two real lanes whose inactive
    /// exposures fall either side of the gate.
    func testAPerfectConcentrationAtNoExposureStaysInconclusive() {
        XCTAssertEqual(linkStrength(LinkInput(withCount: 1_084, withoutCount: 0,
                                              activeSwings: 261_505, inactiveSwings: 289)),
                       "inconclusive")
        XCTAssertEqual(linkStrength(LinkInput(withCount: 14, withoutCount: 0,
                                              activeSwings: 406, inactiveSwings: 225)),
                       "exclusive")
    }

    /// The purity gate discards the boundary minute, prefix-matched for coats.
    func testAWindowWithACommitOfTheGroupIsDiscarded() {
        var w = WindowAccum()
        let active: Set<String> = ["stance:offensive"]
        w.fold(WindowFold(ts: 0, activeDeltaMs: MIN_WINDOW_ACTIVE_MS, swings: MIN_WINDOW_SWINGS),
               active)
        var list = w.list()
        XCTAssertEqual(partitionWindows(list, "stance:offensive", "stance").active.count, 1)
        w.noteTransition(0, "coat:utility", active)
        list = w.list()
        XCTAssertEqual(partitionWindows(list, "stance:offensive", "coat:").active.count, 0)
        XCTAssertEqual(partitionWindows(list, "stance:offensive", "stance").active.count, 1)
    }

    /// The type-7 quantile, pinned so the IQR is reproducible.
    func testTheQuantileIsLinearInterpolated() {
        let s: [Double] = [1.0, 2.0, 3.0, 4.0]
        XCTAssertEqual(quantile(s, 0.5), 2.5)
        XCTAssertEqual(quantile(s, 0.25), 1.75)
        XCTAssertEqual(quantile([], 0.5), 0.0)
    }
}

// MARK: - procdetect.rs

final class CombatProcDetectTests: XCTestCase {
    /// One cast explains one firing: a landing at a later instant is a proc, and every landing at the
    /// same instant still joins the cast (the AoE / lifetap case).
    func testACastRecordExplainsOneInstantAndNoLaterOne() {
        var r = RecentCasts()
        r.note("Anarchy", 1_000)
        XCTAssertEqual(r.origin("Anarchy", 1_000), .cast)
        XCTAssertEqual(r.origin("Anarchy", 1_000), .cast)
        XCTAssertEqual(r.origin("Anarchy", 2_000), .proc)
    }

    /// The window is closed at both ends: a future cast is no cast at all.
    func testACastOutsideTheWindowExplainsNothing() {
        var r = RecentCasts()
        r.note("Anarchy", 20_000)
        XCTAssertEqual(r.origin("Anarchy", 20_000 + PROC_CAST_WINDOW_MS + 1), .proc)
        XCTAssertEqual(r.origin("Anarchy", 19_000), .proc)
    }

    /// A fizzle drops its record; a recovered interrupt gets it back with its original cast ts.
    func testForgetDropsAnUnclaimedRecordAndResumeRestoresIt() {
        var r = RecentCasts()
        r.note("Siphon Life", 1_000)
        r.forget("Siphon Life")
        r.resume()
        XCTAssertEqual(r.origin("Siphon Life", 1_000 + PROC_CAST_WINDOW_MS), .cast)
        // …and a record that already explained a firing is not dropped, so the rest of that instant's
        // lines can still join after a mid-burst resist.
        r.note("Earthquake", 5_000)
        XCTAssertEqual(r.origin("Earthquake", 5_000), .cast)
        r.forget("Earthquake")
        XCTAssertEqual(r.origin("Earthquake", 5_000), .cast)
    }

    /// Rank-normalized at the counting boundary: the cast prints the numeral, the landing does not.
    func testTheJoinIsRankBlind() {
        var r = RecentCasts()
        r.note("Swift Like the Wind I", 1_000)
        XCTAssertEqual(r.origin("Swift Like the Wind", 1_000), .cast)
    }

    /// The rain gate refuses a wave outright, whatever the cast ledger says.
    func testARainWaveIsNeverEligible() {
        XCTAssertTrue(procEligibleDamage("spell", "Anarchy"))
        XCTAssertFalse(procEligibleDamage("spell", "Rain of Fire"))
        XCTAssertFalse(procEligibleDamage("dot", "Anarchy"))
    }

    /// An empty held set is the identity function — no lane name moves without a dump.
    func testTheClickyPromotionNeedsTheDump() {
        let empty: Set<String> = []
        XCTAssertEqual(castlessKind(.proc, "Firestrike", empty), .proc)
        let held: Set<String> = [Names.spellCanonKey("Firestrike")]
        XCTAssertEqual(castlessKind(.proc, "Firestrike", held), .click)
        // …and a cast is never promoted.
        XCTAssertEqual(castlessKind(.cast, "Firestrike", held), .cast)
    }

    /// The lane count is `max`, never the sum — one tap firing prints two lines.
    func testATapThatPrintsBothSidesCountsEachFiringOnce() {
        var lanes = JSMap<SpellProcLane>()
        let active: Set<String> = ["invocation:spellblade"]
        for _ in 0..<12 {
            addSpellProc(&lanes, SpellProcFold(spell: "Lifetap Strike", side: .damage,
                                               amount: 10, active: active, click: false))
            addSpellProc(&lanes, SpellProcFold(spell: "Lifetap Strike", side: .heal,
                                               amount: 9, active: active, click: false))
        }
        let lane = lanes.values[0]
        XCTAssertEqual(laneCount(lane), 12)
        XCTAssertEqual(lane.damage, 120)
        XCTAssertEqual(lane.heal, 108)
        XCTAssertEqual(sidesCount(lane.byState["invocation:spellblade"]), 12)
    }

    /// A landing fold moves no amount — the count is the whole observation.
    func testALandingOnlyProcCarriesACountAndNothingElse() {
        var lanes = JSMap<SpellProcLane>()
        addSpellProc(&lanes, SpellProcFold(spell: "Blessing of the Theurgist", side: .landing,
                                           amount: nil, active: [], click: false))
        let lane = lanes.values[0]
        XCTAssertEqual(laneCount(lane), 1)
        XCTAssertEqual(lane.damage, 0)
        XCTAssertEqual(lane.heal, 0)
    }

    /// The marker is display: both halves of a split key to one spell.
    func testTheLaneMarkerIsStrippedAtEveryJoin() {
        XCTAssertEqual(laneNameFor("Puma Maw", .proc), "Puma Maw \u{00b7} proc")
        XCTAssertEqual(laneNameFor("Puma Maw", .cast), "Puma Maw")
        XCTAssertTrue(isCastlessLaneName("Puma Maw \u{00b7} click"))
        XCTAssertFalse(isCastlessLaneName("Puma Maw"))
        XCTAssertEqual(laneCanonKey("Puma Maw \u{00b7} proc"), Names.spellCanonKey("Puma Maw"))
    }

    /// The two heal refusals: a HoT tick and a Quick Buff burst landing are never procs.
    func testTheHealSideRefusesHotTicksAndQuickBuffBursts() {
        var r = RecentCasts()
        XCTAssertFalse(isCastlessHeal(&r, HealProcInput(spell: "Ethereal Cleansing", ts: 1_000,
                                                        overTime: true, quickBuffTs: 0)))
        XCTAssertFalse(isCastlessHeal(&r, HealProcInput(spell: "Valor", ts: 4_000,
                                                        overTime: false, quickBuffTs: 1_000)))
        XCTAssertTrue(isCastlessHeal(&r, HealProcInput(spell: "Lifetap Strike", ts: 9_000,
                                                       overTime: false, quickBuffTs: 1_000)))
    }

    /// Unambiguous or nothing: a two-candidate list counts no firing.
    func testASelfLandingProcNeedsAOneElementCandidateList() {
        XCTAssertNotNil(selfLandingProcIn(["Blessing of the Theurgist"]))
        XCTAssertNil(selfLandingProcIn(["Blessing of the Theurgist", "Something Else"]))
    }
}
