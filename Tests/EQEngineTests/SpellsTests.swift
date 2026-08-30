// The client-table wave, tested at the laws the four Rust files state: `fold/src/spells_us.rs`,
// `fold/src/dbstr.rs`, `engined/src/spells.rs` and `engined/src/spell_search.rs`, unit test for unit
// test, plus the recorded golden shapes for `spells.search` and `resist.spell`.
//
// The rows below are HAND-AUTHORED, and that is a rule: the client table is Daybreak's file and no
// slice of it may enter this repo. The numbers are the ones the Rust suites transcribed from a real
// install, so all three suites claim the same thing about the same bytes.
import XCTest
import EQEngine
import EQFold
import EQCompanionCore

private typealias U = SpellsUs

/// A row of 173 caret-delimited fields, with the class columns defaulted to `255` (cannot use).
private func row(_ fields: [(Int, String)]) -> String {
    var f = [String](repeating: "0", count: 173)
    for i in 0..<U.F_CLASS_COUNT { f[U.F_CLASS_FIRST + i] = "255" }
    for (i, v) in fields { f[i] = v }
    return f.joined(separator: "^")
}

private func one(_ fields: [(Int, String)], file: StaticString = #filePath, line: UInt = #line) -> SpellInfo {
    let table = U.parseSpellsUs(row(fields))
    XCTAssertEqual(table.count, 1, "the row parsed to exactly one entry", file: file, line: line)
    return table.values.first!
}

/// `Number(x) || 0` over a field that may be absent, as `rowInfo` reads one.
private func orZero(_ s: String?) -> Double { U.orZero(U.jsNumber(s ?? "")) }

// MARK: - spells_us.rs

final class SpellsUsTests: XCTestCase {
    func testJSNumberIsJavaScriptsNumberAndNotSwiftsParser() {
        XCTAssertEqual(U.jsNumber(""), 0.0, "the empty string is zero, never an error")
        XCTAssertEqual(U.jsNumber("   "), 0.0, "…and so is whitespace, trimmed first")
        XCTAssertEqual(U.jsNumber("  12  "), 12.0)
        XCTAssertEqual(U.jsNumber("0x1f"), 31.0, "a radix prefix is a number")
        XCTAssertTrue(U.jsNumber("-0x10").isNaN, "…and takes no sign")
        XCTAssertEqual(U.jsNumber("1e3"), 1000.0)
        XCTAssertEqual(U.jsNumber("+7"), 7.0)
        XCTAssertEqual(U.jsNumber("-1.5"), -1.5)
        XCTAssertEqual(U.jsNumber("Infinity"), .infinity)
        XCTAssertEqual(U.jsNumber("-Infinity"), -.infinity)
        XCTAssertEqual(U.jsNumber("0o17"), 15.0)
        XCTAssertEqual(U.jsNumber("0b101"), 5.0)
        // …and the spellings Swift accepts and JavaScript does not.
        for spelled in ["inf", "infinity", "INFINITY", "NaN", "nan", "abc", "1.2.3", "1e", ".", "0x"] {
            XCTAssertTrue(U.jsNumber(spelled).isNaN, "Number(\(spelled)) is NaN")
        }
    }

    func testTheOrZeroIdiomIsFalsinessAndNotADefault() {
        XCTAssertEqual(orZero("abc"), 0.0, "NaN falls to zero")
        XCTAssertEqual(orZero(nil), 0.0, "an absent field falls to zero")
        XCTAssertEqual(orZero("-0"), 0.0, "…and so does negative zero")
        XCTAssertTrue(orZero("-0").sign == .plus, "the zero it falls to is a positive one")
        XCTAssertEqual(orZero("1500"), 1500.0)
    }

    /// Tashani (id 677) — the row that settled the slot layout. In `2|50|-10|0|101|23`, calc 101 is
    /// "base + level/2, capped" and 23 is the cap.
    func testTashaniIsAMagicDebuffWithACapOfTwentyThree() {
        let info = one([(U.F_ID, "677"), (U.F_NAME, "Tashani"), (U.F_RESIST_TYPE, "1"),
                        (U.F_SLOTS, "2|50|-10|0|101|23"), (U.F_CLASS_FIRST + 13, "16")])
        XCTAssertEqual(info.axis, .magic)
        XCTAssertEqual(info.debuffSlots.count, 1)
        let d = info.debuffSlots[0]
        XCTAssertEqual(d.axis, .magic)
        XCTAssertEqual(d.base, -10.0)
        XCTAssertEqual(d.calc, 101.0)
        XCTAssertEqual(d.max, 23.0)
        XCTAssertFalse(info.song, "an enchanter row is not a song")
    }

    /// Malaisement — the `all resists` family, effect 111, which is a slot axis and never a spell's.
    func testTheTashAndMaloFamilyCarriesTheAllAxis() {
        let info = one([(U.F_ID, "111"), (U.F_NAME, "Malaisement"),
                        (U.F_SLOTS, "1|111|-20|0|101|40"), (U.F_CLASS_FIRST + 10, "44")])
        XCTAssertEqual(info.debuffSlots.count, 1)
        XCTAssertEqual(info.debuffSlots[0].axis, .all)
        XCTAssertEqual(info.debuffSlots[0].max, 40.0)
    }

