// The knowledge oracle, plus the unit tests ported from the two Rust crates this file covers
// (`knowledge/src/{lib,items,mobs,names}.rs` and `engined/src/search.rs`).
//
// The oracle is `Goldens/<fixture>/ops.json`: the answers the RUST engine gave to
// `knowledge.item|mob|spell|search` over its socket, recorded per fixture. Every one of them is
// replayed here against this port and deep-compared with `SnapshotDiff`.
//
// `knowledge.mob` is the one op whose answer is not committed data alone: its `dropsSeen` half is
// YOUR OWN LOOT, read off the fold's index. So a mob case folds that fixture's own
// `events.ndjson` through `EQFold` first and hands the corpus `registry.ownLoot()` — the same seam
// `World::knowledge_mob` reads through.
import XCTest
import EQLog
import EQFold
import EQKnowledge
import EQEngine
import EQCompanionCore

/// `has` is EQKnowledge-internal; the tests need the same "the key is present at all" read.
private extension JSONValue {
    func has(_ key: String) -> Bool {
        if case .object(let o) = self { return o[key] != nil }
        return false
    }
}

final class KnowledgeTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let goldens = repo.appendingPathComponent("Goldens")

    /// One corpus for the whole suite: the overlay stays empty and the miss ledger is nobody's
    /// business here, so the answers are the same corpus's either way — and items.json is parsed
    /// once instead of 48 times.
    static let corpus = KnowledgeCorpus()

    /// The search calls the recording script made, which `ops.json` does not carry (it records the
    /// answers, not the params). Kept in the same order as `scripts/gen-engine-goldens.py SEARCHES`.
    static let searches: [(query: String, domain: String?, limit: Int?)] = [
        ("mithril", nil, 5), ("ghoul", "mob", 5), ("  ", nil, nil), ("spirit", "spell", 3)
    ]

    static func fixtures() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: goldens.path)
            .filter { !$0.hasPrefix("_") && !$0.hasPrefix(".") }
            .filter { FileManager.default.fileExists(atPath: goldens.appendingPathComponent("\($0)/ops.json").path) }
            .sorted()
    }

    static func ops(_ fixture: String) throws -> JSONValue {
        try JSONValue.parse(Data(contentsOf: goldens.appendingPathComponent("\(fixture)/ops.json")))
    }

    /// The fold that owns one fixture's own-loot index — `Tests/EQFoldTests/GoldenSnapshotsTests`'s
    /// construction, which is what the recording engine was running.
    static func fold(_ name: String) throws -> Fold {
        let gdir = goldens.appendingPathComponent(name)
        let events = try String(contentsOf: gdir.appendingPathComponent("events.ndjson"), encoding: .utf8)
        let gold = try JSONValue.parse(Data(contentsOf: gdir.appendingPathComponent("snapshots.json")))
        let clock = Clock(identifier: gold["meta"]["tz"].string ?? "America/Los_Angeles")!
        let db = SpellDb.shared()
        var deps = ClusterDeps()
        deps.knownSpell = Set(db.keys())
        deps.spellClasses = spellClassIndex(db)
        deps.launchMs = Epoch.launchMs(clock)
        deps.constructionNowMs = gold["meta"]["constructionNowMs"].int64 ?? 0
        let character = gold["meta"]["character"].string ?? "Primitive"
        deps.character = ["name": .string(character), "server": "freeport"]
        deps.facts = SpellFacts.project(db)
        let f = Fold(registry: registered(deps), launchMs: deps.launchMs)
        f.foldNDJSON(events)
        return f
    }

    /// The op result the engine replies with, built around one corpus answer — the schema's
    /// `KnowledgeResult`. The wrapper belongs to the ops table; it is spelled here so the oracle
    /// compares the whole recorded answer rather than half of it.
    static func result(_ domain: String, _ asked: String, _ answer: KnowledgeAnswer) -> JSONValue {
        ["domain": .string(domain), "name": .string(asked),
         "found": .bool(answer.found), "record": answer.record]
    }

    // MARK: - The oracle

    func testEveryRecordedItemAnswerMatches() throws {
        try runOracle(op: "knowledge.item") { name in
            Self.result("item", name, Self.corpus.item(name))
        }
    }

    func testEveryRecordedSpellAnswerMatches() throws {
        try runOracle(op: "knowledge.spell") { name in
            Self.result("spell", name, Self.corpus.spell(name))
        }
    }

    /// The mob half, which is the only one that touches a fold. Reported in two tallies: the whole
    /// record, and the record minus `dropsSeen` — so a missing own-loot seam shows up as itself
    /// rather than as a knowledge failure.
    func testEveryRecordedMobAnswerMatchesIncludingYourOwnLoot() throws {
        let names = try Self.fixtures()
        guard !names.isEmpty else { throw XCTSkip("no Goldens/*/ops.json") }
        var whole = (0, 0), withoutSeen = (0, 0), seenSeen = 0
        var firstDiff: [String] = []
        for fixture in names {
            let ops = try Self.ops(fixture)
            guard let cases = ops["knowledge.mob"].object else { continue }
            let loot = try Self.fold(fixture).registry.ownLoot() ?? NoOwnLoot()
            for (asked, recorded) in cases.sorted(by: { $0.key < $1.key }) {
                let golden = recorded["result"]
                let ours = Self.result("mob", asked, Self.corpus.mob(asked, loot: loot))
                if golden["record"].has("dropsSeen") { seenSeen += 1 }
                whole.0 += 1
                let rep = SnapshotDiff.compare(golden: golden, ours: ours, limit: 3)
                if rep.isEqual { whole.1 += 1 } else if firstDiff.count < 5 {
                    firstDiff.append("\(fixture) / \(asked): \(rep.mismatches.joined(separator: "; "))")
                }
                withoutSeen.0 += 1
                let g = withRecord(golden, strip(golden["record"], "dropsSeen"))
                let o = withRecord(ours, strip(ours["record"], "dropsSeen"))
                if SnapshotDiff.compare(golden: g, ours: o, limit: 1).isEqual { withoutSeen.1 += 1 }
            }
        }
        XCTAssertGreaterThan(seenSeen, 0, "no recorded mob answer carries dropsSeen — the own-loot join is untested")
        XCTAssertEqual(whole.0, whole.1,
                       "knowledge.mob whole \(whole.1)/\(whole.0), minus dropsSeen \(withoutSeen.1)/\(withoutSeen.0)\n"
                       + firstDiff.joined(separator: "\n"))
    }

    func testEveryRecordedSearchAnswerMatches() throws {
        let names = try Self.fixtures()
        guard !names.isEmpty else { throw XCTSkip("no Goldens/*/ops.json") }
        var total = 0, ok = 0
        var firstDiff: [String] = []
        for fixture in names {
            let recorded = try Self.ops(fixture)["knowledge.search"].array ?? []
            XCTAssertEqual(recorded.count, Self.searches.count, "\(fixture): the recorded search count moved")
            for (i, one) in recorded.enumerated() where i < Self.searches.count {
                let q = Self.searches[i]
                let ours = Self.corpus.search(q.query, domain: q.domain, limit: q.limit)
                total += 1
                let rep = SnapshotDiff.compare(golden: one["result"], ours: ours, limit: 3)
                if rep.isEqual { ok += 1 } else if firstDiff.count < 5 {
                    firstDiff.append("\(fixture) / \(q.query): \(rep.mismatches.joined(separator: "; "))")
                }
            }
        }
        XCTAssertEqual(total, ok, "knowledge.search \(ok)/\(total)\n" + firstDiff.joined(separator: "\n"))
    }

    /// Item and spell answers are committed data alone, so every fixture recorded the same ones;
    /// the loop is what proves that rather than assuming it.
    private func runOracle(op: String, _ answer: (String) -> JSONValue) throws {
        let names = try Self.fixtures()
        guard !names.isEmpty else { throw XCTSkip("no Goldens/*/ops.json") }
        var total = 0, ok = 0
        var firstDiff: [String] = []
        for fixture in names {
            guard let cases = try Self.ops(fixture)[op].object else { continue }
            for (asked, recorded) in cases.sorted(by: { $0.key < $1.key }) {
                total += 1
                let rep = SnapshotDiff.compare(golden: recorded["result"], ours: answer(asked), limit: 3)
                if rep.isEqual { ok += 1 } else if firstDiff.count < 5 {
                    firstDiff.append("\(fixture) / \(asked): \(rep.mismatches.joined(separator: "; "))")
                }
            }
        }
        XCTAssertGreaterThan(total, 0, "\(op): nothing recorded")
        XCTAssertEqual(total, ok, "\(op) \(ok)/\(total)\n" + firstDiff.joined(separator: "\n"))
    }

    private func strip(_ record: JSONValue, _ key: String) -> JSONValue {
        guard case .object(var o) = record else { return record }
        o.removeValue(forKey: key)
        return .object(o)
    }

    private func withRecord(_ result: JSONValue, _ record: JSONValue) -> JSONValue {
        guard case .object(var o) = result else { return result }
        o["record"] = record
        return .object(o)
    }

    // MARK: - names.rs

    func testTheItemLevelSuffixIsStrippedAndNothingElseIs() {
        XCTAssertEqual(ItemNames.itemBaseName("Cloak of Flames +4"), "Cloak of Flames")
        XCTAssertEqual(ItemNames.itemBaseName("  Cloak of Flames  "), "Cloak of Flames")
        // Not a suffix: no space-plus, no digits, or digits that are part of the name.
        XCTAssertEqual(ItemNames.itemBaseName("Cloak of Flames+4"), "Cloak of Flames+4")
        XCTAssertEqual(ItemNames.itemBaseName("Bag of Sewn Evil-Eye"), "Bag of Sewn Evil-Eye")
        XCTAssertEqual(ItemNames.itemBaseName("Journeyman's Boots 2"), "Journeyman's Boots 2")
        XCTAssertEqual(ItemNames.itemBaseName("+4"), "+4")
    }

    func testTheKeyFoldsCaseAndTheSuffixTogether() {
        XCTAssertEqual(ItemNames.itemKey("Cloak of Flames +4"), "cloak of flames")
        XCTAssertEqual(ItemNames.itemKey("CLOAK OF FLAMES"), "cloak of flames")
        XCTAssertEqual(ItemNames.questItemKey("Guard Bracelet"), "guard bracelet")
    }

    // MARK: - items.rs

    func testTheCompactFormIsExpandedAndTheCallerKeepsItsOwnSpelling() {
        let entry: JSONValue = ["page": "Cloak of Flames", "lore": true]
        let out = Items.knowledgeFromDb(entry, "Cloak of Flames +4")
        XCTAssertEqual(out["name"], "Cloak of Flames +4", "a DB hit never renames the player's item")
        XCTAssertEqual(out["lore"], true)
        XCTAssertEqual(out["quest"], false, "the omitted default is restored")
        XCTAssertEqual(out["questUses"], .array([]))
        XCTAssertEqual(out["page"], "Cloak of Flames")
    }

    func testTheClassPrefixIsStrippedBeforeTwoSourcesAreCompared() {
        XCTAssertEqual(Items.questIdentity("Paladin · Paladin Test of Love"), "paladin test of love")
        XCTAssertEqual(Items.questIdentity("Paladin Test of Love"), "paladin test of love")
    }

    func testALocalAssociationMakesAnItemAQuestItemAndNeverListsAQuestTwice() {
        let base: JSONValue = [
            "name": "Guard Bracelet", "lore": false, "quest": false,
            "questUses": .array([["quest": "Corrupt Guards", "source": "wiki"]])
        ]
        let out = Items.mergeLocal(base, [["quest": "Guards · Corrupt Guards", "source": "quests"]])
        XCTAssertEqual(out["quest"], true)
        XCTAssertEqual(out["questUses"].array?.count, 1, "local wins on identity")
        XCTAssertEqual(out["questUses"][0]["source"], "quests")
    }

    func testAnUnansweredNameStillCarriesWhatTheLocalSourcesKnew() {
        let out = Items.unanswered("Wind Rune Meda", [["quest": "Bard · Bard Test of Tone", "source": "posky"]])
        XCTAssertEqual(out["offline"], true, "the engine has no network — it did not look")
        XCTAssertFalse(out.has("notFound"), "and it therefore claims no negative")
        XCTAssertEqual(out["quest"], true)
        XCTAssertEqual(out["questUses"].array?.count, 1)
    }

    // MARK: - mobs.rs

    func testACatalogEntryStatesOnlyWhatThePageStates() {
        let entry: JSONValue = ["page": "A zol ghoul knight", "name": "a zol ghoul knight",
                                "level": "36-40", "zones": .array(["Lower Guk"]), "drops": .array(["Amber"])]
        var out = Mobs.knowledgeFromCatalog("A zol ghoul knight", entry)
        XCTAssertEqual(out["levelText"], "36-40")
        XCTAssertEqual(out["zone"], "Lower Guk")
        XCTAssertEqual(out["dropsWiki"][0], ["item": "Amber"])
        XCTAssertFalse(out["dropsWiki"][0].has("rarity"), "the catalog states no rarity")

        // A merchant page states no loot at all and comes back with no drop list rather than an
        // empty one — reading a vendor's stock as loot would be a claim the page does not make.
        out = Mobs.knowledgeFromCatalog("Key Master", ["page": "Key Master", "name": "Key Master"])
        XCTAssertFalse(out.has("dropsWiki"))
        XCTAssertFalse(out.has("levelText"))
    }

    func testYourOwnLootIsAttachedAsItsOwnListAndNeverAsDrops() {
        let base = Mobs.knowledgeFromCatalog("a sand giant", ["page": "A sand giant", "drops": .array(["Amber"])])
        let out = Mobs.mergeLocalKnowledge(base, KnowledgeTests.identity("a sand giant"), [:],
                                           Looted([SeenDrop(item: "Giant Toe", count: 3, lastTs: 7)]))
        XCTAssertEqual(out["dropsWiki"].array?.count, 1)
        XCTAssertEqual(out["dropsSeen"][0], ["item": "Giant Toe", "count": 3, "lastTs": 7])
    }

    func testAMobYouHaveNeverLootedCarriesNoDropsSeenKeyAtAll() {
        let base: JSONValue = ["name": "a sand giant", "cached": true,
                               "dropsSeen": .array([["item": "stale"]])]
        let out = Mobs.mergeLocalKnowledge(base, KnowledgeTests.identity("a sand giant"), [:], NoOwnLoot())
        XCTAssertFalse(out.has("dropsSeen"), "absent, never an empty claim")
    }

    func testTheQuestCrossRefIsReadOffRelatedNpcs() {
        let quests: [JSONValue] = [[
            "name": "Corrupt Guards", "page": "Corrupt Guards", "giver": "Vhalen", "startZone": "Qeynos",
            "relatedNpcs": .array(["A Corrupt Qeynos Guard", "a corrupt qeynos guard"])
        ]]
        let index = Mobs.questsByMob(quests)
        let out = Mobs.mergeLocalKnowledge(["name": "a corrupt qeynos guard", "cached": true],
                                           KnowledgeTests.identity("a corrupt qeynos guard"), index, NoOwnLoot())
        XCTAssertEqual(out["quests"].array?.count, 1, "two spellings of one NPC are one quest use")
        XCTAssertEqual(out["quests"][0]["giver"], "Vhalen")
        XCTAssertEqual(out["quests"][0]["zone"], "Qeynos")
    }

    func testTheEraAnnotationAttachesEvidenceAndReachesNoVerdict() {
        let items = ItemDb(map: ["brain of cazic thule": [
            "page": "Brain of Cazic Thule", "eraTag": "FearHateRevamp",
            "dropsFrom": .array([["mob": "Cazic Thule", "zone": "Plane of Fear"],
                                 ["mob": "x", "zone": "Plane of Fear"]])
        ]], keysSorted: ["brain of cazic thule"])
        let record: JSONValue = ["name": "Cazic-Thule", "cached": true,
                                 "dropsWiki": .array([["item": "Brain of Cazic Thule"], ["item": "Amber"]])]
        let out = Mobs.annotateDropEras(record, items)
        XCTAssertEqual(out["dropsWiki"][0]["eraTag"], "FearHateRevamp")
        XCTAssertEqual(out["dropsWiki"][0]["eraZones"], .array(["Plane of Fear"]), "deduped")
        XCTAssertFalse(out["dropsWiki"][1].has("eraTag"), "an item the corpus lacks is unchanged")
        XCTAssertFalse(out["dropsWiki"][0].has("outOfEra"), "no verdict of any kind is written")
    }

    // MARK: - lib.rs (against the committed bytes)

    func testTheCommittedItemCorpusAnswersARealItemWithNoMiss() {
        let corpus = KnowledgeCorpus()
        let answer = corpus.item("Cloak of Flames")
        XCTAssertTrue(answer.found, "the corpus holds Cloak of Flames")
        XCTAssertEqual(answer.record["name"], "Cloak of Flames")
        XCTAssertEqual(answer.record["cached"], true)
        XCTAssertNotNil(answer.record["page"].string)
        XCTAssertTrue(corpus.takeMisses().isEmpty, "a DB hit announces nothing")
    }

    func testTheItemLevelSuffixResolvesToTheSamePageAndKeepsThePlayersSpelling() {
        let corpus = KnowledgeCorpus()
        let plain = corpus.item("Cloak of Flames")
        let upgraded = corpus.item("Cloak of Flames +4")
        XCTAssertTrue(upgraded.found)
        XCTAssertEqual(upgraded.record["page"], plain.record["page"])
        XCTAssertEqual(upgraded.record["name"], "Cloak of Flames",
                       "the display name is the +N-stripped base, which is what normalizeItemName answers")
    }

    func testANameNoCorpusHoldsIsAnnouncedExactlyOnceAndStillAnswers() {
        let corpus = KnowledgeCorpus()
        let answer = corpus.item("A Thing That Does Not Exist")
        XCTAssertFalse(answer.found)
        XCTAssertEqual(answer.record["offline"], true)
        XCTAssertEqual(answer.record["questUses"], .array([]))
        let misses = corpus.takeMisses()
        XCTAssertEqual(misses, [KnowledgeMiss(domain: "item", name: "A Thing That Does Not Exist")])
        // …and asking again announces nothing: the app is asked to fetch a name once.
        _ = corpus.item("A Thing That Does Not Exist")
        XCTAssertTrue(corpus.takeMisses().isEmpty)
    }

    func testAPushedAnswerTurnsTheNextLookupIntoAHit() {
        let corpus = KnowledgeCorpus()
        XCTAssertFalse(corpus.item("A Thing That Does Not Exist").found)
        XCTAssertEqual(corpus.takeMisses().count, 1)
        XCTAssertTrue(corpus.define("item", "A Thing That Does Not Exist",
                                    ["page": "A Thing", "lore": true, "summary": "pushed by the app"]))
        let answer = corpus.item("A Thing That Does Not Exist")
        XCTAssertTrue(answer.found)
        XCTAssertEqual(answer.record["lore"], true)
        XCTAssertEqual(answer.record["summary"], "pushed by the app")
        XCTAssertEqual(answer.record["name"], "A Thing That Does Not Exist")
        XCTAssertEqual(answer.record["quest"], false, "the omitted default is restored")
        XCTAssertTrue(corpus.takeMisses().isEmpty)
        XCTAssertEqual(corpus.overlaySize("item"), 1)
    }

    func testADefineIsIdempotentAndADomainWithNoFetcherIsRefused() {
        let corpus = KnowledgeCorpus()
        let entry: JSONValue = ["page": "A Thing"]
        XCTAssertTrue(corpus.define("item", "A Thing", entry))
        XCTAssertTrue(corpus.define("item", "A Thing", entry))
        XCTAssertEqual(corpus.overlaySize("item"), 1, "the same push twice is one entry")
        XCTAssertFalse(corpus.define("spell", "Complete Heal", entry), "no app-side fetcher")
        XCTAssertFalse(corpus.define("quest", "Corrupt Guards", entry))
    }

    func testAPushedNegativeIsAnAnswerAndStopsTheAsking() {
        let corpus = KnowledgeCorpus()
        XCTAssertTrue(corpus.define("item", "Nothing At All", ["page": "", "notFound": true]))
        let answer = corpus.item("Nothing At All")
        XCTAssertFalse(answer.found, "a real negative is not a find")
        XCTAssertTrue(corpus.takeMisses().isEmpty, "but it is an ANSWER, so nobody is asked again")
    }

    func testTheCommittedMobCatalogAnswersAConWithTheDropTable() {
        let corpus = KnowledgeCorpus()
        let answer = corpus.mob("a sand giant", loot: NoOwnLoot())
        XCTAssertTrue(answer.found, "the catalog holds a sand giant")
        XCTAssertEqual(answer.record["name"], "a sand giant", "the log's own spelling is kept")
        XCTAssertNotNil(answer.record["page"].string)
        XCTAssertTrue(corpus.takeMisses().isEmpty)
    }

    func testYourOwnLootJoinsTheMobAnswerThroughTheFoldsIndex() {
        let corpus = KnowledgeCorpus()
        let answer = corpus.mob("a sand giant", loot: Looted([SeenDrop(item: "Giant Toe", count: 3, lastTs: 7)]))
        XCTAssertEqual(answer.record["dropsSeen"][0]["count"], 3)
        // …and the same mob with no history carries no such key at all.
        XCTAssertFalse(corpus.mob("a sand giant", loot: NoOwnLoot()).record.has("dropsSeen"))
    }

    func testTheRosterIsWhatSaysTwoSpellingsAreOneCreature() {
        // The log spells this god with a HYPHEN and the catalog with a SPACE; bosses.json is the only
        // committed statement that they are one creature.
        let corpus = KnowledgeCorpus()
        let keys = corpus.identityKeys("Cazic-Thule")
        XCTAssertGreaterThan(keys.count, 1, "the roster states more than one spelling: \(keys)")
        let answer = corpus.mob("Cazic-Thule", loot: NoOwnLoot())
        XCTAssertTrue(answer.found, "reached by the LOG spelling")
        XCTAssertEqual(answer.record["name"], "Cazic-Thule", "and it reads back what the log said")
        // An unaliased mob is one key — the unchanged path for the rest of the catalog.
        XCTAssertEqual(corpus.identityKeys("a sand giant"), ["a sand giant"])
    }

    func testAMobTheCatalogLacksIsAnnouncedUnderTheNameTheWikiWouldBeAsked() {
        let corpus = KnowledgeCorpus()
        let answer = corpus.mob("a creature nobody scraped", loot: NoOwnLoot())
        XCTAssertFalse(answer.found)
        XCTAssertEqual(answer.record["offline"], true)
        XCTAssertEqual(corpus.takeMisses(), [KnowledgeMiss(domain: "mob", name: "a creature nobody scraped")])
    }

    func testTheSpellSurfaceAnswersOffTheEffectiveCatalog() {
        let corpus = KnowledgeCorpus()
        let answer = corpus.spell("Complete Heal")
        XCTAssertTrue(answer.found)
        XCTAssertEqual(answer.record["name"], "Complete Heal")
        XCTAssertEqual(answer.record["queried"], "Complete Heal")
        XCTAssertEqual(answer.record["illusion"], false)
        // The named gap, pinned so it cannot appear by accident and go unexplained.
        XCTAssertFalse(answer.record.has("metrics"))
        XCTAssertFalse(answer.record.has("effectClasses"))
        XCTAssertFalse(answer.record.has("lineage"))
        // A name the catalog does not carry is an answer, not an error, and announces nothing —
        // there is no app-side spell fetcher to announce it to.
        let missing = corpus.spell("Spell Of Nothing")
        XCTAssertFalse(missing.found)
        XCTAssertEqual(missing.record["queried"], "Spell Of Nothing")
        XCTAssertTrue(corpus.takeMisses().isEmpty)
    }

    func testSearchRanksExactFirstAndReportsTheWholeMatchCount() {
        let corpus = Self.corpus
        let out = corpus.search("Cloak of Flames")
        XCTAssertEqual(out["hits"][0]["name"], "Cloak of Flames", "exact before prefix before contains")
        XCTAssertEqual(out["hits"][0]["domain"], "item")
        XCTAssertGreaterThanOrEqual(out["total"].int ?? 0, 1)

        // The domain filter is a filter, not a hint.
        let mobs = corpus.search("giant", domain: "mob", limit: 5)
        XCTAssertLessThanOrEqual(mobs["hits"].array?.count ?? 0, 5)
        for hit in mobs["hits"].array ?? [] { XCTAssertEqual(hit["domain"], "mob") }

        // An empty query is an empty answer rather than the whole corpus.
        XCTAssertEqual(corpus.search("   ")["total"], 0)
    }

    func testASearchLimitCannotBeTalkedAboveTheCap() {
        let out = Self.corpus.search("a", limit: 100_000)
        XCTAssertLessThanOrEqual(out["hits"].array?.count ?? 0, searchMaxLimit)
    }

    func testTheProcessCorpusIsOneCorpus() {
        XCTAssertTrue(KnowledgeCorpus.shared() === KnowledgeCorpus.shared())
    }

    // MARK: - helpers

    static func identity(_ name: String) -> Identity {
        Identity(canonical: name, keys: [name.lowercased()], aliased: false)
    }

    final class Looted: OwnLoot {
        let drops: [SeenDrop]
        init(_ drops: [SeenDrop]) { self.drops = drops }
        func dropsAcross(_ spellings: [String]) -> [SeenDrop] { drops }
    }
}

