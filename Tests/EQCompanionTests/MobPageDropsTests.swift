import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The drop relation read from BOTH corpora. The item page's rows lead; the mob pages fill what
/// they lack; a joined row is marked; the mob side has the loot fixes applied first — so the rat
/// the game names is the rat that drops the warrior sets, on every surface that says who drops what.
final class MobPageDropsTests: XCTestCase {
    private static let data: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/EQData/data")

    private static let corpus: GearCorpus = GearIndex.build(
        itemsURL: data.appendingPathComponent("items.json"),
        zonesURL: data.appendingPathComponent("zones.json"),
        researchURL: data.appendingPathComponent("itemsResearch.json"),
        mobsURL: data.appendingPathComponent("mobs.json"),
        lootFixesURL: data.appendingPathComponent("mobLootFixes.json"))

    private func row(_ key: String) throws -> GearRow {
        try XCTUnwrap(Self.corpus.byKey[key], "\(key) should be in the committed corpus")
    }

    /// Item-page rows first and in their order; then only what the mob pages add; one dropper
    /// stated under two spellings of its name or its zone is one row.
    func testUnionKeepsTheItemPageFirstAndStatesEachDropperOnce() {
        let pages = MobPageDrops(mobs: [
            ["name": "a rat", "zones": ["The Plane of Hate"], "drops": ["Whisker", "Tail"]],
            ["name": "Innoruuk`s Chosen", "zones": ["Plane of Hate"], "drops": ["Whisker"]],
            ["name": "a bat", "drops": ["Whisker"]]
        ])
        let wiki = [GearDrop(mob: "a cat", zone: "Plane of Fear"), GearDrop(mob: "A Rat", zone: "Plane of Hate"),
                    GearDrop(mob: "Innoruuk's Chosen", zone: "Plane of Hate")]
        let merged = pages.union(wiki, for: GameData.nameKey("Whisker"))
        XCTAssertEqual(Array(merged.prefix(3)), wiki, "the item page's own rows lead, untouched")
        XCTAssertEqual(merged.dropFirst(3).map(\.mob), ["a bat"],
                       "the rat under the article and the Chosen under the backtick are already stated")
        XCTAssertEqual(merged.last?.zone, "", "a page stating no zone names a dropper with a blank zone")
        XCTAssertEqual(pages.union([], for: "nothing"), [], "an item no mob page lists gains nothing")
    }

    /// The case the join exists for: the item page never named the rat.
    func testTheRatDropsTheWarriorSetsOnTheGearTable() throws {
        let plate = try row("indicolite breastplate")
        XCTAssertTrue(plate.drops.contains(GearDrop(mob: "a revultant rat", zone: "Plane of Hate")),
                      "the breastplate's droppers should name the rat: \(plate.drops)")
        XCTAssertFalse(plate.drops.contains { $0.mob == "a repulsive rat" },
                       "the orphan page's name must not reach the table")
    }

    /// Four pieces of armour the log recorded dropping in Hate whose item page names only Plane of
    /// Fear. The mob page had it right, so the union puts Hate back - and with it an in-era verdict
    /// no longer hangs on one scrape's omission.
    func testArmourTheItemPageFiledUnderTheWrongPlaneRegainsHate() throws {
        for (key, mob) in [("blighted armband", "a revultant rat"), ("carmine turban", "a spite golem"),
                           ("shiverback-hide armbands", "a forsaken revenant"), ("thorny vine bracer", "an abhorrent")] {
            let r = try row(key)
            XCTAssertTrue(r.drops.contains { $0.mob == mob && $0.zone == "Plane of Hate" },
                          "\(key) should list \(mob) in Plane of Hate: \(r.drops)")
            XCTAssertEqual(r.drops.first?.zone, "Plane of Fear", "\(key): the item page's own row still leads")
            XCTAssertTrue(r.drops.map(\.zone).contains("Plane of Hate"))
            XCTAssertEqual(r.era, .inEra)
        }
    }

