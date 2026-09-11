// The committed loot corrections: that each one still lands, that each one is self-retiring, and
// that none of them reaches a mob the golden oracle pins.
//
// These assert the CONTRACT, not the contents. A new fix should not need an edit here — what is
// stated below is that a guard holds only while the error does, that a merge is a union in the
// canonical page's order, and that the alias never survives as a mob of its own.
import XCTest
@testable import EQKnowledge
import EQCompanionCore
@testable import EQEngine

final class MobLootFixesTests: XCTestCase {

    /// Every shipped fix must still apply: a correction whose guard has quietly stopped holding is
    /// dead weight that reads, from the file, as though it were doing something.
    func testEveryShippedFixStillLands() {
        let index = MobIndex.build()
        for a in MobLootFixes.shipped.aliases {
            XCTAssertNotNil(index.entry(a.mob), "\(a.mob) is not in the catalog")
            let merged = (index.entry(a.mob)?["drops"].array ?? []).compactMap(\.string)
            XCTAssertFalse(merged.isEmpty, "\(a.mob) has no drops after the merge")
            XCTAssertFalse(a.why.isEmpty, "\(a.mob) -> \(a.alias) is uncited")
        }
        for d in MobLootFixes.shipped.drops {
            let have = (index.entry(d.mob)?["drops"].array ?? []).compactMap { $0.string.map { $0.lowercased() } }
            for item in d.add {
                XCTAssertTrue(have.contains(item.lowercased()), "\(d.mob) is missing \(item)")
            }
            XCTAssertFalse(d.why.isEmpty, "\(d.mob) \(d.add) is uncited")
        }
    }

    /// The rat is the case the whole file exists for: unmerged it states one warrior item, and the
    /// fifteen that make it worth camping are on the page the game never names.
    func testTheRatKeepsItsArmour() {
        let drops = (MobIndex.build().entry("a revultant rat")?["drops"].array ?? []).compactMap(\.string)
        for piece in ["Indicolite Breastplate", "Indicolite Greaves", "Legionnaire Scale Breastplate",
                      "Legionnaire Scale Boots", "Revultant Whip", "Woven Shadow Bracer"] {
            XCTAssertTrue(drops.contains(piece), "a revultant rat lost \(piece)")
        }
    }

    /// The alias is not a creature. Leaving it indexed would put a second rat in the zone's list and
    /// offer search a name the game never prints.
    func testTheAliasIsGoneFromTheCatalog() {
        let index = MobIndex.build()
        for a in MobLootFixes.shipped.aliases where a.alias.lowercased() != a.mob.lowercased() {
            // `Innoruuk`s Chosen` folds to the canonical page's own key, so it must still ANSWER —
            // what must not survive is a second display name.
            XCTAssertFalse(index.names().contains(a.alias), "\(a.alias) is still a mob of its own")
        }
    }

    /// A guard that only holds while the error does. Stated over a corpus of this test's own making,
    /// so the shipped file can change without rewriting the rule.
    func testAFixRetiresWhenTheCorpusIsFixed() {
        let fixes = MobLootFixes.Fixes(
            aliases: [.init(mob: "a rat", alias: "a ratte", zone: "Somewhere", why: "cited")],
            drops: [.init(mob: "a rat", add: ["Tail"], why: "cited")])

        // The error present: two pages, and the drop absent.
        let split: [JSONValue] = [
            ["name": "a rat", "zones": ["Somewhere"], "drops": ["Whisker"]],
            ["name": "a ratte", "zones": ["Somewhere"], "drops": ["Whisker", "Ear"]]
        ]
        let merged = MobLootFixes.apply(split, fixes)
        XCTAssertEqual(merged.count, 1, "the alias page survived the merge")
        XCTAssertEqual(merged[0]["drops"].array?.compactMap(\.string), ["Whisker", "Ear", "Tail"],
                       "a union in the canonical page's order, de-duped, with the stated drop last")

        // The error gone: one page that already says everything. Both fixes must be inert.
        let fixed: [JSONValue] = [["name": "a rat", "zones": ["Somewhere"], "drops": ["Whisker", "Tail"]]]
        XCTAssertEqual(MobLootFixes.apply(fixed, fixes), fixed, "a retired fix still changed the corpus")
    }

    /// A fix must never merge two creatures that merely share a name in different zones.
    func testTheZoneIsPartOfTheGuard() {
        let fixes = MobLootFixes.Fixes(
            aliases: [.init(mob: "a rat", alias: "a ratte", zone: "Somewhere", why: "cited")])
        let elsewhere: [JSONValue] = [
            ["name": "a rat", "zones": ["Somewhere"], "drops": ["Whisker"]],
            ["name": "a ratte", "zones": ["Elsewhere"], "drops": ["Ear"]]
        ]
        XCTAssertEqual(MobLootFixes.apply(elsewhere, fixes), elsewhere,
                       "a fix reached across zones")
    }

    /// The golden oracle pins `knowledge.mob` answers for the fixtures' own mobs. A correction that
    /// touched one of those would break parity with the Rust engine for a reason no golden explains.
    func testNoFixTouchesAGoldenMob() throws {
        let ops = Self.goldenMobNames()
        try XCTSkipIf(ops.isEmpty, "Goldens/ absent")
        let touched = Set(MobLootFixes.shipped.aliases.flatMap { [$0.mob.lowercased(), $0.alias.lowercased()] })
            .union(MobLootFixes.shipped.drops.map { $0.mob.lowercased() })
        XCTAssertTrue(touched.isDisjoint(with: ops),
                      "a fix reaches a mob the goldens pin: \(touched.intersection(ops))")
    }

    /// Every mob name any `ops.json` asks `knowledge.mob` about.
    private static func goldenMobNames() -> Set<String> {
        let goldens = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: goldens,
                                                                     includingPropertiesForKeys: nil)
        else { return [] }
        var out: Set<String> = []
        for d in dirs {
            let f = d.appendingPathComponent("ops.json")
            guard let text = try? String(contentsOf: f, encoding: .utf8),
                  let json = try? JSONValue.parse(text) else { continue }
            if case .object(let asked) = json["knowledge.mob"] {
                for name in asked.keys { out.insert(name.lowercased()) }
            }
        }
        return out
    }
}