/// engined/src/search.rs — the fight scorer, and the app's own golden cases mirrored.
final class FightSearchScoringTests: XCTestCase {
    /// One authored summary. Only the fields the scorer and the tie-break read are stated.
    private func fight(_ id: String, _ name: String, _ zone: String, _ startTs: Int64) -> JSONValue {
        ["id": .string(id), "kind": "fight", "name": .string(name), "zone": .string(zone), "startTs": .int(startTs)]
    }

    private func names(_ hits: [Search.Hit]) -> [String] { hits.map { $0.summary["id"].string ?? "" } }

    func testPunctuationAndCaseAreNotPartOfAToken() {
        XCTAssertEqual(Search.tokenize("Baron Telyx V`Zher"), ["baron", "telyx", "v", "zher"])
        XCTAssertEqual(Search.tokenize("a zol ghoul knight (3)+2"), ["a", "zol", "ghoul", "knight", "3", "2"])
        XCTAssertTrue(Search.tokenize("   ").isEmpty)
    }

    func testATransposedPairIsOneEditAndAnUnrelatedWordAborts() {
        // The two real typos the app's own decision record names.
        XCTAssertEqual(Search.damerauLevenshtein("gohul", "ghoul", 2), 1)
        XCTAssertEqual(Search.damerauLevenshtein("freeprot", "freeport", 2), 1)
        // `gohl` → `ghoul` is two: transpose, then insert.
        XCTAssertEqual(Search.damerauLevenshtein("gohl", "ghoul", 2), 2)
        // Further apart than the budget: the answer is the abort value, not the true distance.
        XCTAssertEqual(Search.damerauLevenshtein("dragon", "slayer", 2), 3)
    }

