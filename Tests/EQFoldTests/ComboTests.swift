// The combo module (fold/src/modules/combo.rs + combo/{evidence,score,levels,intervals}.rs), tested
// at the laws its headers state. The Rust files carry no `#[cfg(test)]` block, so these are written
// against the rules the comments assert rather than ported case by case.
import XCTest
import EQLog
import EQFold
import EQCompanionCore

final class ComboTests: XCTestCase {
    // MARK: - evidence.rs: the committed tables and the class-string parse

    func testParseSpellClassStringDedupesAndSorts() {
        let s = "* Shaman - Level 9\n* Necromancer - Level 14\n* Shaman - Level 20"
        XCTAssertEqual(parseSpellClassString(s), ["NEC", "SHM"])
    }

    /// The wiki spells the Shadow Knight both ways across its own spell pages; both are SHD.
    func testShadowKnightSpelledBothWays() {
        XCTAssertEqual(parseSpellClassString("* Shadow Knight - Level 20"), ["SHD"])
        XCTAssertEqual(parseSpellClassString("* Shadowknight - Level 20"), ["SHD"])
    }

    /// Anything not of the bullet shape yields an empty list rather than a guess.
    func testNonBulletShapeYieldsNothing() {
        XCTAssertEqual(parseSpellClassString("Cleric, Paladin"), [])
        XCTAssertEqual(parseSpellClassString("* Squire - Level 4"), [])
        XCTAssertEqual(parseSpellClassString(nil), [])
    }

    func testClassAbbrIsAClosedSet() {
        XCTAssertEqual(asClassAbbr("SHD"), "SHD")
        XCTAssertNil(asClassAbbr("SHK"))
        XCTAssertNil(asClassAbbr("shd"))
        XCTAssertEqual(classAbbrs.count, 16)
        XCTAssertEqual(classAbbrs, classAbbrs.sorted())
    }

    /// The tables ship with the app; an empty stance table would silently turn every inference into
    /// an unknown slot, so the module says "not ready" instead.
    func testTablesAreReady() {
        XCTAssertTrue(comboTablesReady())
    }

    /// spells.json is the authority on anything with a spell page.
    func testSpellClassIndexIsBuiltOffTheCatalog() {
        let index = spellClassIndex(SpellDb.shared())
        XCTAssertFalse(index.isEmpty)
        for (_, classes) in index.prefix(50) {
            XCTAssertFalse(classes.isEmpty)
            XCTAssertEqual(classes, classes.sorted())
            for c in classes { XCTAssertNotNil(asClassAbbr(c)) }
        }
    }

    // MARK: - levels.rs

    private func obs(_ ts: Int64, _ seq: Int64, _ source: String, _ label: String, _ cands: [ClassAbbr]) -> ClassObservation {
        let weights: [String: Double] = ["who": 0, "poisonCoat": 3, "stance": 2.5, "skillUp": 2.5, "invocation": 1.5]
        return ClassObservation(ts: ts, seq: seq, source: source, label: label, candidates: cands,
                                weight: weights[source] ?? 1.0)
    }

    /// The two loops share one `at`, so the latest statement wins whichever source it came from —
    /// and a `/who` row at the SAME instant as a ding still wins: it states the bracket outright.
    func testLevelAtPrefersTheWhoRowOnATie() {
        let st = LevelStatements(levels: [LevelPoint(ts: 100, level: 12)],
                                 whoRows: [WhoRow(ts: 100, seq: 1, classes: ["WAR"], level: 30)])
        XCTAssertEqual(levelAt(st, 100), 30)
        XCTAssertEqual(levelAt(st, 99), nil)
    }

    func testLevelRangeIsTheHullIncludingTheLevelInForce() {
        let st = LevelStatements(levels: [LevelPoint(ts: 10, level: 20), LevelPoint(ts: 50, level: 21),
                                          LevelPoint(ts: 90, level: 22)],
                                 whoRows: [])
        let (lo, hi) = levelRange(st, 40, 100)
        XCTAssertEqual(lo, 20) // the level in force at 40
        XCTAssertEqual(hi, 22)
    }

    /// A level observed inside the interval BELOW the level in force when it opened proves a swap.
    func testLevelRegressionIsAboutOrderNotWidth() {
        let grind = LevelStatements(levels: [LevelPoint(ts: 10, level: 24), LevelPoint(ts: 90, level: 50)],
                                    whoRows: [])
        XCTAssertFalse(levelRegressedInside(grind, 10, nil))
        let swap = LevelStatements(levels: [LevelPoint(ts: 10, level: 50), LevelPoint(ts: 90, level: 11)],
                                   whoRows: [])
        XCTAssertTrue(levelRegressedInside(swap, 10, nil))
    }