    func testARiderBelowTheMagnitudeFloorOpensNoWindow() {
        let info = one([(U.F_ID, "1"), (U.F_NAME, "Solon's Bewitching Bravura"),
                        (U.F_SLOTS, "1|22|1|0|100|50$2|50|-1|0|100|1")])
        XCTAssertTrue(info.debuffSlots.isEmpty)
    }

    func testAResistBuffIsNeverADebuffWindow() {
        let info = one([(U.F_ID, "2"), (U.F_NAME, "Resist Fire"), (U.F_SLOTS, "1|46|40|0|100|40")])
        XCTAssertTrue(info.debuffSlots.isEmpty)
    }

    /// The class order is the file's: Tashani is an enchanter spell (13), Chaos Flux a wizard's (11),
    /// Malaisement a necromancer's (10), and the bard is column 7.
    func testTheClassOrderIsTheFiles() {
        XCTAssertEqual(U.classColumn("ENC"), 13)
        XCTAssertEqual(U.classColumn("WIZ"), 11)
        XCTAssertEqual(U.classColumn("NEC"), 10)
        XCTAssertEqual(U.classColumn("BRD"), U.CLASS_BARD)
        XCTAssertEqual(U.classColumn("SHD"), 4)
        XCTAssertNil(U.classColumn("NOT A CLASS"))
        XCTAssertEqual(U.CLASS_ORDER.sorted(),
                       ["BER", "BRD", "BST", "CLR", "DRU", "ENC", "MAG", "MNK", "NEC", "PAL", "RNG",
                        "ROG", "SHD", "SHM", "WAR", "WIZ"],
                       "the same sixteen codes classCombo.ts CLASS_ABBRS carries")
    }

    func testAMezCarriesItsLevelCapOffTheFirstSlot() {
        let info = one([(U.F_ID, "307"), (U.F_NAME, "Mesmerization"), (U.F_SLOTS, "1|31|2|0|100|55")])
        XCTAssertEqual(info.levelCap, 55.0)
    }

    /// Chaos Flux — a stun rider capped at 55 on a later slot. Being above it costs the stun, not the
    /// nuke, so the cap must not reach the whole spell.
    func testARidersCapNeverBecomesTheSpellsCap() {
        let info = one([(U.F_ID, "350"), (U.F_NAME, "Chaos Flux"),
                        (U.F_SLOTS, "1|50|-20|0|101|30$2|31|2|0|100|55")])
        XCTAssertNil(info.levelCap, "slot 2's cap is not the spell's")
        XCTAssertEqual(info.debuffSlots.count, 1, "…and slot 1 is still a real window")
    }

    func testTheRecastIsFieldTenAndFieldNineIsIgnored() {
        let info = one([(U.F_ID, "4093"), (U.F_NAME, "Odium"), (9, "1500"), (U.F_RECAST_MS, "6000")])
        XCTAssertEqual(info.recastMs, 6000.0)
    }

    func testAZeroInAnAbsentMeansNothingColumnIsAnAbsence() {
        let info = one([(U.F_ID, "1292"), (U.F_NAME, "Complete Heal"), (9, "1500"),
                        (U.F_RECAST_MS, "0"), (U.F_AE_MAX_TARGETS, "0"), (U.F_MANA, "350")])
        XCTAssertNil(info.recastMs)
        XCTAssertNil(info.aeMaxTargets)
        XCTAssertEqual(info.mana, 350.0, "…while a positive one is carried")
    }

    func testADurationRowMarksItsHitpointSlotsPerTick() {
        let info = one([(U.F_ID, "4093"), (U.F_NAME, "Odium"), (U.F_DURATION_FORMULA, "7"),
                        (U.F_DURATION, "5"), (U.F_SLOTS, "2|0|-217|0|103|325")])
        XCTAssertEqual(info.hp.count, 1)
        XCTAssertTrue(info.hp[0].perTick)
        XCTAssertEqual(info.hpDuration, U.HpDuration(formula: 7.0, value: 5.0))
        XCTAssertEqual(info.damageSlot, U.DamageSlot(base: -217.0, max: 325.0, calc: 103.0))
    }

    func testAnInstantRowHasNoDurationAndItsSlotIsNotPerTick() {
        let info = one([(U.F_ID, "3"), (U.F_NAME, "Bolt of Karana"), (U.F_DURATION_FORMULA, "0"),
                        (U.F_SLOTS, "1|0|-200|0|100|200")])
        XCTAssertEqual(info.hp.count, 1)
        XCTAssertFalse(info.hp[0].perTick)
        XCTAssertNil(info.hpDuration)
    }

    /// A formula with no hitpoint slot writes no duration — the nesting in `rowInfo`.
    func testADurationOnARowWithNoHitpointSlotWritesNothing() {
        let info = one([(U.F_ID, "4"), (U.F_NAME, "Clarity"), (U.F_DURATION_FORMULA, "7"),
                        (U.F_DURATION, "50"), (U.F_SLOTS, "1|15|10|0|100|10")])
        XCTAssertTrue(info.hp.isEmpty)
        XCTAssertNil(info.hpDuration)
    }