    func testEveryQueryTokenMustMatchSomething() {
        // The coverage rule: `gohul knigt` must not surface every ghoul in the corpus because one
        // word landed, which is the difference between exclusion and a score of 0.
        let corpus = [fight("f1", "a zol ghoul knight", "Freeport", 100),
                      fight("f2", "a zol ghoul wizard", "Freeport", 200)]
        XCTAssertEqual(names(Search.search(corpus, "gohul knigt", 50)), ["f1"])
        XCTAssertTrue(Search.search(corpus, "dragon slayer", 50).isEmpty)
    }

    func testTheZoneIsPartOfTheHaystackAndSurvivesATypo() {
        let corpus = [fight("f1", "a dervish cutthroat", "Freeport", 100),
                      fight("f2", "a dervish cutthroat", "Najena", 200)]
        XCTAssertEqual(names(Search.search(corpus, "freprot", 50)), ["f1"])
    }

    func testAnEmptyQueryIsNoHitsRatherThanEverything() {
        let corpus = [fight("f1", "a bat", "Innothule Swamp", 100)]
        XCTAssertTrue(Search.search(corpus, "", 50).isEmpty)
        XCTAssertTrue(Search.search(corpus, "   \t ", 50).isEmpty)
        // …and a query of pure punctuation tokenizes to nothing, which is the same state.
        XCTAssertTrue(Search.search(corpus, "`'()", 50).isEmpty)
    }