    // MARK: - intervals.rs: the detectors

    /// `<=`, not `<`: a genuine same-level repeat hours apart is a swap signal too.
    func testLevelDropFiresOnANonIncreasingDing() {
        let drops = levelDropBoundaries([LevelPoint(ts: 10, level: 20), LevelPoint(ts: 20, level: 21),
                                         LevelPoint(ts: 30, level: 21), LevelPoint(ts: 40, level: 12)])
        XCTAssertEqual(drops.map(\.at), [30, 40])
        XCTAssertEqual(drops.map(\.lo), [20, 30])
        XCTAssertEqual(drops.map(\.reason), ["levelDrop", "levelDrop"])
    }

    /// The first row never opens a boundary, and a swap something sharper already dated is not split
    /// a second time.
    func testWhoBoundariesStandDownWhereSomethingSharperCut() {
        let rows = [WhoRow(ts: 10, seq: 1, classes: ["WAR", "NEC"], level: 9),
                    WhoRow(ts: 100, seq: 2, classes: ["WAR", "SHM", "NEC"], level: 10)]
        XCTAssertEqual(whoBoundaries(rows, []).map(\.at), [100])
        let dated = [Boundary(lo: 40, hi: 60, at: 60, reason: "evidenceShift")]
        XCTAssertEqual(whoBoundaries(rows, dated).map(\.at), [])
    }

    /// Windows that OVERLAP describe one swap and the narrowest wins; the loser is recorded in
    /// `also` rather than thrown away. Windows that merely TOUCH are two swaps.
    func testMergeKeepsTheNarrowestAndRecordsTheRest() {
        let merged = mergeBoundaries([Boundary(lo: 0, hi: 1000, at: 1000, reason: "levelDrop"),
                                      Boundary(lo: 400, hi: 500, at: 500, reason: "evidenceShift")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].reason, "evidenceShift")
        XCTAssertEqual(merged[0].also, ["levelDrop"])
        // The cut is the EARLIEST `at` in the group, clamped into the winning window.
        XCTAssertEqual(merged[0].at, 500)

        let touching = mergeBoundaries([Boundary(lo: 0, hi: 100, at: 100, reason: "levelDrop"),
                                        Boundary(lo: 100, hi: 200, at: 200, reason: "levelDrop")])
        XCTAssertEqual(touching.map(\.at), [100, 200])
    }

    /// A `/who` cut is never merged away: two rows are two statements, never one event.
    func testAWhoCutSurvivesAWiderInferredWindow() {
        let out = mergeBoundaries([Boundary(lo: 0, hi: 1000, at: 1000, reason: "levelDrop"),
                                   Boundary(lo: 300, hi: 400, at: 400, reason: "who"),
                                   Boundary(lo: 600, hi: 700, at: 700, reason: "who")])
        XCTAssertEqual(out.map(\.at), [400, 700])
        XCTAssertEqual(out.map(\.reason), ["who", "who"])
        // The absorbed drop corroborates the row cut nearest its own date.
        XCTAssertEqual(out[1].also, ["levelDrop"])
    }

    // MARK: - score.rs

