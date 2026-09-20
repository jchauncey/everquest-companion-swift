import XCTest
@testable import EQCompanion

/// The Stats picker: "what has STR and WIS" - an AND over what an item gives, so each stat chosen
/// narrows the table further, and a penalty is not a stat.
final class GearStatFilterTests: XCTestCase {
    @MainActor
    private func corpus() -> [GearRow] {
        let roots = GameData.shared.roots
        return GearIndex.build(itemsURL: roots.data.appendingPathComponent("items.json"),
                               zonesURL: roots.generated.appendingPathComponent("zones.json"),
                               researchURL: roots.data.appendingPathComponent("itemsResearch.json")).rows
    }

    func testEveryChosenStatMustBeGivenAndAPenaltyIsNotGiving() {
        let stats = ["STR": 5, "WIS": 3, "CHA": -5, "AC": 0]
        XCTAssertTrue(gearGivesEveryStat(stats, []), "no pick keeps everything")
        XCTAssertTrue(gearGivesEveryStat(stats, ["STR"]))
        XCTAssertTrue(gearGivesEveryStat(stats, ["STR", "WIS"]))
        XCTAssertFalse(gearGivesEveryStat(stats, ["STR", "INT"]), "AND: one missing stat fails the item")
        XCTAssertFalse(gearGivesEveryStat(stats, ["CHA"]), "-5 CHA is a penalty, not CHA")
        XCTAssertFalse(gearGivesEveryStat(stats, ["AC"]), "a stated zero is not giving")
    }

    /// Against the committed corpus: an item known to give both, one known to give only STR, and
    /// the monotonic narrowing the picker promises.
    @MainActor
    func testAddingAStatOnlyNarrows() throws {
        let rows = corpus()
        let armband = try XCTUnwrap(rows.first { $0.key == "adamantite armband" })
        XCTAssertTrue(gearGivesEveryStat(armband.stats, ["STR", "WIS"]))
        let rod = try XCTUnwrap(rows.first { $0.key == "abashi`s rod of disempowerment" })
        XCTAssertTrue(gearGivesEveryStat(rod.stats, ["STR"]))
        XCTAssertFalse(gearGivesEveryStat(rod.stats, ["STR", "WIS"]))

        let str = rows.filter { gearGivesEveryStat($0.stats, ["STR"]) }.count
        let strWis = rows.filter { gearGivesEveryStat($0.stats, ["STR", "WIS"]) }.count
        let three = rows.filter { gearGivesEveryStat($0.stats, ["STR", "WIS", "SV_FIRE"]) }.count
        XCTAssertGreaterThan(str, strWis)
        XCTAssertGreaterThanOrEqual(strWis, three)
        XCTAssertGreaterThan(three, 0, "the corpus has STR+WIS+SV FIRE items")
    }

    /// The picker offers what an item gives, spelled the way a player asks, and never a weapon
    /// column or the weight.
    func testThePickerOffersStatsNotColumns() {
        XCTAssertTrue(gearStatFilterKeys.contains("AC"))
        XCTAssertTrue(gearStatFilterKeys.contains("SV_FIRE"))
        XCTAssertTrue(gearStatFilterKeys.contains("HASTE"))
        for k in ["DMG", "DELAY", "RATIO", "WEIGHT", "BACKSTAB", "RANGE", "DMG_BONUS"] {
            XCTAssertFalse(gearStatFilterKeys.contains(k), "\(k) is not a stat an item gives")
        }
        XCTAssertEqual(gearStatFilterLabel("MP"), "MANA")
        XCTAssertEqual(gearStatFilterLabel("SV_FIRE"), "SV FIRE")
        XCTAssertEqual(gearStatFilterLabel("HP_REGEN"), "HP REGEN")
    }
}
