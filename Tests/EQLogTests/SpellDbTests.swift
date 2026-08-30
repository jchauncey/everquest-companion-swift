import XCTest
@testable import EQLog

/// The spell catalog: the four load passes, the message overlay, the suffix matcher, and the
/// projection the fold reads. The acceptance is the goldens' own `candidates` arrays, which are
/// literally this database's answers.
final class SpellDbTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")

    // MARK: - passes.rs

    func testParseDurationMs() {
        XCTAssertNil(SpellDbPasses.parseDurationMs(nil))
        XCTAssertNil(SpellDbPasses.parseDurationMs(""))
        XCTAssertNil(SpellDbPasses.parseDurationMs("Instant"))
        XCTAssertNil(SpellDbPasses.parseDurationMs("Permanent"))
        XCTAssertNil(SpellDbPasses.parseDurationMs("Until cancelled"))
        XCTAssertNil(SpellDbPasses.parseDurationMs("Varies"))
        XCTAssertNil(SpellDbPasses.parseDurationMs("N/A"))
        XCTAssertEqual(SpellDbPasses.parseDurationMs("36 Sec"), 36000)
        XCTAssertEqual(SpellDbPasses.parseDurationMs("1 hour 12 minutes"), 4_320_000)
        XCTAssertEqual(SpellDbPasses.parseDurationMs("3 ticks"), 18000)
        XCTAssertEqual(SpellDbPasses.parseDurationMs("1.5 min"), 90000)
        // A clock form is read only when no unit component matched.
        XCTAssertEqual(SpellDbPasses.parseDurationMs("1:30"), 90000)
        XCTAssertEqual(SpellDbPasses.parseDurationMs("1:02:03"), 3_723_000)
        XCTAssertNil(SpellDbPasses.parseDurationMs("0:00"))
        // A formula takes the max rather than the sum.
        XCTAssertEqual(SpellDbPasses.parseDurationMs("30 sec to 5 min"), 300_000)
    }

    func testIsPlaceholder() {
        XCTAssertTrue(SpellDbPasses.isPlaceholder("N/A"))
        XCTAssertTrue(SpellDbPasses.isPlaceholder(" n/a "))
        XCTAssertTrue(SpellDbPasses.isPlaceholder("Someone"))
        XCTAssertTrue(SpellDbPasses.isPlaceholder("You."))
        XCTAssertTrue(SpellDbPasses.isPlaceholder("  ---  "))
        XCTAssertTrue(SpellDbPasses.isPlaceholder(""))
        XCTAssertFalse(SpellDbPasses.isPlaceholder("You feel much faster."))
        XCTAssertFalse(SpellDbPasses.isPlaceholder("Someone looks tougher."))
    }

    func testRemovalsAndCorrectionsAreApplied() {
        let db = SpellDb.shared()
        // The two removals: the game does not have these rows at all.
        XCTAssertEqual(db.spells.count, 2004, "spells.json ships 2006 rows; the sidecar removes two")
        XCTAssertNil(db.byKeyGet(Names.dbCanonKey("Invigor")))
        XCTAssertTrue(db.spells.allSatisfy { $0.name != "Invigor" })
        // Removals run BEFORE corrections, so the rename of `Invisibility vs. Undead` puts the
        // removed name back — the ordering of the chain is observable here.
        XCTAssertTrue(db.spells.allSatisfy { $0.name != "Invisibility vs. Undead" })
        XCTAssertEqual(db.byKeyGet(Names.dbCanonKey("Invisibility Versus Undead"))?.durationText, "27 Min")
        // The other two `name` corrections.
        XCTAssertNotNil(db.byKeyGet(Names.dbCanonKey("Solon's Bewitching Bravura")))
        XCTAssertNotNil(db.byKeyGet(Names.dbCanonKey("Malaisement")))
        // A `msgCastOnOther` correction: "engulfed in" → "engulfed by".
        XCTAssertEqual(db.byKeyGet(Names.dbCanonKey("Engulfing Darkness"))?.msgCastOnOther,
                       "Someone is engulfed by darkness.")
    }

    // MARK: - mod.rs

    func testKnownEntries() {
        let db = SpellDb.shared()
        let venom = db.byKeyGet(Names.dbCanonKey("Venom of the Snake"))
        XCTAssertEqual(venom?.name, "Venom of the Snake")
        XCTAssertEqual(venom?.durationMs, 36000)
        XCTAssertEqual(venom?.msgCastOnYou, "You have been poisoned.")
        XCTAssertEqual(venom?.msgWearsOff, "The poison has run its course.")
        let harness = db.byKeyGet(Names.dbCanonKey("Harnessing of Spirit"))
        XCTAssertEqual(harness?.durationMs, 4_320_000)
        XCTAssertEqual(harness?.durationText, "1 hour 12 minutes")
        XCTAssertEqual(harness?.msgCastOnYou, "You feel tough.")
    }

    func testCatalogSizes() {
        let db = SpellDb.shared()
        print("spells=\(db.spells.count) keys=\(db.keys().count) castOnYou=\(db.castOnYouMap.count) " +
              "wearsOff=\(db.wearsOffMap.count) suffixBuckets=\(db.castOnOtherByLastWord.count) " +
              "unkeyed=\(db.castOnOtherUnkeyed.count) charmKeys=\(db.charmKeys.count)")
        // spells.json ships 2006 rows; the sidecar removes two.
        XCTAssertEqual(db.spells.count, 2004)
        XCTAssertEqual(db.keys().count, db.byKeyOrder.count)
        XCTAssertEqual(db.byKeyEntries().count, db.keys().count)
        // The unkeyable suffix list is measured empty — the bucket index is total.
        XCTAssertTrue(db.castOnOtherUnkeyed.isEmpty)
        XCTAssertFalse(db.keys().isEmpty)
    }

    func testCastOnOtherSuffix() {
        XCTAssertEqual(castOnOtherSuffix("Someone looks less aggressive."), "looks less aggressive.")
        XCTAssertEqual(castOnOtherSuffix("Someone's eyes glow."), "'s eyes glow.")
        XCTAssertEqual(castOnOtherSuffix("Someone 's skin turns to stone."), "'s skin turns to stone.")
        XCTAssertNil(castOnOtherSuffix("You feel much faster."))
    }

    func testSuffixMatchNeedsSomethingInFrontOfTheTail() {
        let db = SpellDb.shared()
        let hit = db.matchCastOnOther("A goblin has been poisoned.")
        XCTAssertEqual(hit?.1, "A goblin")
        XCTAssertTrue((hit?.0.cands ?? []).contains { db.entry($0)?.name == "Venom of the Snake" })
        // A line that is only the suffix is refused.
        XCTAssertNil(db.matchCastOnOther("has been poisoned."))
        // The 60-UTF-16-unit cap on the target.
        XCTAssertNil(db.matchCastOnOther(String(repeating: "a", count: 61) + " has been poisoned."))
        XCTAssertNotNil(db.matchCastOnOther(String(repeating: "a", count: 60) + " has been poisoned."))
    }

    func testCharmRoster() {
        let db = SpellDb.shared()
        XCTAssertTrue(db.isCharmSpell("Beguile"))
        XCTAssertTrue(db.isCharmSpell("Dominate Undead"))
        // The stem roster answers for a name the catalog does not carry.
        XCTAssertTrue(db.isCharmSpell("Alluring Whispers"))
        XCTAssertFalse(db.isCharmSpell("Venom of the Snake"))
    }

    // MARK: - overlay.rs

    func testOverlayLandingCorrectionsWin() {
        let db = SpellDb.shared()
        let corrections = SpellDbOverlay.deriveLandingCorrections(db)
        print("landingCorrections=\(corrections.count)")
        XCTAssertFalse(corrections.isEmpty)
        // Each text appears at most once.
        XCTAssertEqual(Set(corrections.map(\.0)).count, corrections.count)
        // A correction never points at a Detrimental spell in the effective DB.
        for (text, name, _) in corrections {
            guard let idx = db.byKey[Names.dbCanonKey(name)] else { continue }
            if db.spells[idx].spellType == "Detrimental" { continue }
            XCTAssertNotNil(db.castOnYou(text), "the overlay registers \(text)")
        }
    }

    // MARK: - spell_facts.rs

    func testSpellFactsProjection() {
        let db = SpellDb.shared()
        let facts = SpellFacts.project(db)
        XCTAssertEqual(facts.count, db.keys().count)
        XCTAssertFalse(facts.isEmpty)
        let venom = facts.get(Names.dbCanonKey("Venom of the Snake"))
        XCTAssertEqual(venom?.name, "Venom of the Snake")
        XCTAssertEqual(venom?.durationMs, 36000)
        XCTAssertEqual(venom?.nature, .detrimental)
        XCTAssertEqual(venom?.msgCastOnOtherSuffix, "has been poisoned.")
        XCTAssertFalse(venom?.calmsTarget ?? true)
        let harness = facts.get(Names.dbCanonKey("Harnessing of Spirit"))
        XCTAssertEqual(harness?.nature, .beneficial)
        XCTAssertTrue(SpellFacts().isEmpty)
    }

    /// The two shapes the mining rule exists to tell apart.
    func testALandingMessageIsAboutYouAndCarriesNoNumbers() {
        XCTAssertTrue(looksLandingMessage("The symbol of Pinzarn flashes before your eyes."))
        XCTAssertTrue(looksLandingMessage("You feel much faster."))
        // A mob-subject line names nobody — combat spam, refused.
        XCTAssertFalse(looksLandingMessage("A revenant staggers."))
        // Numbers are damage/heal lines.
        XCTAssertFalse(looksLandingMessage("You have taken 12 points of damage."))
        // No terminal period, and too short.
        XCTAssertFalse(looksLandingMessage("You feel much faster"))
        XCTAssertFalse(looksLandingMessage("You."))
        // The casting-system family.
        XCTAssertFalse(looksLandingMessage("Your spell is interrupted."))
        XCTAssertFalse(looksLandingMessage("You have entered the wastes."))
        // A `by`/`from` marker is a combat sentence however it is dressed.
        XCTAssertFalse(looksLandingMessage("You are healed by your pet."))
    }

    /// The suffix tail test refuses a line that is only the suffix.
    func testTheOtherSuffixTestNeedsSomethingInFrontOfTheTail() {
        XCTAssertTrue(messageMatchesOtherSuffix("A goblin looks less aggressive.", "looks less aggressive."))
        XCTAssertFalse(messageMatchesOtherSuffix("looks less aggressive.", "looks less aggressive."))
        XCTAssertTrue(messageMatchesOtherSuffix("A goblin's eyes glow.", "'s eyes glow."))
    }

    // MARK: - The goldens' own candidate lists

    /// `classify_db_buff`, replayed off the goldens: a `buffApply`/`buffWearOff` line's `candidates`
    /// array is this database's answer, so the goldens pin the whole load chain.
    func testGoldenCandidateListsMatch() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.goldens.path) else { throw XCTSkip("no Goldens/") }
        let db = SpellDb.shared()
        let line = Re("^\\[(\(JS.DOT)+?)\\]\(JS.S)?(\(JS.DOT)*)$")
        var checked = 0, bad = 0
        var firstFailures: [String] = []
        let names = try fm.contentsOfDirectory(atPath: Self.goldens.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        for n in names {
            let path = Self.goldens.appendingPathComponent(n).appendingPathComponent("events.ndjson")
            guard let gold = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for raw in gold.split(separator: "\n") {
                guard raw.contains("\"kind\":\"buffApply\"") || raw.contains("\"kind\":\"buffWearOff\"") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let logLine = obj["raw"] as? String, let kind = obj["kind"] as? String,
                      let caps = line.captures(logLine) else { continue }
                let text = caps.s(2)
                checked += 1
                var ok = false
                if kind == "buffApply" {
                    let expected = (obj["candidates"] as? [[String: Any]]) ?? []
                    var got: [(String, Int64?, Bool)] = []
                    var target = ""
                    if let cands = db.castOnYou(text), !cands.isEmpty {
                        target = "self"
                        got = cands.map { (db.entry($0)!.name, db.entry($0)!.durationMs, db.entry($0)!.illusion) }
                    } else if let worn = db.wearsOff(text), !worn.isEmpty {
                        target = "<buffWearOff>"
                    } else if let (entry, t) = db.matchCastOnOther(text) {
                        target = Names.norm(t)
                        got = entry.cands.map { (db.entry($0)!.name, db.entry($0)!.durationMs, db.entry($0)!.illusion) }
                    }
                    ok = target == (obj["target"] as? String ?? "")
                        && got.first?.0 == (obj["spell"] as? String)
                        && got.first?.2 == (obj["illusion"] as? Bool)
                        && sameCands(got, expected)
                } else {
                    let expected = (obj["candidates"] as? [String]) ?? []
                    var got: [String] = []
                    if let cands = db.castOnYou(text), !cands.isEmpty {
                        got = ["<buffApply>"]
                    } else if let worn = db.wearsOff(text), !worn.isEmpty {
                        got = worn.map { db.entry($0)!.name }
                    }
                    ok = got == expected && got.first == (obj["spell"] as? String)
                }
                if !ok {
                    bad += 1
                    if firstFailures.count < 5 { firstFailures.append("\(n): \(raw.prefix(260))") }
                }
            }
        }
        print("golden candidate lines checked=\(checked) mismatched=\(bad)")
        XCTAssertGreaterThan(checked, 20000, "the goldens carry the buff kinds")
        XCTAssertEqual(bad, 0, "first divergences:\n" + firstFailures.joined(separator: "\n"))
    }

    private func sameCands(_ got: [(String, Int64?, Bool)], _ expected: [[String: Any]]) -> Bool {
        if got.count != expected.count { return false }
        for (g, e) in zip(got, expected) {
            if g.0 != (e["name"] as? String) { return false }
            let d = e["durationMs"] as? Int64 ?? (e["durationMs"] as? NSNumber).map { $0.int64Value }
            if g.1 != d { return false }
            if g.2 != (e["illusion"] as? Bool) { return false }
        }
        return true
    }
}