    func testTheTwoOtherHitpointEffectsReachHpButNotTheDamageSlot() {
        let hot = one([(U.F_ID, "3683"), (U.F_NAME, "Ethereal Cleansing"),
                       (U.F_DURATION_FORMULA, "3"), (U.F_SLOTS, "1|100|10|0|103|100")])
        XCTAssertEqual(hot.hp.count, 1)
        XCTAssertEqual(hot.hp[0].base, 10.0)
        XCTAssertNil(hot.damageSlot, "effect 100 is not the estimator's slot")

        let song = one([(U.F_ID, "703"), (U.F_NAME, "Chords of Dissonance"),
                        (U.F_DURATION_FORMULA, "3"), (U.F_SLOTS, "1|334|-2|0|109|0"),
                        (U.F_CLASS_FIRST + U.CLASS_BARD, "5")])
        XCTAssertEqual(song.hp.count, 1)
        XCTAssertEqual(song.hp[0].base, -2.0)
        XCTAssertNil(song.damageSlot)
        XCTAssertTrue(song.song, "a bard-only row is a song")
    }

    func testBardOnlyMeansOnlyTheBard() {
        let info = one([(U.F_ID, "5"), (U.F_NAME, "Shared Thing"),
                        (U.F_CLASS_FIRST + U.CLASS_BARD, "5"), (U.F_CLASS_FIRST + 5, "12")])
        XCTAssertFalse(info.song)
    }

    /// The class-level window is `1...254`: 255 is "cannot use" and 0 is nothing.
    func testTheClassLevelWindowExcludesBothEnds() {
        for level in ["255", "0", "256"] {
            let table = U.parseSpellsUs(row([(U.F_ID, "6"), (U.F_NAME, "Unlearnable"),
                                             (U.F_CLASS_FIRST + 5, level)]))
            XCTAssertEqual(table.count, 1)
            // Unplayable rows still parse — they simply lose a key contest to a playable row.
            XCTAssertFalse(table.values.first!.song)
        }
    }

    /// Lifetap — the row that settled the category columns.
    func testLifetapCarriesTheCategoryAndSubcategoryTheScreenshotShows() {
        let info = one([(U.F_ID, "341"), (U.F_NAME, "Lifetap"), (U.F_CATEGORY, "114"),
                        (U.F_SUBCATEGORY, "43"), (U.F_CLASS_FIRST + 4, "1"), (U.F_CLASS_FIRST + 10, "1")])
        XCTAssertEqual(info.category, 114)
        XCTAssertEqual(info.subcategory, 43)
        XCTAssertEqual(info.name, "Lifetap")
        XCTAssertEqual(info.classLevels[4], 1)
        XCTAssertEqual(info.classLevels[10], 1)
        XCTAssertEqual(info.classLevels[7], 0, "the bard learns no lifetap")
    }

    func testAnUncategorisedRowReportsNoCategoryRatherThanZero() {
        let info = one([(U.F_ID, "1"), (U.F_NAME, "Uncategorised")])
        XCTAssertNil(info.category)
        XCTAssertNil(info.subcategory)
    }

    func testASubcategoryWithNoCategoryIsStillRead() {
        let info = one([(U.F_ID, "2398"), (U.F_NAME, "Destroy Mind Poison"), (U.F_SUBCATEGORY, "83")])
        XCTAssertNil(info.category)
        XCTAssertEqual(info.subcategory, 83)
    }

    func testTheClassLevelsRowHoldsALevelPerClassAndZeroForTheRest() {
        let info = one([(U.F_ID, "703"), (U.F_NAME, "Chords of Dissonance"),
                        (U.F_CLASS_FIRST + U.CLASS_BARD, "5")])
        XCTAssertEqual(info.classLevels[U.CLASS_BARD], 5)
        XCTAssertEqual(info.classLevels.filter { $0 > 0 }.count, 1)
        XCTAssertTrue(info.song)
    }

    /// `f.length < 172`, not `< 173`. The row passes and then reads `undefined` for its slots.
    func testARowWithExactlyOneHundredAndSeventyTwoFieldsIsKept() {
        var f = [String](repeating: "0", count: 172)
        f[U.F_NAME] = "Short Row"
        for i in 0..<U.F_CLASS_COUNT { f[U.F_CLASS_FIRST + i] = "255" }
        let table = U.parseSpellsUs(f.joined(separator: "^"))
        XCTAssertEqual(table.count, 1)
        let info = table.values.first!
        XCTAssertTrue(info.hp.isEmpty)
        XCTAssertTrue(info.debuffSlots.isEmpty)
        XCTAssertNil(info.levelCap)
    }

    func testARowOneFieldShorterThanThatIsDropped() {
        let f = [String](repeating: "0", count: 171)
        XCTAssertTrue(U.parseSpellsUs(f.joined(separator: "^")).isEmpty)
    }

    func testAnEmptyIdIsFiniteAndThereforeKept() {
        let table = U.parseSpellsUs(row([(U.F_ID, ""), (U.F_NAME, "No Id")]))
        XCTAssertEqual(table.count, 1)
    }

    func testANonNumericIdIsDroppedAndAnEmptyNameIsToo() {
        XCTAssertTrue(U.parseSpellsUs(row([(U.F_ID, "abc"), (U.F_NAME, "Bad Id")])).isEmpty)
        XCTAssertTrue(U.parseSpellsUs(row([(U.F_ID, "1"), (U.F_NAME, "")])).isEmpty)
        // A whitespace-only name survives the empty-name test and dies at the key test.
        XCTAssertTrue(U.parseSpellsUs(row([(U.F_ID, "1"), (U.F_NAME, "   ")])).isEmpty)
    }

