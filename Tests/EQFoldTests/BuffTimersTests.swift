import XCTest
import EQLog
import EQFold
import EQCompanionCore

/// The Rust unit tests at the bottom of `fold/src/modules/buff_timer_rows.rs`, ported: they pin the
/// row ordering, the modes and the two ledgers' precedence over one another.
final class BuffTimersTests: XCTestCase {
    /// The test fixture's `ActiveBuff`, spelled through the buffs half's own JSON so the seam under
    /// test is the one the registry uses.
    private func buff(_ spell: String, _ started: Int64, _ duration: Int64?) -> JSONValue {
        [
            "spell": .string(spell),
            "cls": "buff",
            "self": true,
            "startedTs": .int(started),
            "estimatedMs": duration.map { JSONValue.int($0) } ?? .null,
            "p25": .null,
            "p75": .null,
            "n": 0,
            "overlayDurationMs": duration.map { JSONValue.int($0) } ?? .null,
        ]
    }

    private func with(_ b: JSONValue, _ edits: [String: JSONValue]) -> JSONValue {
        var o = b.object ?? [:]
        for (k, v) in edits { o[k] = v }
        return .object(o)
    }

    private func hold(_ key: String, _ target: String, _ spell: String?, _ started: Int64) -> CcHold {
        CcHold(key: key, target: target, startedTs: started, spell: spell, candidates: [],
               durationMs: 48_000, source: nil, count: nil, caster: nil)
    }

    func testANameFoldsToItsFamilyAndTheRankChipIsTheDifference() {
        XCTAssertEqual(timerNameBase("Mesmerization VII"), "Mesmerization")
        XCTAssertEqual(timerNameKey("Mesmerization VII"), "mesmerization")
        // The rank chip is only the DIFFERENCE between two spellings of one spell.
        XCTAssertEqual(rowRankLabel("Mesmerization", "Mesmerization vii"), "VII")
        // A cast name folding to a different spell yields nothing.
        XCTAssertNil(rowRankLabel("Mesmerization", "Enthrall II"))
        // A cast name with no rank tail is not a rank.
        XCTAssertNil(rowRankLabel("Clarity", "clarity"))
        // A name that IS a numeral keeps it: the pattern needs a space before the tail.
        XCTAssertEqual(timerNameBase("V"), "V")
    }

    func testAStatedDurationCountsDownAndEverythingElseCountsUp() {
        let rows = buildTimerRows(
            active: [buff("Clarity", 1_000, 60_000), buff("Levitate", 2_000, nil)],
            holds: [], ends: [])
        XCTAssertEqual(rows.count, 2)
        // The countdown ranks ahead of the count-up whatever their landings said.
        XCTAssertEqual(rows[0].name, "Clarity")
        XCTAssertEqual(rows[0].mode, .countdown)
        XCTAssertEqual(rows[0].durationMs, 60_000)
        XCTAssertEqual(rows[1].mode, .elapsed)
        XCTAssertNil(rows[1].durationMs, "a count-up carries no number")

        // The end instant is the half early warning needs.
        XCTAssertEqual(timerEndsAt(rows[0]), 61_000)
        XCTAssertNil(timerEndsAt(rows[1]))
    }

    func testAPermanentRowHasNoClockAndSortsLast() {
        let perm = with(buff("Illusion: Wood Elf", 500, nil), ["permanent": true])
        let rows = buildTimerRows(active: [perm, buff("Levitate", 9_000, nil)], holds: [], ends: [])
        XCTAssertEqual(rows[0].name, "Levitate")
        XCTAssertEqual(rows[1].mode, .permanent)
        XCTAssertNil(timerEndsAt(rows[1]))
    }

    func testAReadingIsTheRowsOwnNumbersAgainstAClockTheCallerBrought() {
        let rows = buildTimerRows(active: [buff("Clarity", 1_000, 60_000)], holds: [], ends: [])
        let half = timerReading(rows[0], 31_000)
        XCTAssertEqual(half.elapsedMs, 30_000)
        XCTAssertEqual(half.remainingMs, 30_000)
        XCTAssertLessThan(abs(half.fraction - 0.5), 1e-9)
        XCTAssertFalse(half.overdue)
        // A countdown never reads negative; it reads overdue.
        let past = timerReading(rows[0], 200_000)
        XCTAssertEqual(past.remainingMs, 0)
        XCTAssertTrue(past.overdue)
        // A clock behind the landing is clamped rather than negative.
        XCTAssertEqual(timerReading(rows[0], 0).elapsedMs, 0)
    }