    /// Admission needs an exclusive label spanning two hourly buckets AND evidence in two buckets;
    /// unfilled positions come back as explicit UNKNOWN slots, never dropped.
    func testAnAdmittedClassResolvesAndTheRestAreUnknown() {
        let hour: Int64 = 3_600_000
        let slots = scoreSlots([obs(0, 1, "poisonCoat", "Blinding Poison", ["ROG"]),
                                obs(hour, 2, "poisonCoat", "Blinding Poison", ["ROG"])], 3)
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].candidates, ["ROG"])
        XCTAssertEqual(slots[0].provenance, "inferred")
        XCTAssertEqual(slots[0].confidence, 0.5)
        XCTAssertEqual(slots[0].because, ["poisonCoat:Blinding Poison"])
        XCTAssertEqual(slots[1].candidates, classAbbrs)
        XCTAssertEqual(slots[1].confidence, 0.0)
        XCTAssertEqual(slots[2].candidates, classAbbrs)
    }

    /// A class named by one exclusive label inside a single hour has been glimpsed, not evidenced.
    func testOneStrayExclusiveLabelInOneHourIsRefused() {
        let slots = scoreSlots([obs(0, 1, "cast", "Word of Shadow", ["NEC"])], 3)
        XCTAssertEqual(slots.map(\.candidates), [classAbbrs, classAbbrs, classAbbrs])
    }

    /// The model says "I don't know" out loud: a residual cluster holds the SET, not a member, and
    /// a two-way ambiguity is worth 0.3, not 0.6.
    func testAResidualClusterKeepsBothCandidates() {
        let slots = scoreSlots([obs(0, 1, "cast", "Courage", ["CLR", "PAL"]),
                                obs(60_000, 2, "cast", "Minor Healing", ["CLR", "PAL"])], 3)
        XCTAssertEqual(slots[0].candidates, ["CLR", "PAL"])
        XCTAssertEqual(slots[0].confidence, 0.3, accuracy: 1e-12)
        XCTAssertEqual(slots[0].because, ["cast:Courage", "cast:Minor Healing"])
        XCTAssertEqual(slots[1].candidates, classAbbrs)
    }

    /// A `/who` row is not scored, it OVERRIDES — so it never draws an exclusive span for itself.
    func testWhoObservationsNeverScore() {
        let hour: Int64 = 3_600_000
        let slots = scoreSlots([obs(0, 1, "who", "who", ["WIZ"]), obs(hour, 2, "who", "who", ["WIZ"])], 3)
        XCTAssertEqual(slots.map(\.candidates), [classAbbrs, classAbbrs, classAbbrs])
    }

    func testStatedSlotsAreResolvedAtFullConfidence() {
        let slots = statedSlots(["WAR", "SHM", "NEC"], "who")
        XCTAssertEqual(slots.map(\.candidates), [["WAR"], ["SHM"], ["NEC"]])
        XCTAssertEqual(slots.map(\.confidence), [1.0, 1.0, 1.0])
        XCTAssertEqual(slots.map(\.because), [["who"], ["who"], ["who"]])
    }

    // MARK: - intervals.rs: assembly

    func testNoObservationsMeansNoIntervals() {
        XCTAssertTrue(buildIntervals(IntervalInput(observations: [], whoRows: [], levels: [], corrections: [])).isEmpty)
    }

    /// A `/who` row states the loadout for its own span and sets `expectedSlots` from its arity; the
    /// open interval's `endHi` stays null while `endLo` is the last moment we have evidence for.
    func testAWhoRowStatesTheSliceItSitsIn() {
        let hour: Int64 = 3_600_000
        let rows = [WhoRow(ts: 0, seq: 1, classes: ["WAR", "NEC"], level: 9)]
        let intervals = buildIntervals(IntervalInput(
            observations: [obs(0, 1, "who", "who", ["NEC", "WAR"]),
                           obs(hour, 2, "cast", "Word of Shadow", ["NEC"])],
            whoRows: rows, levels: [], corrections: []))
        XCTAssertEqual(intervals.count, 1)
        let i = intervals[0]
        XCTAssertEqual(i.id, "ci1")
        XCTAssertEqual(i.startReason, "logStart")
        XCTAssertEqual(i.expectedSlots, 2)
        XCTAssertEqual(i.slots.map(\.candidates), [["WAR"], ["NEC"]])
        XCTAssertEqual(i.slots.map(\.provenance), ["who", "who"])
        XCTAssertNil(i.endTs)
        XCTAssertNil(i.endHi)
        XCTAssertEqual(i.endLo, hour)
        XCTAssertEqual(i.evidenceCount, 2)
        XCTAssertFalse(i.userLocked)
        XCTAssertNil(i.userOverruled)
    }

    /// A level below the tertiary unlock is a PRIOR of two slots; the `/who` row's own arity wins
    /// over it where there is one.
    func testTheTertiaryPriorFollowsTheLevelInForce() {
        let hour: Int64 = 3_600_000
        let low = buildIntervals(IntervalInput(
            observations: [obs(0, 1, "cast", "Courage", ["CLR", "PAL"]), obs(hour, 2, "cast", "Courage", ["CLR", "PAL"])],
            whoRows: [], levels: [LevelPoint(ts: 0, level: 4)], corrections: []))
        XCTAssertEqual(low[0].expectedSlots, 2)
        XCTAssertEqual(low[0].slots.count, 2)
        XCTAssertEqual(low[0].levelLo, 4)

        let high = buildIntervals(IntervalInput(
            observations: [obs(0, 1, "cast", "Courage", ["CLR", "PAL"]), obs(hour, 2, "cast", "Courage", ["CLR", "PAL"])],
            whoRows: [], levels: [LevelPoint(ts: 0, level: 30)], corrections: []))
        XCTAssertEqual(high[0].expectedSlots, 3)
        XCTAssertEqual(high[0].slots.count, 3)
    }

    /// A user correction governs the slice it covers, locks it, and states its own arity.
    func testAUserCorrectionGovernsAndLocksTheSlice() {
        let hour: Int64 = 3_600_000
        let intervals = buildIntervals(IntervalInput(
            observations: [obs(0, 1, "cast", "Courage", ["CLR", "PAL"]), obs(hour, 2, "cast", "Courage", ["CLR", "PAL"])],
            whoRows: [], levels: [],
            corrections: [ComboCorrection(startTs: 0, endTs: nil, classes: ["ENC", "MAG"], setAt: 5)]))
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].slots.map(\.candidates), [["ENC"], ["MAG"]])
        XCTAssertEqual(intervals[0].slots.map(\.provenance), ["user", "user"])
        XCTAssertEqual(intervals[0].expectedSlots, 2)
        XCTAssertTrue(intervals[0].userLocked)
    }

    /// Rule 1: the game named the loadout for this very span, so it wins even over a user correction
    /// — and the loss is carried in the model rather than swallowed.
    func testAWhoRowOverrulesAStandingCorrection() {
        let intervals = buildIntervals(IntervalInput(
            observations: [obs(0, 1, "who", "who", ["NEC", "WAR"])],
            whoRows: [WhoRow(ts: 0, seq: 1, classes: ["WAR", "NEC"], level: 20)],
            levels: [],
            corrections: [ComboCorrection(startTs: 0, endTs: nil, classes: ["ENC", "MAG"], setAt: 5)]))
        XCTAssertEqual(intervals[0].slots.map(\.candidates), [["WAR"], ["NEC"]])
        XCTAssertEqual(intervals[0].userOverruled, true)
        XCTAssertFalse(intervals[0].userLocked)
    }

    /// Rule 1 covering the start wins; otherwise the correction overlapping most wins, ties to the
    /// latest `setAt`.
    func testCorrectionForSliceRules() {
        let covering = ComboCorrection(startTs: 0, endTs: 100, classes: ["WAR"], setAt: 1)
        let later = ComboCorrection(startTs: 0, endTs: 100, classes: ["NEC"], setAt: 2)
        XCTAssertEqual(correctionForSlice([covering, later], 50, 200)?.classes, ["NEC"])
        // Nothing covers 500; the one overlapping [500, 900) most wins.
        let small = ComboCorrection(startTs: 600, endTs: 650, classes: ["WAR"], setAt: 1)
        let big = ComboCorrection(startTs: 700, endTs: 900, classes: ["NEC"], setAt: 1)
        XCTAssertEqual(correctionForSlice([small, big], 500, 900)?.classes, ["NEC"])
        XCTAssertNil(correctionForSlice([small], 1000, 2000))
    }

    // MARK: - combo.rs: the shell

    private func ev(_ o: [String: JSONValue]) -> Event { Event.fromValue(.object(o)) }

    /// `seq` is this module's own revision, never a LogEvent seq: a correction changes every
    /// interval and advances no log seq.
    func testSeqIsAPrivateRevision() {
        let m = ComboModule(spellClasses: [:], launchMs: 0)
        m.reset()
        let afterReset = m.publishedSeq
        XCTAssertEqual(afterReset, 1)
        m.onEvent(ev(["kind": "level", "seq": 900, "ts": 10, "level": 12]), live: false)
        XCTAssertEqual(m.publishedSeq, 2)
        // An event that says nothing about class advances nothing.
        m.onEvent(ev(["kind": "zone", "seq": 901, "ts": 20]), live: false)
        XCTAssertEqual(m.publishedSeq, 2)
        m.define(.array([["startTs": 10, "endTs": .null, "classes": .array([.string("WAR")]), "setAt": 1]]))
        XCTAssertEqual(m.publishedSeq, 3)
    }

    /// Character rebirth: observations before the boundary belong to a dead character, and a
    /// correction older than the launch describes the wiped beta character sharing this log file.
    func testAnEpochResetsTheRingAndPrunesOldCorrections() {
        let m = ComboModule(spellClasses: [:], launchMs: 1_000)
        m.define(.array([
            ["startTs": 500, "endTs": .null, "classes": .array([.string("WAR")]), "setAt": 1],
            ["startTs": 2_000, "endTs": .null, "classes": .array([.string("NEC")]), "setAt": 2],
        ]))
        // The pre-launch correction never lands at all.
        m.onEvent(ev(["kind": "epoch", "seq": 1, "ts": 3_000]), live: false)
        m.onEvent(ev(["kind": "selfWho", "seq": 2, "ts": 4_000, "level": 20,
                      "classes": .array([.string("SHM")])]), live: false)
        let state = m.snapshot()["state"]
        XCTAssertEqual(state["intervals"].array?.count, 1)
        XCTAssertEqual(state["intervals"][0]["slots"][0]["candidates"][0].string, "SHM")
        XCTAssertEqual(state["ready"].bool, true)
    }

    /// A correction is refused whole, never filtered.
    func testCorrectionValidationRefusesWhole() {
        let m = ComboModule(spellClasses: [:], launchMs: 1_000)
        // Duplicated code, an unknown code, four slots, a pre-launch start, an end before the start.
        m.define(.array([
            ["startTs": 2_000, "classes": .array([.string("ENC"), .string("ENC")]), "setAt": 1],
            ["startTs": 2_000, "classes": .array([.string("SHK")]), "setAt": 1],
            ["startTs": 2_000, "classes": .array([.string("ENC"), .string("MAG"), .string("NEC"), .string("WIZ")]), "setAt": 1],
            ["startTs": 10, "classes": .array([.string("ENC")]), "setAt": 1],
            ["startTs": .int(2_000), "endTs": .int(1_500), "classes": .array([.string("ENC")]), "setAt": 1],
            ["startTs": 2_000, "endTs": .null, "classes": .array([.string("WAR"), .string("SHM")]), "setAt": 1],
        ]))
        m.onEvent(ev(["kind": "selfWho", "seq": 1, "ts": 2_500, "level": 20,
                      "classes": .array([])]), live: false)
        m.onEvent(ev(["kind": "poisonCoat", "seq": 2, "ts": 2_500, "who": "you", "poison": "Blinding Poison"]), live: false)
        m.onEvent(ev(["kind": "poisonCoat", "seq": 3, "ts": .int(Int64(2_500 + 3_600_000)), "who": "you", "poison": "Blinding Poison"]), live: false)
        let state = m.snapshot()["state"]
        // Exactly one correction survived, and it governs the whole span.
        XCTAssertEqual(state["current"]["slots"].array?.count, 2)
        XCTAssertEqual(state["current"]["slots"][0]["candidates"][0].string, "WAR")
        XCTAssertEqual(state["current"]["slots"][1]["candidates"][0].string, "SHM")
        XCTAssertEqual(state["current"]["userLocked"].bool, true)
    }

    /// An empty ring publishes an empty state, not a guess.
    func testEmptyStateShape() {
        let m = ComboModule(spellClasses: [:], launchMs: 0)
        m.reset()
        let snap = m.snapshot()
        XCTAssertEqual(snap["seq"].int, 1)
        XCTAssertEqual(snap["state"]["intervals"].array?.count, 0)
        XCTAssertTrue(snap["state"]["current"].isNull)
        XCTAssertEqual(snap["state"]["ready"].bool, true)
    }

    /// Somebody else's blades say nothing about this character.
    func testOnlyYourOwnPoisonCoatCounts() {
        XCTAssertNil(classObservation([:], ev(["kind": "poisonCoat", "seq": 1, "ts": 0,
                                               "who": "Grimgar", "poison": "Blinding Poison"])))
        let mine = classObservation([:], ev(["kind": "poisonCoat", "seq": 1, "ts": 0,
                                             "who": "you", "poison": "Blinding Poison"]))
        XCTAssertEqual(mine?.candidates, ["ROG"])
        XCTAssertEqual(mine?.weight, 3.0)
    }

    /// The label strips the Roman rank; the lookup lowercases it too.
    func testACastLabelStripsTheRomanRank() {
        let index: SpellClassIndex = ["mesmerization": ["ENC"]]
        let o = classObservation(index, ev(["kind": "castBegin", "seq": 1, "ts": 0, "spell": "Mesmerization III"]))
        XCTAssertEqual(o?.label, "Mesmerization")
        XCTAssertEqual(o?.candidates, ["ENC"])
        XCTAssertEqual(o?.source, "cast")
        XCTAssertEqual(o?.weight, 1.0)
    }
}