    /// Without the mob side the corpus is what it always was: the join is additive only.
    func testWithoutMobPagesTheCorpusIsUnchanged() throws {
        let bare = GearIndex.build(itemsURL: Self.data.appendingPathComponent("items.json"),
                                   zonesURL: Self.data.appendingPathComponent("zones.json"),
                                   researchURL: Self.data.appendingPathComponent("itemsResearch.json"))
        let plate = try XCTUnwrap(bare.byKey["indicolite breastplate"])
        XCTAssertFalse(plate.drops.contains { $0.mob == "a revultant rat" })
        let joined = try row("indicolite breastplate")
        XCTAssertEqual(Array(joined.drops.prefix(plate.drops.count)), plate.drops)
    }

    /// The join only ADDS sources. Under `layeredVerdict` any resolving zone is final and the
    /// banner speaks only into silence - so a verdict an in-era ZONE earned can never be lost (the
    /// zone is still there), and the one way a verdict may move away from in-era is a banner-only
    /// guess being superseded by the first zone evidence the item ever had (Bamboo Splint Boots:
    /// page banner "Classic", no sources; the mob pages put it on kobold shamans in Stonebrunt).
    /// Stated over the whole corpus, with the size of the shift printed.
    func testTheJoinOnlySupersedesBannerOnlyVerdicts() throws {
        let bare = GearIndex.build(itemsURL: Self.data.appendingPathComponent("items.json"),
                                   zonesURL: Self.data.appendingPathComponent("zones.json"),
                                   researchURL: Self.data.appendingPathComponent("itemsResearch.json"))
        var gained = 0, resolved = 0, restored = 0, superseded = 0, wrong: [String] = []
        for r in Self.corpus.rows {
            guard let b = bare.byKey[r.key] else { continue }
            if r.drops.count > b.drops.count { gained += 1 }
            switch (b.era, r.era) {
            case (.unknown, .inEra), (.unknown, .outOfEra): resolved += 1
            case (.outOfEra, .inEra): restored += 1
            case (.inEra, .outOfEra):
                // Allowed only if no zone of its own ever spoke: the old verdict was the banner's.
                if layeredVerdict(zoneEras: [], tag: b.eraTag) == b.era { superseded += 1 } else { wrong.append(r.name) }
            case (.inEra, .unknown), (.outOfEra, .unknown): wrong.append(r.name)
            default: break
            }
        }
        print("MOB-PAGE JOIN: \(gained) items gained a dropper, \(resolved) unknown verdicts resolved, "
              + "\(restored) out-of-era restored to in-era, \(superseded) banner-only in-era guesses superseded by zone evidence")
        XCTAssertTrue(wrong.isEmpty, "a verdict a zone had earned was lost: \(wrong.prefix(10))")
    }

    /// The map's own read of the catalog: one rat, carrying both pages and saying so.
    @MainActor
    func testTheMapSeesOneRatWithBothPages() throws {
        let mobs = GameData.shared.mobs
        XCTAssertNil(mobs.first { $0.name == "a repulsive rat" }, "the orphan page is still a mob on the map")
        let rat = try XCTUnwrap(mobs.first { $0.name == "a revultant rat" })
        XCTAssertNotNil(rat.lootFix, "the merged row is unmarked")
        XCTAssertTrue(rat.drops.contains("Legionnaire Scale Breastplate"))
        XCTAssertTrue(rat.drops.contains("Woven Shadow Bracer"), "its own page's rows are kept")
        XCTAssertEqual(GameData.shared.mobsByZone[GameData.zoneKey("Plane of Hate")]?.filter { $0.name.hasSuffix("rat") }.count, 1)
    }

