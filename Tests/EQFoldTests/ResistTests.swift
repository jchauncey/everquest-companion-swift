// The resist fold's own unit tests, ported from the `#[cfg(test)]` modules at the bottom of
// fold/src/modules/resist/{ledger,world,catalog,songs,cast_state,ledger_file}.rs. They pin the
// numbers the golden snapshots cannot see: the week arithmetic, the pooling key, the histogram
// give-up, the pulse reconstruction and the file's exact bytes.
import XCTest
import EQLog
import EQCompanionCore
@testable import EQFold

final class ResistTests: XCTestCase {
    // MARK: - ledger.rs

    func testTheIsoWeekBelongsToTheYearContainingItsThursday() {
        // 2026-08-19 is a Wednesday in ISO week 34.
        XCTAssertEqual(ResistLedger.isoWeekKey(1_787_184_000_000), "2026-W34")
        // 1970-01-01 was a Thursday, so epoch week zero is 1970-W01.
        XCTAssertEqual(ResistLedger.isoWeekKey(0), "1970-W01")
        // The year-boundary rule: 2019-12-30 (a Monday) is already 2020-W01.
        XCTAssertEqual(ResistLedger.isoWeekKey(1_577_664_000_000), "2020-W01")
        // …and 2021-01-01 (a Friday) is still 2020-W53.
        XCTAssertEqual(ResistLedger.isoWeekKey(1_609_459_200_000), "2020-W53")
        // Zero-padded to two digits, because the string is compared lexicographically.
        XCTAssertEqual(ResistLedger.isoWeekKey(1_704_672_000_000), "2024-W02")
    }

    func testTheLaterWeekIsAStringCompareAndAbsentLoses() {
        XCTAssertEqual(ResistLedger.laterWeek(nil, "2026-W01"), "2026-W01")
        XCTAssertEqual(ResistLedger.laterWeek("2026-W01", nil), "2026-W01")
        XCTAssertNil(ResistLedger.laterWeek(nil, nil))
        XCTAssertEqual(ResistLedger.laterWeek("2026-W52", "2027-W01"), "2027-W01")
    }

    func testTheHistogramGivesUpPastTheCapAndFoldsWhatItHadIntoLands() {
        let row = ResistRow(
            spec: ResistRowSpec(mobKey: "a rat", spellKey: "shock of frost", family: .cast,
                                casterKind: .selfCast, overchannel: false, week: "2026-W34"),
            firstTs: 0, lastTs: 0)
        for n in 0..<Int64(ResistLedger.maxDistinctDamageValues) {
            ResistLedger.addDamage(row, n)
        }
        XCTAssertEqual(row.dmg.count, ResistLedger.maxDistinctDamageValues)
        XCTAssertFalse(row.variable)
        ResistLedger.addDamage(row, 999)
        XCTAssertTrue(row.variable)
        XCTAssertTrue(row.dmg.isEmpty)
        // The 32 it had, plus the one that broke the cap.
        XCTAssertEqual(row.land, Int64(ResistLedger.maxDistinctDamageValues) + 1)
        ResistLedger.addDamage(row, 1)
        XCTAssertEqual(row.land, Int64(ResistLedger.maxDistinctDamageValues) + 2)
    }

    func testTheRowKeyStatesTheClassCountOnlyWhereItChangesRc() {
        let base = ResistRowSpec(mobKey: "a rat", zone: "Innothule Swamp", spellKey: "malosi",
                                 family: .cast, casterKind: .selfCast, casterLevel: 51, mobLevel: 20,
                                 mobLevelLo: 18, mobLevelHi: 22, debuffs: "", rank: 0,
                                 overchannel: false, casterClasses: 3, week: "2026-W34")
        // The zone and the catalog range ride the row and are not in the key.
        XCTAssertEqual(ResistLedger.rowKey(base), "a rat|malosi|cast|self|51|20||0|-||2026-W34")
        var oc = base
        oc.overchannel = true
        XCTAssertEqual(ResistLedger.rowKey(oc), "a rat|malosi|cast|self|51|20||0|oc|3|2026-W34")
        var unknown = base
        unknown.overchannel = nil
        unknown.casterLevel = nil
        unknown.mobLevel = nil
        // Three empties in a row: the two unknown levels and the empty debuff list.
        XCTAssertEqual(ResistLedger.rowKey(unknown), "a rat|malosi|cast|self||||0|?||2026-W34")
    }

    // MARK: - world.rs