    func testTiesBreakByRecencyAndThenById() {
        // Three fights that score identically by construction: same name, same zone.
        let corpus = [fight("f1", "a sand giant", "Oasis", 100),
                      fight("f3", "a sand giant", "Oasis", 300),
                      // Same instant as f1 — EQ stamps to the second, so `id` is what settles it.
                      fight("f0", "a sand giant", "Oasis", 100)]
        XCTAssertEqual(names(Search.search(corpus, "sand giant", 50)), ["f3", "f0", "f1"])
    }

    func testAnExactTokenOutranksAPrefixAndAPrefixATypo() {
        let corpus = [fight("exact", "ghoul", "Neriak", 100),
                      fight("prefix", "ghoulbane", "Neriak", 100),
                      fight("typo", "gohul", "Neriak", 100)]
        XCTAssertEqual(names(Search.search(corpus, "ghoul", 50)), ["exact", "prefix", "typo"])
    }

    func testTheLimitCapsTheRankedListRatherThanTheSearch() {
        let corpus = (0..<10).map { fight("f\($0)", "a sand giant", "Oasis", Int64($0)) }
        let hits = Search.search(corpus, "sand", 3)
        XCTAssertEqual(hits.count, 3)
        // Newest first, because every one of them scores the same.
        XCTAssertEqual(names(hits), ["f9", "f8", "f7"])
    }
}
