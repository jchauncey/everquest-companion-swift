import XCTest
@testable import EQCompanion

/// The article seam is allowed to reach exactly one other spelling of the SAME name. These tests
/// pin both halves: that the real corpus mismatches resolve, and that nothing else does.
final class NameArticlesTests: XCTestCase {
    func testVariantsAreArticlesAndNothingElse() {
        XCTAssertEqual(NameArticles.variants(of: "Dark Reaver"), ["A Dark Reaver", "An Dark Reaver", "The Dark Reaver"])
        // Already articled: the one alternative is the bare name, never more articles.
        XCTAssertEqual(NameArticles.variants(of: "A Snake Venom Sac"), ["Snake Venom Sac"])
        XCTAssertEqual(NameArticles.variants(of: "the Scepter of Destruction"), ["Scepter of Destruction"])
        XCTAssertEqual(NameArticles.variants(of: ""), [])
        XCTAssertEqual(NameArticles.variants(of: "a"), ["A a", "An a", "The a"], "a bare word is not an article")
        // An article INSIDE the name is not a prefix and must not be touched.
        XCTAssertEqual(NameArticles.variants(of: "Cloak of a Thousand Eyes").count, 3)
        XCTAssertFalse(NameArticles.variants(of: "Cloak of a Thousand Eyes").contains("Cloak of Thousand Eyes"))
    }

    /// Both directions, against the shipped corpus: the drop spelling that needs an article added,
    /// and the one that needs it removed.
    @MainActor
    func testCorpusMismatchesResolveBothWays() {
        let g = GameData.shared
        XCTAssertEqual(g.articleVariant(domain: "item", of: "Dark Reaver"), "A Dark Reaver")
        XCTAssertEqual(g.articleVariant(domain: "item", of: "A Snake Venom Sac"), "Snake Venom Sac")
        // A name that already resolves is never redirected - the exact page always wins.
        XCTAssertNil(g.articleVariant(domain: "item", of: "A Dark Reaver"))
        XCTAssertNil(g.articleVariant(domain: "item", of: "Adamantite Epaulets"))
        // A name no article can rescue stays a miss.
        XCTAssertNil(g.articleVariant(domain: "item", of: "Nonexistent Blade of Nothing"))
        XCTAssertNil(g.articleVariant(domain: "spell", of: "Dark Reaver"), "only item and mob resolve")

        // And the local item lookup itself now crosses the seam.
        XCTAssertEqual(g.item(named: "Dark Reaver")?.page, "A Dark Reaver")
        XCTAssertEqual(g.item(named: "A Dark Reaver")?.page, "A Dark Reaver")
    }

    /// The whole point: the drop edges the corpus could not join before now join.
    @MainActor
    func testWikiDropNamesResolveAcrossTheCorpus() {
        let g = GameData.shared
        var unresolved = 0, rescued = 0
        for m in g.mobs {
            for d in m.drops {
                if g.items[GameData.nameKey(d)] != nil { continue }
                unresolved += 1
                if g.item(named: d) != nil { rescued += 1 }
            }
        }
        XCTAssertGreaterThan(rescued, 40, "the article seam should rescue the ~50 known mismatches")
        XCTAssertLessThan(rescued, unresolved, "a real miss must stay a miss")
    }
}