    func testATargetIsACreatureByShapeOrByTheCatalogAndNeverByBeingStruck() {
        let v = TargetVerdicts()
        XCTAssertTrue(v.isMobTarget("a froglok ton knight"))
        XCTAssertTrue(v.isMobTarget("A fire giant warrior"))
        // A one-word capitalized name the catalog never heard of is a person — the safe direction.
        XCTAssertFalse(v.isMobTarget("Dranix"))
        // …and self is refused by identity first, because the catalog holds a row folding to `you`.
        XCTAssertFalse(v.isMobTarget("You"))
        XCTAssertFalse(v.isMobTarget("yourself"))
        // A proper-named creature the committed catalog knows is admitted despite the shape.
        XCTAssertTrue(v.isMobTarget("Innoruuk"))
    }

    func testADebuffWindowClosesOnItsOwnClockAndSortsWhatIsLeft() {
        let d = DebuffWindows()
        d.open("a rat", "tashani", 0)
        d.open("a rat", "malosi", 1_000)
        XCTAssertEqual(d.active("a rat", 2_000), "malosi|tashani")
        // The window is closed at `until <= ts`, so the tash is gone one ms past its end.
        XCTAssertEqual(d.active("a rat", DEBUFF_WINDOW_MS), "malosi")
        XCTAssertEqual(d.active("a rat", DEBUFF_WINDOW_MS + 1_000), "")
        XCTAssertEqual(d.active("a bat", 0), "")
    }

    func testTheCatalogLevelFoldsARangeToItsMidpointAndAConBeatsIt() {
        let levels = MobLevels()
        // The alias table is what lets a `/con` of the short spelling answer the long one.
        levels.note("innoruuk", 61)
        let fact = levels.levelOf("innoruuk, the prince of hate", "Innoruuk, the Prince of Hate")
        XCTAssertEqual(fact?.level, 61)
        XCTAssertEqual(fact?.from, "con")
    }

    // MARK: - catalog.rs

    func testTheCatalogLevelTextIsReadOrRefusedAndNeverGuessed() {
        XCTAssertTrue(ResistCatalog.parseCatalogLevel("39").map { $0 == (39, 39) } ?? false)
        XCTAssertTrue(ResistCatalog.parseCatalogLevel("39 - 43").map { $0 == (39, 43) } ?? false)
        XCTAssertTrue(ResistCatalog.parseCatalogLevel("45-50").map { $0 == (45, 50) } ?? false)
        XCTAssertNil(ResistCatalog.parseCatalogLevel("unknown"))
        XCTAssertNil(ResistCatalog.parseCatalogLevel(nil))
        // hi < lo, and a level above 200, are both refusals rather than repairs.
        XCTAssertNil(ResistCatalog.parseCatalogLevel("50-45"))
        XCTAssertNil(ResistCatalog.parseCatalogLevel("0"))
        XCTAssertNil(ResistCatalog.parseCatalogLevel("300"))
    }

    func testTheRosterStatesWhichSpellingsAreOneCreature() {
        let id = ResistCatalog.resolveMobIdentity("Innoruuk, the Prince of Hate")
        XCTAssertTrue(id.aliased, "the roster names both spellings")
        XCTAssertTrue(id.keys.contains("innoruuk"))
        let plain = ResistCatalog.resolveMobIdentity("a giant rat")
        XCTAssertFalse(plain.aliased)
        XCTAssertEqual(plain.keys, ["a giant rat"])
        XCTAssertEqual(plain.canonical, "a giant rat")
    }

    func testTheCommittedMobCatalogAnswersByEitherSpelling() {
        // The page's `|name` is the spelling a `/con` prints; the folded key finds it any casing.
        XCTAssertTrue(ResistCatalog.catalogKnows("a Alchemist`s Acolyte"))
        XCTAssertTrue(ResistCatalog.catalogKnows("A ALCHEMIST'S ACOLYTE"))
        XCTAssertFalse(ResistCatalog.catalogKnows("Dranix"))
    }

    func testTheCasterClassCountAdmitsOnlyTheSevenPureCasters() {
        XCTAssertEqual(ResistCatalog.casterClassCount(["PAL", "ENC", "SHM"]), 2)
        XCTAssertEqual(ResistCatalog.casterClassCount([]), 0)
        XCTAssertEqual(ResistCatalog.casterClassCount([" wiz "]), 1)
    }

    // MARK: - songs.rs

    private func pulses(_ out: [SongOut]) -> [(Int64, Bool)] {
        out.compactMap { o in
            if case .pulse(let p) = o { return (p.ts, p.witnessed) }
            return nil
        }
    }