    func testEmptyLinesAreSkippedAndACRLFFileStillParsesItsSlots() {
        let text = "\n" + row([(U.F_ID, "7"), (U.F_NAME, "Crlf Spell"), (U.F_SLOTS, "1|31|2|0|100|55")]) + "\r\n\n"
        let table = U.parseSpellsUs(text)
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table.values.first!.levelCap, 55.0)
    }

    func testRanksFoldOntoOneKeyAndTheFirstRowWins() {
        let text = row([(U.F_ID, "74042"), (U.F_NAME, "Scorching Arrow I"), (U.F_RESIST_ADJ, "10"),
                        (U.F_CLASS_FIRST + 3, "20")])
            + "\n" + row([(U.F_ID, "74045"), (U.F_NAME, "Scorching Arrow IV"), (U.F_RESIST_ADJ, "40"),
                          (U.F_CLASS_FIRST + 3, "50")])
        let table = U.parseSpellsUs(text)
        XCTAssertEqual(table.count, 1, "the rank tail folds both onto one key")
        XCTAssertEqual(table["scorching arrow"]?.resistAdj, 10.0, "file order decides, and the first row wins")
    }

    /// The one override on first-wins: a row no class can cast is a mob's or an item's copy.
    func testAnNPCCopyLosesToTheRowAPlayerCanLearn() {
        let text = row([(U.F_ID, "6850"), (U.F_NAME, "Chaos Flux"), (U.F_RESIST_ADJ, "99")])
            + "\n" + row([(U.F_ID, "350"), (U.F_NAME, "Chaos Flux"), (U.F_RESIST_ADJ, "-20"),
                          (U.F_CLASS_FIRST + 11, "39")])
        let table = U.parseSpellsUs(text)
        XCTAssertEqual(table.count, 1)
        XCTAssertEqual(table["chaos flux"]?.resistAdj, -20.0, "the playable row replaces the unplayable one")
    }

    func testAPlayableRowIsNeverReplacedByALaterOne() {
        let text = row([(U.F_ID, "350"), (U.F_NAME, "Chaos Flux"), (U.F_RESIST_ADJ, "-20"),
                        (U.F_CLASS_FIRST + 11, "39")])
            + "\n" + row([(U.F_ID, "6850"), (U.F_NAME, "Chaos Flux"), (U.F_RESIST_ADJ, "99")])
        XCTAssertEqual(U.parseSpellsUs(text)["chaos flux"]?.resistAdj, -20.0)
        // …not even by another playable one.
        let twoPlayable = row([(U.F_ID, "1"), (U.F_NAME, "Twice"), (U.F_RESIST_ADJ, "1"),
                               (U.F_CLASS_FIRST + 11, "39")])
            + "\n" + row([(U.F_ID, "2"), (U.F_NAME, "Twice"), (U.F_RESIST_ADJ, "2"),
                          (U.F_CLASS_FIRST + 11, "40")])
        XCTAssertEqual(U.parseSpellsUs(twoPlayable)["twice"]?.resistAdj, 1.0)
    }

    func testTheFiveAxesMapAndEverythingElseIsRefused() {
        XCTAssertEqual(U.axisFromResistType(1.0), .magic)
        XCTAssertEqual(U.axisFromResistType(2.0), .fire)
        XCTAssertEqual(U.axisFromResistType(3.0), .cold)
        XCTAssertEqual(U.axisFromResistType(4.0), .poison)
        XCTAssertEqual(U.axisFromResistType(5.0), .disease)
        for t in [0.0, 6.0, 7.0, 8.0, 9.0, -1.0] {
            XCTAssertNil(U.axisFromResistType(t), "resist type \(t)")
        }
        XCTAssertNil(U.axisFromResistType(.nan), "an unparseable type")
    }

    /// The latin-1 read and the `String` read are one parser: a high byte is a character in a NAME,
    /// never a replacement, and the two entry points must agree about it.
    func testTheLatinOneReadWidensAByteRatherThanReplacingIt() {
        let text = row([(U.F_ID, "9"), (U.F_NAME, "Caf\u{e9} Song"), (U.F_CLASS_FIRST + 11, "10")])
        let fromText = U.parseSpellsUs(text)
        // The same row as the file holds it: every scalar is < 256, so latin-1 is one byte each.
        let bytes = text.unicodeScalars.map { UInt8($0.value) }
        let fromBytes = U.parseSpellsUs(latin1: bytes)
        XCTAssertEqual(fromText, fromBytes)
        XCTAssertEqual(fromBytes["caf\u{e9} song"]?.name, "Caf\u{e9} Song")
    }
}

// MARK: - dbstr.rs

final class DbStrTests: XCTestCase {
    /// Hand-authored rows. The ids and words below are transcribed from a real install.
    private func row(_ id: String, _ ty: String, _ text: String) -> String { "\(id)^\(ty)^\(text)^0^" }

    func testTheThreeWordsTheOwnersScreenshotShowsAreRead() {
        let text = [row("114", "5", "Taps"), row("43", "5", "Health"),
                    row("33", "5", "Duration Tap"), row("76", "5", "Power Tap")].joined(separator: "\n")
        let names = DbStr.parseSpellCategories(text)
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(names[114], "Taps")
        XCTAssertEqual(names[43], "Health")
        XCTAssertEqual(names[33], "Duration Tap")
        XCTAssertEqual(names[76], "Power Tap")
    }

    func testEveryOtherNamespaceIsDropped() {
        let text = [row("114", "5", "Taps"),
                    row("114", "6", "A tooltip that happens to share an id"),
                    row("11", "10", "UNKNOWN RACE")].joined(separator: "\n")
        let names = DbStr.parseSpellCategories(text)
        XCTAssertEqual(names.count, 1, "only the spell-category namespace survives")
        XCTAssertEqual(names[114], "Taps")
    }