    func testAHoldWinsOverTheActiveInstanceDescribingTheSameMez() {
        // One mez seen twice: the catalog matcher made an ActiveBuff of the landing sentence and the
        // CC ledger made a hold of its sibling.
        let mez = with(buff("Mesmerization", 1_000, 96_000),
                       ["self": false, "cls": "debuff", "target": "a sand giant"])
        let rows = buildTimerRows(
            active: [mez],
            holds: [hold("a sand giant", "a sand giant", "Mesmerization", 1_000)],
            ends: [])
        XCTAssertEqual(rows.count, 1, "one row, not two")
        XCTAssertEqual(rows[0].kind, .cc)
        XCTAssertEqual(rows[0].targetKey, "a sand giant")
    }

    func testACcEndClearsAnInstanceTheBuffsModelNeverHeardAbout() {
        let mez = with(buff("Mesmerization", 1_000, 96_000),
                       ["self": false, "cls": "debuff", "target": "A Sand Giant"])
        let ends = [CcEnd(key: "a sand giant", ts: 5_000, spell: "Mesmerization VII")]
        XCTAssertTrue(buildTimerRows(active: [mez], holds: [], ends: ends).isEmpty)
        // An end BEFORE the landing is a different hold and clears nothing.
        let earlier = [CcEnd(key: "a sand giant", ts: 500, spell: nil)]
        XCTAssertEqual(buildTimerRows(active: [mez], holds: [], ends: earlier).count, 1)
    }

    func testSelfRowsComeFirstAndTargetsArriveInBlocks() {
        let onPet = with(buff("Symbol of Ryltan", 1_000, 30_000),
                         ["self": false, "target": "Gybartik"])
        let onAlly = with(buff("Valor", 1_000, 10_000), ["self": false, "target": "Rowel"])
        let rows = buildTimerRows(active: [onPet, onAlly, buff("Clarity", 4_000, 90_000)],
                                  holds: [], ends: [])
        XCTAssertEqual(rows[0].group, .selfGroup)
        XCTAssertEqual(rows[0].name, "Clarity")
        // Groups are ordered by their SOONEST row, so Rowel's 10 s Valor pulls that block first.
        XCTAssertEqual(rows[1].targetKey, "rowel")
        XCTAssertEqual(rows[2].targetKey, "gybartik")

        // The flat order is the same rows sorted soonest-first, blocks ignored.
        let flat = orderTimerRows(rows, groupByTarget: false)
        XCTAssertEqual(flat.map(\.name), ["Valor", "Symbol of Ryltan", "Clarity"])
        // Grouping by target hands the projection back untouched.
        XCTAssertEqual(orderTimerRows(rows, groupByTarget: true), rows)
    }

    func testACalmLineIsTheOneBuffThatBelongsToTheDebuffsWindow() {
        let pacify = with(buff("Pacify", 1_000, 60_000),
                          ["self": false, "target": "an icy terror", "calmsTarget": true])
        var rows = buildTimerRows(active: [pacify], holds: [], ends: [])
        XCTAssertEqual(rows[0].kind, .buff)
        XCTAssertEqual(timerRowSurface(rows[0]), .debuffs)
        // An ordinary buff on the very same kind of target is still a BUFF row: nothing here reads
        // `group`, `target` or `disposition`.
        let valor = with(buff("Valor", 1_000, 60_000), ["self": false, "target": "an icy terror"])
        rows = buildTimerRows(active: [valor], holds: [], ends: [])
        XCTAssertEqual(timerRowSurface(rows[0]), .buffs)
    }

    func testAnUnresolvedHoldIsAFamilyAndSaysSo() {
        var h = hold("a sand giant", "a sand giant", nil, 1_000)
        h.candidates = ["Mesmerize", "Mesmerization"]
        h.durationMs = nil
        var rows = buildTimerRows(active: [], holds: [h], ends: [])
        XCTAssertEqual(rows[0].name, "Mesmerize / Mesmerization")
        XCTAssertTrue(rows[0].ambiguous)
        XCTAssertEqual(rows[0].mode, .elapsed)
        XCTAssertEqual(rows[0].id, "cc|a sand giant|mesmerize+mesmerization")

        // A hold with no candidates at all still draws something readable.
        var bare = hold("a sand giant", "a sand giant", nil, 1_000)
        bare.candidates = []
        rows = buildTimerRows(active: [], holds: [bare], ends: [])
        XCTAssertEqual(rows[0].name, "Crowd control")
    }
}