    /// Your own log on the item card: a count on the dropper the wiki names, a marked row for the
    /// corpse it does not, `+N` variants counted as one item, destroys and unsourced rows ignored.
    func testYourOwnLootJoinsTheItemCard() {
        func ev(_ item: String, _ src: String?, _ zone: String? = "The Plane of Hate 3 (Fused)", _ n: Int = 1,
                _ disp: String? = nil) -> LootEvent {
            LootEvent(item: item, itemKey: item.lowercased(), countKey: LootName.countKey(item), source: src,
                      zone: zone, ts: 1, count: n, disposition: disp)
        }
        let events = [ev("Indicolite Helm +1", "a spite golem"), ev("Indicolite Helm +2", "a spite golem"),
                      ev("Indicolite Helm +1", "Grandmaster R`tal"), ev("Indicolite Helm", nil),
                      ev("Indicolite Helm +1", "a kiraikuei", nil, 1, "destroyed"), ev("Indicolite Bracer +1", "a revultant rat")]
        let sources = OwnLootSources.sources(for: "Indicolite Helm", in: events)
        XCTAssertEqual(sources.map(\.mob), ["a spite golem", "Grandmaster R`tal"], "most-looted first; the destroy is not a source")
        XCTAssertEqual(sources.first?.count, 2, "+1 and +2 are one helm")

        let record: JSONValue = ["name": "Indicolite Helm",
                                 "dropsFrom": [["mob": "a kiraikuei", "zone": "Plane of Hate"],
                                               ["mob": "Grandmaster R`Tal", "zone": "Plane of Hate", "via": "mob page"]]]
        let joined = OwnLootSources.join(record, sources) { _ in "The Plane of Hate" }
        let rows = joined["dropsFrom"].array ?? []
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0]["looted"].int, "never looted one off a kiraikuei")
        XCTAssertEqual(rows[1]["looted"].int, 1, "R`Tal under the wiki's capital matches R`tal in the log")
        XCTAssertEqual(rows[2]["mob"].string, "a spite golem")
        XCTAssertEqual(rows[2]["via"].string, "your loot")
        XCTAssertEqual(rows[2]["looted"].int, 2)
        XCTAssertEqual(rows[2]["zone"].string, "The Plane of Hate", "the instance's log name resolves to the roster's")
        XCTAssertEqual(OwnLootSources.join(record, []), record, "nothing looted, nothing changed")
    }

    /// The item card's record: joined rows arrive marked, the engine's own rows do not.
    @MainActor
    func testTheItemCardMarksAJoinedRow() {
        let record: JSONValue = ["name": "Indicolite Breastplate", "found": true,
                                 "dropsFrom": [["mob": "a kiraikuei", "zone": "Plane of Hate"]]]
        let joined = GameData.shared.withMobPageDrops(record)
        let rows = joined["dropsFrom"].array ?? []
        XCTAssertEqual(rows.first?["mob"].string, "a kiraikuei")
        XCTAssertNil(rows.first?["via"].string, "the item page's own row is not marked")
        let rat = rows.first { $0["mob"].string == "a revultant rat" }
        XCTAssertEqual(rat?["via"].string, "mob page")
        XCTAssertEqual(rat?["zone"].string, "Plane of Hate")
        // A record that gains nothing is handed back untouched.
        let alone: JSONValue = ["name": "No Such Thing", "dropsFrom": []]
        XCTAssertEqual(GameData.shared.withMobPageDrops(alone), alone)

        // The card holds the ANSWER, `{found, record}` - the join must reach the record inside.
        // (The first cut joined at the top level and showed the item page alone.)
        let helm: JSONValue = ["name": "Indicolite Helm", "dropsFrom": [["mob": "a kiraikuei", "zone": "Plane of Hate"]]]
        let answer: JSONValue = ["found": true, "record": helm]
        let joinedAnswer = GameData.shared.withMobPageDrops(answer: answer)
        XCTAssertEqual(joinedAnswer["found"].bool, true)
        let helmRows = joinedAnswer["record"]["dropsFrom"].array ?? []
        XCTAssertEqual(helmRows.first?["mob"].string, "a kiraikuei", "the item page's row still leads")
        XCTAssertTrue(helmRows.contains { $0["mob"].string == "a spite golem" && $0["via"].string == "mob page" },
                      "the helm the log saw drop from a spite golem: the mob page says so, the item page never did")
        XCTAssertTrue(helmRows.contains { $0["mob"].string == "a revultant rat" })
    }
}