    func testAMalformedRowIsSkippedRatherThanGuessedAt() {
        let text = [row("", "5", "No Id"), row("abc", "5", "Not A Number"), row("7", "5", ""),
                    "7^5", "", row("114", "5", "Taps")].joined(separator: "\n")
        let names = DbStr.parseSpellCategories(text)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names[114], "Taps")
    }

    func testACRLFFileDoesNotCarryTheCarriageReturnIntoAName() {
        let names = DbStr.parseSpellCategories("114^5^Taps\r\n43^5^Health\r\n")
        XCTAssertEqual(names[114], "Taps")
        XCTAssertEqual(names[43], "Health")
        let padded = DbStr.parseSpellCategories("114^5^Taps^0^\r\n")
        XCTAssertEqual(padded[114], "Taps")
    }

    func testARepeatedIdKeepsTheFirstWord() {
        let text = [row("114", "5", "Taps"), row("114", "5", "Something Else")].joined(separator: "\n")
        XCTAssertEqual(DbStr.parseSpellCategories(text)[114], "Taps")
    }

    func testAnEmptyTableIsAnEmptyMapAndNotACrash() {
        XCTAssertTrue(DbStr.parseSpellCategories("").isEmpty)
        XCTAssertTrue(DbStr.parseSpellCategories("\n\n\n").isEmpty)
    }
}

// MARK: - engined/src/spells.rs

final class ClientSpellsTests: XCTestCase {
    private static let counter = ScratchCounter()

    private func scratch(_ tag: String) throws -> String {
        let dir = NSTemporaryDirectory() + "engined-spells-\(ProcessInfo.processInfo.processIdentifier)-\(Self.counter.next())-\(tag)"
        try FileManager.default.createDirectory(atPath: dir + "/Logs", withIntermediateDirectories: true)
        return dir
    }

    /// One 173-field row, hand-authored.
    private func row(_ id: String, _ name: String, _ resistType: String, _ slots: String) -> String {
        var f = [String](repeating: "0", count: 173)
        for i in 36..<52 { f[i] = "255" }
        f[0] = id; f[1] = name; f[29] = resistType; f[49] = "39"; f[172] = slots
        return f.joined(separator: "^")
    }

    func testTheTableSitsBesideTheInstallTheLogNames() throws {
        let dir = try scratch("path")
        let log = dir + "/Logs/eqlog_Primitive_freeport.txt"
        let spells = try XCTUnwrap(ClientSpells.besideLog(log))
        // `<eqRoot>/Logs/<log>` → `<eqRoot>/spells_us.txt`. Nothing on the wire says this.
        XCTAssertEqual(spells.path, dir + "/spells_us.txt")
        XCTAssertEqual(spells.dbstrPath, dir + "/dbstr_us.txt")
    }

    func testALogPathWithNoInstallAboveItDerivesNothing() {
        XCTAssertNil(ClientSpells.besideLog("eqlog.txt"))
    }

    func testAMissingFileIsASupportedStateAndNotAnError() throws {
        let dir = try scratch("missing")
        let spells = try XCTUnwrap(ClientSpells.besideLog(dir + "/Logs/eqlog_Primitive_freeport.txt"))
        // A folder of logs with no EverQuest behind it is a real configuration.
        XCTAssertNil(spells.table())
        XCTAssertEqual(spells.state, .missing)
        XCTAssertNil(spells.spell("Tashani"))
    }

    func testARealFileIsParsedOnceAndAnsweredPerSpell() throws {
        let dir = try scratch("ok")
        try (row("677", "Tashani", "1", "2|50|-10|0|101|23") + "\n"
             + row("350", "Chaos Flux", "1", "1|50|-20|0|101|30") + "\n")
            .write(toFile: dir + "/spells_us.txt", atomically: true, encoding: .utf8)
        let spells = try XCTUnwrap(ClientSpells.besideLog(dir + "/Logs/eqlog_Primitive_freeport.txt"))
        XCTAssertEqual(spells.state, .ok)

        let tashani = try XCTUnwrap(spells.spell("Tashani"))
        XCTAssertEqual(tashani.axis, .magic)
        XCTAssertEqual(tashani.debuffSlots.count, 1)

        // The key is folded here, so a rank suffix and a case difference are one question.
        XCTAssertNotNil(spells.spell("chaos flux"))
        XCTAssertNotNil(spells.spell("Chaos Flux II"))
        XCTAssertNil(spells.spell("Not A Spell"))
    }

    func testTheReadHappensOnceEvenWhenTheFileDisappearsUnderneathIt() throws {
        let dir = try scratch("once")
        let table = dir + "/spells_us.txt"
        try (row("677", "Tashani", "1", "") + "\n").write(toFile: table, atomically: true, encoding: .utf8)
        let spells = try XCTUnwrap(ClientSpells.besideLog(dir + "/Logs/eqlog_Primitive_freeport.txt"))
        XCTAssertNotNil(spells.spell("Tashani"))
        try FileManager.default.removeItem(atPath: table)
        XCTAssertNotNil(spells.spell("Tashani"), "the parsed table outlives the file it was read from")
    }

