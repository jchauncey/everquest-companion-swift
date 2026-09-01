import XCTest
@testable import EQCompanion

/// The era verdict against the committed corpus — regression cover for the article mismatch that
/// hid whole armor sets. The zone roster spells its rows "The Plane of Fear"; the wiki's drop
/// tables say "Plane of Fear". Before the zone-era table registered both article variants, that
/// one word left thousands of drop rows unresolvable, and every item whose zones all failed to
/// resolve (Umbral Platemail among them) was verdicted `unknown` — which the Current era toggle
/// hides. A classic-zone drop must verdict in-era under either spelling.
final class GearEraTests: XCTestCase {
    // Read straight off disk rather than through GameData: under `swift test` Bundle.main is the
    // xctest harness, so the app's own root walk cannot find the checkout.
    private static let data: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // EQCompanionTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("Sources/EQData/data")

    private static let corpus: GearCorpus = GearIndex.build(
        itemsURL: data.appendingPathComponent("items.json"),
        zonesURL: data.appendingPathComponent("zones.json"),
        researchURL: data.appendingPathComponent("itemsResearch.json"))

    private func row(_ key: String) throws -> GearRow {
        try XCTUnwrap(Self.corpus.byKey[key], "\(key) should be in the committed corpus")
    }

    func testAnItemDroppingInTheArticlelessSpellingOfAClassicZoneIsInEra() throws {
        // The wiki's drop row says "Plane of Fear"; the zone roster says "The Plane of Fear".
        let boots = try row("umbral platemail boots")
        XCTAssertEqual(boots.drops.map(\.zone), ["Plane of Fear"])
        XCTAssertEqual(boots.era, .inEra,
                       "a Plane of Fear drop is farmable in classic, whichever side keeps the article")
    }

    func testAKunarkOnlyDropStaysOutOfEraUnderTheSameArticleRule() throws {
        // The article fold must not blur eras: "Dreadlands" resolves (to Kunark) and stays out.
        let out = Self.corpus.rows.first { r in
            !r.drops.isEmpty && r.drops.allSatisfy { $0.zone == "Dreadlands" }
        }
        let found = try XCTUnwrap(out, "the corpus should hold at least one Dreadlands-only drop")
        XCTAssertEqual(found.era, .outOfEra, "\(found.name) drops only in Kunark")
    }

    func testTheBigClassicOutdoorZonesResolveDespiteTheArticle() throws {
        // The other top spellings the article mismatch orphaned. One item per zone is enough:
        // any resolving classic zone makes its item in-era, so an unknown here means the
        // zone-era table lost the spelling again.
        for zone in ["Plane of Sky", "Lesser Faydark", "Plane of Hate", "Ocean of Tears"] {
            let item = Self.corpus.rows.first { r in
                !r.drops.isEmpty && r.drops.allSatisfy { $0.zone == zone }
            }
            guard let item else { continue }
            XCTAssertEqual(item.era, .inEra, "\(item.name) drops only in \(zone), a classic zone")
        }
    }
}