    private func assertPulses(_ got: [(Int64, Bool)], _ want: [(Int64, Bool)],
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.map(\.0), want.map(\.0), file: file, line: line)
        XCTAssertEqual(got.map(\.1), want.map(\.1), file: file, line: line)
    }

    func testATwelveSecondGapInterpolatesExactlyOnePulseAndARestartDropsIt() {
        var p = SongPulses()
        var out: [SongOut] = []
        p.witness("largo's melodic binding", 0, "a rat", &out)
        p.witness("largo's melodic binding", 12_000, "a rat", &out)
        // Closing the first pulse emitted it; the interpolated 6 s pulse waits for the second close.
        p.flush(&out)
        assertPulses(pulses(out), [(0, true), (6_000, false), (12_000, true)])

        p = SongPulses()
        out = []
        p.witness("largo's melodic binding", 0, nil, &out)
        p.noteSing("largo's melodic binding", 7_000, &out)
        p.witness("largo's melodic binding", 12_000, nil, &out)
        p.flush(&out)
        // The restart re-anchors: the 6 s interior pulse is before it and is dropped.
        assertPulses(pulses(out), [(0, true), (12_000, true)])
    }

    func testNothingIsInterpolatedAcrossAGapLongerThanARun() {
        let p = SongPulses()
        var out: [SongOut] = []
        p.witness("s", 0, nil, &out)
        p.witness("s", SONG_RUN_GAP_MS + 6_000, nil, &out)
        p.flush(&out)
        assertPulses(pulses(out), [(0, true), (SONG_RUN_GAP_MS + 6_000, true)])
    }

    func testTheAurasHeartbeatBeatsSixSecondArithmeticInsideAGap() {
        let p = SongPulses()
        var out: [SongOut] = []
        p.noteHeartbeat(5_500)
        p.witness("s", 0, nil, &out)
        p.witness("s", 12_000, nil, &out)
        p.flush(&out)
        // 5,500 — the instant the log printed — rather than the arithmetic 6,000.
        assertPulses(pulses(out), [(0, true), (5_500, false), (12_000, true)])
    }

    func testEverythingInsideOneSecondOfAWitnessIsTheSamePulse() {
        let p = SongPulses()
        var out: [SongOut] = []
        p.witness("s", 0, "a rat", &out)
        p.witness("s", 800, "a bat", &out)
        p.flush(&out)
        guard case .pulse(let pulse) = out[0] else { return XCTFail("a pulse") }
        XCTAssertEqual(pulse.resisted, ["a rat", "a bat"])
        XCTAssertEqual(out.count, 1)
    }

    // MARK: - cast_state.rs

    private func armed(_ spell: String, _ ts: Int64, _ kind: ResistCasterKind) -> Armed {
        Armed(spellKey: spell, display: spell, ts: ts, kind: kind, level: nil, rank: 0,
              overchannel: nil, damaged: [])
    }

    func testAnOutcomeReadsOnlyItsOwnCastersArmedCast() {
        let casts = ArmedCasts()
        casts.arm(armed("shock of frost", 0, .selfCast))
        XCTAssertNotNil(casts.ownedBy(.selfCast, "shock of frost", 1_000))
        // A charmed pet throwing the same spell must not inherit your rank.
        XCTAssertNil(casts.ownedBy(.npc, "shock of frost", 1_000))
        // Past the join window, and before the cast, nothing is claimable.
        XCTAssertNil(casts.ownedBy(.selfCast, "shock of frost", CAST_JOIN_MS + 1))
        casts.disarm("shock of frost")
        XCTAssertNil(casts.ownedBy(.selfCast, "shock of frost", 1))
    }

    func testALandingSentenceConsumesTheCastACandidateNames() {
        let casts = ArmedCasts()
        casts.arm(armed("clarity", 0, .selfCast))
        casts.arm(armed("malosi", 1, .selfCast))
        let names = ["Clarity II"]
        XCTAssertEqual(casts.take(2, names)?.spellKey, "clarity")
        // …and it is gone, so the same sentence cannot claim it twice.
        XCTAssertNil(casts.take(2, names))
        // With no candidate list at all the newest in-window cast is taken.
        XCTAssertEqual(casts.take(2, nil)?.spellKey, "malosi")
    }

    func testAnObservationWithNoCastBehindItIsAProcAndAStrangersIsUnknowable() {
        let state = CastState()
        XCTAssertEqual(state.invocationFor(.selfCast, nil), false)
        XCTAssertEqual(state.invocationFor(.selfCast, .some(true)), true)
        XCTAssertNil(state.invocationFor(.pc, .some(true)))
        XCTAssertNil(state.invocationFor(.npc, nil))
        // Nothing has stated the invocation until a line does.
        XCTAssertNil(state.overchannel())
        state.noteInvocation("empowering")
        XCTAssertEqual(state.overchannel(), false)
        state.noteInvocation(OVERCHANNEL_INVOCATION)
        XCTAssertEqual(state.overchannel(), true)
    }

    // MARK: - ledger_file.rs

    /// A hand-written fixture in the app's exact shape, so every format claim is checked against these
    /// bytes rather than against another serializer.
    static let appFile = """
    {"version":3,"sources":[\
    {"key":"baseline","rows":[{"mobKey":"a rat","spellKey":"shock of frost","family":"cast",\
    "casterKind":"self","casterLevel":null,"mobLevel":null,"debuffs":"","rank":0,\
    "overchannel":false,"resist":9,"land":9,"dmg":{},"firstTs":0,"lastTs":0}]},\
    {"key":"primitive_freeport","rows":[\
    {"mobKey":"a rat","zone":"Innothule Swamp","spellKey":"malosi","family":"cast",\
    "casterKind":"self","casterLevel":51,"mobLevel":20,"mobLevelLo":18,"mobLevelHi":22,\
    "debuffs":"","rank":2,"overchannel":true,"casterClasses":3,"week":"2026-W34","resist":4,\
    "land":7,"dmg":{"9":2,"10":5},"firstTs":1000,"lastTs":2000},\
    {"mobKey":"a bat","spellKey":"chant of frost","family":"song","casterKind":"npc",\
    "casterLevel":null,"mobLevel":null,"debuffs":"","rank":0,"overchannel":null,\
    "week":"2026-W34","resist":1,"land":0,"dmg":{},"variable":true,"firstTs":5,"lastTs":6}\
    ]}]}
    """

    private func primitive(_ load: ResistLedgerLoad) -> LedgerSource {
        load.sources.first { $0.key == "primitive_freeport" }!
    }

    private func rows(_ source: LedgerSource) -> [ResistRowFile] {
        source.rows.compactMap { ResistRowFile.from($0) }
    }

    func testTheAppsOwnBytesReadAndTheBaselineBucketIsRefused() {
        let load = ResistLedgerFile.readLedger(ResistTests.appFile)
        XCTAssertNil(load.notice, "an ordinary read says nothing")
        // One source: `baseline` was rejected on read.
        XCTAssertEqual(load.sources.count, 1)
        let r = rows(primitive(load))
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].mobKey, "a rat")
        XCTAssertEqual(r[0].zone, "Innothule Swamp")
        XCTAssertEqual(r[0].casterKind, .selfCast)
        XCTAssertEqual(r[0].overchannel, true)
        XCTAssertEqual(r[0].casterClasses, 3)
        XCTAssertEqual(r[0].dmg["10"], 5)
        XCTAssertEqual(r[1].family, .song)
        XCTAssertEqual(r[1].casterKind, .npc)
        XCTAssertNil(r[1].overchannel)
        XCTAssertEqual(r[1].variable, true)
    }

    func testARowSurvivesTheRoundTripThroughTheFoldShapeByteForByte() {
        let load = ResistLedgerFile.readLedger(ResistTests.appFile)
        let row = rows(primitive(load))[0]
        var before = ""
        row.write(&before)
        var after = ""
        ResistRowFile.of(row.intoRow()).write(&after)
        XCTAssertEqual(before, after)
        // …and the bytes are the app's own: `null` for the three nullable fields, absent for the
        // optional ones the row does not carry.
        XCTAssertEqual(before, #"{"mobKey":"a rat","zone":"Innothule Swamp","spellKey":"malosi","family":"cast","casterKind":"self","casterLevel":51,"mobLevel":20,"mobLevelLo":18,"mobLevelHi":22,"debuffs":"","rank":2,"overchannel":true,"casterClasses":3,"week":"2026-W34","resist":4,"land":7,"dmg":{"9":2,"10":5},"firstTs":1000,"lastTs":2000}"#)
    }

    func testTheHistogramWritesInNumericOrderNotLexicographic() {
        var dmg: [String: Int64] = [:]
        for n in [10, 9, 100, 2] { dmg[String(n)] = 1 }
        var text = ""
        ResistHistogram.write(&text, dmg)
        XCTAssertEqual(text, #"{"2":1,"9":1,"10":1,"100":1}"#)
    }

    func testAMissingOrCorruptOrStaleFileReadsAsEmpty() {
        XCTAssertTrue(ResistLedgerFile.readLedger("").sources.isEmpty)
        XCTAssertTrue(ResistLedgerFile.readLedger(#"{"version":3,"sources":["#).sources.isEmpty)
        XCTAssertNotNil(ResistLedgerFile.readLedger(#"{"version":3,"sources":["#).notice)
        // A version this build does not speak: empty, and silent — a planned discard.
        let stale = ResistLedgerFile.readLedger(#"{"version":2,"sources":[{"key":"a","rows":[]}]}"#)
        XCTAssertTrue(stale.sources.isEmpty)
        XCTAssertNil(stale.notice)
        // Parsed, ours, but the source is not a shape we can seed from.
        XCTAssertTrue(ResistLedgerFile.readLedger(#"{"version":3,"sources":[{"key":"a","rows":{}}]}"#).sources.isEmpty)
    }

    func testABucketWhoseRowsWillNotParseIsDroppedWholeAndSaysSo() {
        let load = ResistLedgerFile.readLedger(
            #"{"version":3,"sources":[{"key":"a","rows":[{"mobKey":"x"}]},{"key":"b","rows":[]}]}"#)
        XCTAssertEqual(load.sources.count, 1)
        XCTAssertEqual(load.sources[0].key, "b")
        XCTAssertNotNil(load.notice)
    }

    func testTheWriteDropsTheBaselineAndTheEmptiesAndSortsBothLevels() {
        let load = ResistLedgerFile.readLedger(ResistTests.appFile)
        let store = ResistLedgerStore()
        ResistLedgerFile.seedStore(store, load.sources)
        // A baseline bucket and an empty bucket, both deliberate: neither may be written.
        ResistLedgerFile.seedStore(store, [LedgerSource(key: BASELINE_SOURCE_KEY,
                                                        rows: [primitive(load).rows[0]])])
        _ = store.bucketMut("zzz_empty")
        // …and a second real bucket whose key sorts BEFORE the first, so the sort is proven to reorder
        // rather than merely to preserve.
        ResistLedgerFile.seedStore(store, [LedgerSource(key: "aardvark_bertox",
                                                        rows: [primitive(load).rows[1]])])

        let file = ResistLedgerFile.ledgerFileOf(store)
        XCTAssertEqual(file.version, 3)
        XCTAssertEqual(file.sources.map(\.key), ["aardvark_bertox", "primitive_freeport"])
        // Rows by pooling key ascending, which reverses the order the fixture listed them in.
        let written = file.sources[1].rows
        XCTAssertEqual(written[0].mobKey, "a bat")
        XCTAssertEqual(written[1].mobKey, "a rat")

        // `version` first — the app's truncation salvage reads it off the head of a file it cannot
        // parse, so this is a compatibility assertion and not a cosmetic one.
        let text = file.serializedString()
        XCTAssertTrue(text.hasPrefix(#"{"version":3,"sources":[{"key":"#), text)
    }

    func testSeedingTheSameBucketTwiceReplacesItsRowsRatherThanDoublingThem() {
        let load = ResistLedgerFile.readLedger(ResistTests.appFile)
        let store = ResistLedgerStore()
        ResistLedgerFile.seedStore(store, load.sources)
        let rowsOnce = store.counts().rows
        // A second seed of the same bytes, which is the shape a cold launch has. Rows are keyed by
        // their pooling key, so they land on themselves.
        ResistLedgerFile.seedStore(store, load.sources)
        XCTAssertEqual(store.counts().rows, rowsOnce)
        XCTAssertEqual(rowsOnce, 2)
    }

    func testBeginSourceDiscardsTheSeededBucketSoAReFoldReplacesIt() {
        let load = ResistLedgerFile.readLedger(ResistTests.appFile)
        let store = ResistLedgerStore()
        ResistLedgerFile.seedStore(store, load.sources)
        XCTAssertEqual(store.counts().rows, 2)
        // The character about to be folded has its bucket discarded before a byte is read, because the
        // fold is about to state that bucket's whole content again.
        store.beginSource("primitive_freeport")
        XCTAssertEqual(store.counts().rows, 0)
        // …and a bucket for a character we are NOT folding is untouched, because nothing can
        // re-derive it.
        ResistLedgerFile.seedStore(store, [LedgerSource(key: "other_bertox",
                                                        rows: [primitive(load).rows[0]])])
        store.beginSource("primitive_freeport")
        XCTAssertEqual(store.counts().rows, 1)
    }
}