    /// An empty table is not a missing one.
    func testAFileThatParsesToNothingIsStillAReadFile() throws {
        let dir = try scratch("empty")
        try "not^a^spell^row\n".write(toFile: dir + "/spells_us.txt", atomically: true, encoding: .utf8)
        let spells = try XCTUnwrap(ClientSpells.besideLog(dir + "/Logs/eqlog_Primitive_freeport.txt"))
        XCTAssertEqual(spells.state, .ok)
        XCTAssertTrue(spells.table()!.isEmpty)
    }

    /// A file that is there and will not read is `unloadable`, which is a different sentence.
    func testAnUnreadableFileIsNotAMissingOne() throws {
        let dir = try scratch("unreadable")
        let path = dir + "/spells_us.txt"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let spells = try XCTUnwrap(ClientSpells.besideLog(dir + "/Logs/eqlog_Primitive_freeport.txt"))
        // Running as root would read it anyway; only assert when the permission actually bites.
        if spells.table() == nil { XCTAssertEqual(spells.state, .unloadable) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
}

/// A tiny atomic counter, so two scratch installs never share a directory.
final class ScratchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}

// MARK: - engined/src/spell_search.rs

final class SpellSearchTests: XCTestCase {
    private let SHD = 4, BRD = 7, WIZ = 11

    /// A small table shaped like a corner of the real one.
    private func corpus() -> (SpellTable, DbStr.CategoryNames) {
        let table = U.parseSpellsUs([
            // Taps / Health, SHD 1 and NEC 1.
            row([(U.F_ID, "341"), (U.F_NAME, "Lifetap"), (U.F_CATEGORY, "114"),
                 (U.F_SUBCATEGORY, "43"), (U.F_CLASS_FIRST + 4, "1"), (U.F_CLASS_FIRST + 10, "1")]),
            // Taps / Power Tap, SHD 34.
            row([(U.F_ID, "343"), (U.F_NAME, "Siphon Strength"), (U.F_CATEGORY, "114"),
                 (U.F_SUBCATEGORY, "76"), (U.F_CLASS_FIRST + 4, "34")]),
            // Taps / Duration Tap, SHD 49.
            row([(U.F_ID, "500"), (U.F_NAME, "Leech"), (U.F_CATEGORY, "114"),
                 (U.F_SUBCATEGORY, "33"), (U.F_CLASS_FIRST + 4, "49")]),
            // Direct Damage, WIZ 29 — matches `tap` on neither name nor category.
            row([(U.F_ID, "600"), (U.F_NAME, "Lightning Bolt"), (U.F_CATEGORY, "25"),
                 (U.F_CLASS_FIRST + 11, "29")]),
            // A cleric tap — in the Taps category, but outside the SHD/BRD/WIZ combo.
            row([(U.F_ID, "700"), (U.F_NAME, "Divine Tap"), (U.F_CATEGORY, "114"),
                 (U.F_SUBCATEGORY, "43"), (U.F_CLASS_FIRST + 1, "20")]),
            // A mob's copy: no class can cast it, so it is in no answer.
            row([(U.F_ID, "6850"), (U.F_NAME, "Unholy Tap"), (U.F_CATEGORY, "114"),
                 (U.F_SUBCATEGORY, "43")])
        ].joined(separator: "\n"))
        let names: DbStr.CategoryNames = [114: "Taps", 43: "Health", 33: "Duration Tap",
                                          76: "Power Tap", 25: "Direct Damage"]
        return (table, names)
    }

    private func namesOf(_ found: SpellSearch.Found) -> [String] { found.rows.map(\.name) }

    private func q(text: String? = nil, category: String? = nil, subcategory: String? = nil,
                   classes: [Int]? = nil, sort: SpellSort = .level,
                   offset: Int = 0, limit: Int = 50) -> SpellSearch.Query {
        SpellSearch.Query(text: text, category: category, subcategory: subcategory,
                          classes: classes, sort: sort, offset: offset, limit: limit)
    }

    /// A `tap` search over SHD/BRD/WIZ returns every tap by level, with the Category and Subcategory
    /// the game prints.
    func testTheOwnersTapSearchOverTheScreenshotsCombo() {
        let (table, names) = corpus()
        let found = SpellSearch.search(table, names, q(text: "tap", classes: [SHD, BRD, WIZ]))
        // Level descending, the game's own order. `Divine Tap` is a cleric's and out of scope;
        // `Unholy Tap` is a mob's copy and in no answer at all.
        XCTAssertEqual(namesOf(found), ["Leech", "Siphon Strength", "Lifetap"])
        for foundByType in ["Leech", "Siphon Strength"] {
            XCTAssertFalse(foundByType.lowercased().contains("tap"), "\(foundByType) is a type match")
        }
        XCTAssertEqual(found.total, 3)
        let leech = found.rows[0]
        XCTAssertEqual(leech.level, 49)
        XCTAssertEqual(leech.category, "Taps")
        XCTAssertEqual(leech.subcategory, "Duration Tap")
        XCTAssertEqual(leech.classes, [SpellSearch.ClassLevel(class: "SHD", level: 49)])
        XCTAssertEqual(found.categories.count, 1)
        XCTAssertEqual(found.categories[0].name, "Taps")
        XCTAssertEqual(found.categories[0].subcategories, ["Duration Tap", "Health", "Power Tap"])
    }

