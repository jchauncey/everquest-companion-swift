import XCTest
@testable import EQCompanion

/// The focus-exaltation overlay (exaltations.json, scraped from the wiki) and its join to items.
/// Every row must point at an item the corpus actually carries, the lookup must resolve by name,
/// and a gear row must carry its exaltation so the page can filter and the card can show it.
final class ExaltationTests: XCTestCase {
    private static let data: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/EQData/data")

    @MainActor
    func testTheOverlayResolvesAKnownItemsFocusEffect() {
        let ex = GameData.shared.exaltation(forItem: "Green Silken Drape")
        XCTAssertEqual(ex?.effect, "Affliction Haste II")
        XCTAssertEqual(ex?.decaysAfter, 44)
        XCTAssertEqual(Set(ex?.category ?? []), ["Spell Haste", "DoT"])
        XCTAssertTrue(ex?.description?.contains("cast time") ?? false)
    }

    @MainActor
    func testTheLookupToleratesSpellingAndArticles() {
        // The corpus keys apostrophes with a backtick; a caller with a straight apostrophe or odd
        // casing must still resolve, because names arrive from logs and the wiki alike.
        XCTAssertNotNil(GameData.shared.exaltation(forItem: "green silken drape"))
        XCTAssertNotNil(GameData.shared.exaltation(forItem: "Chrysoberyl Talisman"))
    }

    @MainActor
    func testEveryOverlayRowPointsAtACorpusItem() {
        // A row whose item is not in items.json is a dead join - it would show on no card and
        // filter nothing. The generator matches against the corpus, so this must stay empty.
        let items = GameData.shared.items
        var orphans: [String] = []
        for (nameKey, _) in GameData.shared.exaltations where items[nameKey] == nil {
            orphans.append(nameKey)
        }
        XCTAssertEqual(orphans, [], "every exaltation row must join to a corpus item")
        XCTAssertGreaterThan(GameData.shared.exaltations.count, 100, "the overlay should be populated")
        XCTAssertGreaterThan(GameData.shared.exaltationEffects.count, 40, "many distinct focus effects")
    }

    @MainActor
    func testAGearRowCarriesItsExaltationAndItJoinsTheSearchCorpus() {
        let corpus = GearIndex.build(
            itemsURL: Self.data.appendingPathComponent("items.json"),
            zonesURL: Self.data.appendingPathComponent("zones.json"),
            researchURL: Self.data.appendingPathComponent("itemsResearch.json"),
            exaltationsURL: Self.data.appendingPathComponent("exaltations.json"))
        let drape = corpus.rows.first { $0.name == "Green Silken Drape" }
        XCTAssertEqual(drape?.exaltation?.effect, "Affliction Haste II")
        // The effect name is searchable even though the item's own stats block never prints it.
        XCTAssertTrue(drape?.searchKey.contains("affliction haste") ?? false,
                      "typing the exaltation's effect must find the item")
    }

    @MainActor
    func testTheExaltationFilterKeepsOnlyMatchingItems() {
        let corpus = GearIndex.build(
            itemsURL: Self.data.appendingPathComponent("items.json"),
            zonesURL: Self.data.appendingPathComponent("zones.json"),
            researchURL: Self.data.appendingPathComponent("itemsResearch.json"),
            exaltationsURL: Self.data.appendingPathComponent("exaltations.json"))
        let want: Set<String> = ["Spell Haste II"]
        let kept = corpus.rows.filter { row in row.exaltation.map { want.contains($0.effect) } ?? false }
        XCTAssertFalse(kept.isEmpty, "Spell Haste II is granted by several items")
        XCTAssertTrue(kept.allSatisfy { $0.exaltation?.effect == "Spell Haste II" })
        XCTAssertTrue(kept.contains { $0.name == "Djarns Amethyst Ring" })
    }

    @MainActor
    func testBuildWithoutTheOverlayLeavesRowsExaltationless() {
        // The URL is optional; the three-arg build (used elsewhere) must still work with nil.
        let corpus = GearIndex.build(
            itemsURL: Self.data.appendingPathComponent("items.json"),
            zonesURL: Self.data.appendingPathComponent("zones.json"),
            researchURL: Self.data.appendingPathComponent("itemsResearch.json"))
        XCTAssertTrue(corpus.rows.allSatisfy { $0.exaltation == nil })
    }
}
