import XCTest
@testable import EQCompanion

/// Zone-name resolution across the article seam. The zone roster spells the planes with a leading
/// "The" ("The Plane of Hate"); the mob and item corpora spell them without ("Plane of Hate"). That
/// one word left the planes' mobs off their own maps and broke the gear→map jump into them. Every
/// resolver here must bridge the two spellings, in both directions, without folding distinct zones
/// together.
final class ZoneResolveTests: XCTestCase {
    @MainActor
    func testTheCorpusReallyDisagreesWithTheRosterAboutTheArticle() {
        // Guards the premise: if the data is ever cleaned up so both sides spell it the same, this
        // test should be revisited rather than silently passing on a moot point.
        let g = GameData.shared
        let hate = g.zones.first { $0.short == "hateplane" }
        XCTAssertEqual(hate?.name, "The Plane of Hate", "the roster keeps the article")
        let mobs = g.mobs(inLogZone: "Plane of Hate")
        XCTAssertFalse(mobs.isEmpty, "the mob corpus spells it without the article")
    }

    @MainActor
    func testAPlaneResolvesFromEitherSpelling() {
        let g = GameData.shared
        XCTAssertEqual(g.zone(forLogName: "Plane of Hate")?.short, "hateplane")
        XCTAssertEqual(g.zone(forLogName: "The Plane of Hate")?.short, "hateplane")
        XCTAssertEqual(g.zone(forLogName: "plane of fear")?.short,
                       g.zone(forLogName: "The Plane of Fear")?.short)
    }

    @MainActor
    func testThePlanesMobsLandOnTheirMapUnderTheRostersName() {
        let g = GameData.shared
        // The map opens the zone under the ROSTER's name; the mobs are filed under the corpus's.
        // Both the roster spelling and the bare spelling must return the same non-empty roster.
        let viaRoster = g.mobs(inLogZone: "The Plane of Hate")
        let viaCorpus = g.mobs(inLogZone: "Plane of Hate")
        XCTAssertFalse(viaRoster.isEmpty, "the Plane of Hate map must show its mobs")
        XCTAssertEqual(Set(viaRoster.map(\.page)), Set(viaCorpus.map(\.page)),
                       "the same mobs, whichever spelling the map used")
        XCTAssertTrue(viaRoster.contains { $0.name.lowercased().contains("ghoul") || $0.zones.contains("Plane of Hate") })
    }

    func testTheArticleFlipIsAWholeWordNotAPrefix() {
        // "Theater of..." must not lose its "The" — the flip is the article, not any leading "the".
        XCTAssertEqual(GameData.zoneKeyVariants("Theater of Blood"), ["theaterofblood", "thetheaterofblood"])
        // The real article, both directions.
        XCTAssertEqual(GameData.zoneKeyVariants("The Plane of Hate"), ["theplaneofhate", "planeofhate"])
        XCTAssertEqual(GameData.zoneKeyVariants("Plane of Hate"), ["planeofhate", "theplaneofhate"])
        XCTAssertEqual(GameData.zoneKeyVariants(""), [])
    }

    @MainActor
    func testAJumpToAOneZoneDropOpensStraightAway() {
        MapJump.shared.show(mob: "a ghoul lord", zonesLongNames: ["Plane of Hate"])
        let p = MapJump.shared.pending
        XCTAssertEqual(p?.zone, "hateplane", "a single resolved zone loads without a prompt")
        XCTAssertTrue(p?.zoneChoices.isEmpty ?? false)
        MapJump.shared.clear()
    }

    @MainActor
    func testAJumpToAMultiZoneDropAsksWhichZone() {
        MapJump.shared.show(mob: "a fetid fiend", zonesLongNames: ["Plane of Fear", "Plane of Hate"])
        let p = MapJump.shared.pending
        XCTAssertNil(p?.zone, "no zone is chosen yet - the map must ask")
        XCTAssertEqual(p?.zoneChoices, ["fearplane", "hateplane"])
        // Resolving keeps the same request (mob and seq), now with a zone.
        MapJump.shared.resolveChoice("hateplane")
        XCTAssertEqual(MapJump.shared.pending?.zone, "hateplane")
        XCTAssertEqual(MapJump.shared.pending?.seq, p?.seq)
        XCTAssertTrue(MapJump.shared.pending?.zoneChoices.isEmpty ?? false)
        MapJump.shared.clear()
    }

    @MainActor
    func testUnresolvableZonesDropOutRatherThanPrompt() {
        // One resolves, one is nonsense: no prompt, straight to the one that resolved.
        MapJump.shared.show(mob: "x", zonesLongNames: ["Nowhere At All", "Plane of Hate"])
        XCTAssertEqual(MapJump.shared.pending?.zone, "hateplane")
        XCTAssertTrue(MapJump.shared.pending?.zoneChoices.isEmpty ?? false)
        MapJump.shared.clear()
    }
}