    func testACategoryFilterNeedsNoTextAtAll() {
        let (table, names) = corpus()
        let found = SpellSearch.search(table, names, q(category: "Taps", classes: [SHD, BRD, WIZ]))
        XCTAssertEqual(namesOf(found), ["Leech", "Siphon Strength", "Lifetap"])
        let health = SpellSearch.search(table, names,
                                        q(category: "Taps", subcategory: "Health", classes: [SHD, BRD, WIZ]))
        XCTAssertEqual(namesOf(health), ["Lifetap"])
        // The filter value is case-insensitive, so a stored preference still matches.
        let lowered = SpellSearch.search(table, names, q(category: "taps", classes: [SHD, BRD, WIZ]))
        XCTAssertEqual(lowered.total, 3)
    }

    func testNoClassScopeIsEveryClassButStillNeverAnNPCCopy() {
        let (table, names) = corpus()
        let found = SpellSearch.search(table, names, q(category: "Taps"))
        XCTAssertEqual(namesOf(found), ["Leech", "Siphon Strength", "Divine Tap", "Lifetap"])
        XCTAssertFalse(namesOf(found).contains("Unholy Tap"))
    }

    func testTheFacetsIgnoreTheCategoryFilterTheyDescribe() {
        let (table, names) = corpus()
        let picked = SpellSearch.search(table, names, q(category: "Taps"))
        XCTAssertEqual(picked.categories.map(\.name), ["Direct Damage", "Taps"],
                       "picking Taps must not hide Direct Damage from the control")
        // …but they do describe the class scope, which is a filter the control does not own.
        let wizard = SpellSearch.search(table, names, q(classes: [WIZ]))
        XCTAssertEqual(wizard.categories.map(\.name), ["Direct Damage"],
                       "a wizard-only scope has no taps in it")
    }

    /// The order is total. The corpus is a dictionary with unspecified iteration order.
    func testTheOrderIsStableAcrossCallsAndTiesBreakByKey() {
        var (table, names) = corpus()
        let extra = U.parseSpellsUs(row([(U.F_ID, "800"), (U.F_NAME, "Aardvark Tap"),
                                         (U.F_CATEGORY, "114"), (U.F_SUBCATEGORY, "43"),
                                         (U.F_CLASS_FIRST + 4, "49")]))
        for (k, v) in extra { table[k] = v }
        let first = SpellSearch.search(table, names, q(text: "tap", classes: [SHD]))
        // `Aardvark Tap` and `Leech` are both level 49; `aardvark tap` sorts before `leech`.
        XCTAssertEqual(namesOf(first), ["Aardvark Tap", "Leech", "Siphon Strength", "Lifetap"])
        for _ in 0..<8 {
            let again = SpellSearch.search(table, names, q(text: "tap", classes: [SHD]))
            XCTAssertEqual(namesOf(again), namesOf(first), "the order is total")
        }
    }

    func testSortingByNameIsAlphabeticalAndAlsoTotal() {
        let (table, names) = corpus()
        let found = SpellSearch.search(table, names, q(category: "Taps", sort: .name))
        XCTAssertEqual(namesOf(found), ["Divine Tap", "Leech", "Lifetap", "Siphon Strength"])
    }

    /// `total` counts what matched, not what was returned.
    func testTheWindowReportsTheWholeMatchCountBehindIt() {
        let (table, names) = corpus()
        let page = SpellSearch.search(table, names, q(category: "Taps", offset: 1, limit: 2))
        XCTAssertEqual(namesOf(page), ["Siphon Strength", "Divine Tap"])
        XCTAssertEqual(page.total, 4, "a surface says 2-3 of 4 off this")
        // Past the end is an empty page, never an error.
        let past = SpellSearch.search(table, names, q(category: "Taps", offset: 99, limit: 20))
        XCTAssertTrue(past.rows.isEmpty)
        XCTAssertEqual(past.total, 4, "…and it still says how many there were")
    }

    func testAMultiClassRowFilesUnderTheEarliestLevelItCouldBeHad() {
        let table = U.parseSpellsUs(row([(U.F_ID, "1"), (U.F_NAME, "Shared Spell"),
                                         (U.F_CLASS_FIRST + 4, "40"), (U.F_CLASS_FIRST + 11, "22")]))
        let found = SpellSearch.search(table, [:], q(classes: [SHD, WIZ]))
        XCTAssertEqual(found.rows[0].level, 22, "the earliest you could have it")
        XCTAssertEqual(found.rows[0].classes,
                       [SpellSearch.ClassLevel(class: "SHD", level: 40),
                        SpellSearch.ClassLevel(class: "WIZ", level: 22)],
                       "…and the whole truth rides beside it, in the file's column order")
        let shdOnly = SpellSearch.search(table, [:], q(classes: [SHD]))
        XCTAssertEqual(shdOnly.rows[0].level, 40)
        XCTAssertEqual(shdOnly.rows[0].classes.count, 1)
    }

    /// An unreadable string table is a degraded list, not an outage.
    func testWithNoStringTableTheRowsSurviveWithoutTheirWords() {
        let (table, _) = corpus()
        let found = SpellSearch.search(table, [:], q(text: "tap"))
        XCTAssertFalse(found.rows.isEmpty, "the spells are still found by name")
        XCTAssertTrue(found.rows.allSatisfy { $0.category == nil })
        XCTAssertTrue(found.categories.isEmpty)
        // …and a category filter therefore matches nothing, rather than everything.
        XCTAssertTrue(SpellSearch.search(table, [:], q(category: "Taps")).rows.isEmpty)
    }

    func testAnEmptyTextFilterFiltersNothing() {
        let (table, names) = corpus()
        XCTAssertEqual(SpellSearch.search(table, names, q(text: "")).total, 5,
                       "every playable row in the corpus")
    }

    /// The op's own arithmetic: a limit is clamped rather than refused, and a negative offset is no
    /// offset. The reply echoes the EFFECTIVE limit, which is what lets a caller notice the clamp.
    func testTheWindowIsClampedRatherThanRefused() {
        XCTAssertEqual(SpellSearch.clampSpellRows(nil), 50, "the default")
        XCTAssertEqual(SpellSearch.clampSpellRows(3), 3)
        XCTAssertEqual(SpellSearch.clampSpellRows(10_000), 200, "the cap")
        XCTAssertEqual(SpellSearch.clampSpellRows(-5), 0)
        XCTAssertEqual(SpellSearch.clampOffset(nil), 0)
        XCTAssertEqual(SpellSearch.clampOffset(-1), 0)
        XCTAssertEqual(SpellSearch.clampOffset(2), 2)
    }
}

// MARK: - The recorded goldens

/// Every fixture's `spells.search` and `resist.spell` were recorded with the fixture staged in a temp
/// directory with NO `spells_us.txt` beside it, so the golden answers are the `missing` shapes. They
/// pin the whole reply shape — the empty lists, the echoed window, the state word and the derived
/// path — for the situation a player with no EverQuest install behind the folder produces.
final class SpellsGoldenTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")

    /// The three queries `scripts/gen-engine-goldens.py` records, in its order.
    private func answers(_ spells: ClientSpells) -> [SpellsSearchResult] {
        [SpellSearch.answer(spells, text: "haste", limit: 3),
         SpellSearch.answer(spells, classes: ["NEC"], sort: .name, offset: 2, limit: 5),
         SpellSearch.answer(spells, category: "Pet", limit: 2)]
    }

    func testTheMissingTableShapesMatchEveryFixturesGolden() throws {
        let fm = FileManager.default
        let dirs = try fm.contentsOfDirectory(atPath: Self.goldens.path).sorted()
        var checked = 0, mismatches: [String] = []
        for name in dirs {
            let ops = Self.goldens.appendingPathComponent(name).appendingPathComponent("ops.json")
            guard let data = fm.contents(atPath: ops.path),
                  let gold = try? JSONValue.parse(data),
                  let searches = gold["spells.search"].array, searches.count == 3 else { continue }
            // The golden's own path names the staging directory this fixture was recorded in; the
            // engine derives the same one from the log two levels below it.
            guard let path = searches[0]["result"]["path"].string else { continue }
            let root = (path as NSString).deletingLastPathComponent
            let spells = try XCTUnwrap(ClientSpells.besideLog(root + "/Logs/eqlog_Primitive_freeport.txt"))
            XCTAssertEqual(spells.path, path, "\(name): the derived path is the recorded one")

            for (i, ours) in answers(spells).enumerated() {
                let rep = SnapshotDiff.compare(golden: searches[i]["result"], ours: ours.json)
                if !rep.isEqual { mismatches.append("\(name) spells.search[\(i)]: \(rep.mismatches)") }
            }
            for spellName in ["Venom of the Snake", "Tashani", "Nothing"] {
                let golden = gold["resist.spell"][spellName]["result"]
                let rep = SnapshotDiff.compare(golden: golden, ours: spells.resistSpell(name: spellName).json)
                if !rep.isEqual { mismatches.append("\(name) resist.spell[\(spellName)]: \(rep.mismatches)") }
            }
            checked += 1
        }
        XCTAssertTrue(mismatches.isEmpty, "\(mismatches.count) divergences: \(mismatches.prefix(5))")
        XCTAssertGreaterThan(checked, 0, "no fixture carried a spells.search golden")
    }
}

// MARK: - The owner's own install

/// Skipped wherever the owner's client files are not present, and it asserts only what the Rust
/// suites already pin in the open — nothing derived from Daybreak's file is written down here.
final class RealClientTableTests: XCTestCase {
    static let install = NSHomeDirectory()
        + "/Library/Application Support/CrossOver/Bottles/EverQuest/drive_c/users/Public"
        + "/Daybreak Game Company/Installed Games/EverQuest Legends"

    func testTheOwnersTableParsesAndTashaniIsStillAMagicDebuff() throws {
        let log = Self.install + "/Logs/eqlog_Zoddrick_oggok.txt"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.install + "/spells_us.txt"),
                          "the owner's client files are not on this machine")
        let spells = try XCTUnwrap(ClientSpells.besideLog(log))
        XCTAssertEqual(spells.state, .ok)
        let tashani = try XCTUnwrap(spells.spell("Tashani"))
        // The debuff slot the Rust suite names — `2|50|-10|0|101|23`, effect 50 with a cap of 23.
        // The row's own RESIST TYPE is not one of the five, so the SPELL carries no axis: the axis
        // here belongs to the slot, which is exactly the distinction the two enums exist for, and
        // the Rust engine answers this row the same way.
        XCTAssertNil(tashani.axis)
        XCTAssertEqual(tashani.debuffSlots.first?.axis, .magic)
        XCTAssertEqual(tashani.debuffSlots.first?.max, 23.0)
        // The string table beside it names the category ids, and the search finds a spell by type.
        XCTAssertFalse(spells.categoryNames().isEmpty)
        XCTAssertGreaterThan(SpellSearch.answer(spells, text: "haste", limit: 3).total, 0)
    }
}
