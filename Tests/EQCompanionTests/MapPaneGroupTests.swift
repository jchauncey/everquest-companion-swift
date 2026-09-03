import XCTest
@testable import EQCompanion

/// The Maps pane's two mob groups: named and rare mobs on top, common spawns under them, each
/// alphabetical — and a group whose toggle is off comes back empty, which is what takes its pins
/// off the map too. The named verdict is `MobNameConvention.isNamed`, three signals deep, because
/// this wiki spells most camp nameds like trash ("a ghoul sage") and capitalization alone missed
/// nearly all of Lower Guk's roster.
final class MapPaneGroupTests: XCTestCase {
    private static func mob(_ name: String, named: Bool) -> MapPaneRow {
        MapPaneRow(kind: .mob, id: name, name: name, level: nil, named: named,
                   pins: [MobPin(x: 0, y: 0, z: nil, pct: nil)],
                   zoneCount: 1, unattributable: false, locFix: nil,
                   searchKey: name.lowercased(), point: nil)
    }

    private let zoo: [MapPaneRow] = [
        // Deliberately shuffled, with a label row that must never appear in a group.
        MapPaneRow(kind: .label, id: "l", name: "to_Freeport", level: nil, pins: [], zoneCount: 0,
                   unattributable: false, locFix: nil, searchKey: "to_freeport", point: nil),
        mob("a ghoul sage", named: true),          // a camp named this wiki spells like trash
        mob("Skeleton Lrodd", named: true),
        mob("an orc pawn", named: false),
        mob("the ghoul lord", named: true),
        mob("a bat", named: false),
    ]

    func testNamedSortAboveCommonAndBothAreAlphabetical() {
        let g = MapPaneRows.grouped(zoo, showNamed: true, showCommon: true)
        XCTAssertEqual(g.named.map(\.name), ["a ghoul sage", "Skeleton Lrodd", "the ghoul lord"])
        XCTAssertEqual(g.common.map(\.name), ["a bat", "an orc pawn"])
        XCTAssertEqual(g.all.map(\.name),
                       ["a ghoul sage", "Skeleton Lrodd", "the ghoul lord", "a bat", "an orc pawn"],
                       "the combined order feeds the pins: nameds first, then commons")
    }

    func testAGroupSwitchedOffIsEmptyAndItsPinsLeaveTheMap() {
        let justNamed = MapPaneRows.grouped(zoo, showNamed: true, showCommon: false)
        XCTAssertEqual(justNamed.common, [])
        XCTAssertEqual(justNamed.named.count, 3)
        let justTrash = MapPaneRows.grouped(zoo, showNamed: false, showCommon: true)
        XCTAssertEqual(justTrash.named, [])
        XCTAssertEqual(MapPaneRows.placedPins(justTrash.all).pins.map(\.name),
                       ["a bat", "an orc pawn"],
                       "pins are drawn from the grouped rows, so an off group pins nothing")
    }

    func testLabelsNeverEnterTheMobGroups() {
        let g = MapPaneRows.grouped(zoo, showNamed: true, showCommon: true)
        XCTAssertFalse(g.all.contains { $0.kind == .label })
    }

    // MARK: - The named verdict, on Lower Guk's own roster

    func testTheThreeSignalsEachMakeANamed() {
        // 1. Capitalized — the wiki's own convention.
        XCTAssertTrue(MobNameConvention.isNamed("Raster of Guk", level: "35", dropsRareLoot: true))
        XCTAssertTrue(MobNameConvention.isNamed("A Froglok Noble", level: "39-40", dropsRareLoot: false))
        // 2. "the " prefix — the definite article names a unique, whatever it drops.
        XCTAssertTrue(MobNameConvention.isNamed("the ghoul lord (Hoptor Thaggelum)", level: "47",
                                                dropsRareLoot: false))
        // 3. One fixed level AND rare loot — the camp nameds this wiki spells like trash.
        XCTAssertTrue(MobNameConvention.isNamed("a ghoul sage", level: "37", dropsRareLoot: true))
        XCTAssertTrue(MobNameConvention.isNamed("a frenzied ghoul", level: "42", dropsRareLoot: true))
    }

    func testNeitherHalfOfTheThirdSignalAloneIsEnough() {
        // A level RANGE is a population, not a named — rare loot or not.
        XCTAssertFalse(MobNameConvention.isNamed("a dar ghoul knight", level: "39-43", dropsRareLoot: true))
        // One stated level with no loot of its own is just precise trash.
        XCTAssertFalse(MobNameConvention.isNamed("a trout", level: "1", dropsRareLoot: false))
        // Fuzzy levels are not single levels.
        XCTAssertFalse(MobNameConvention.isNamed("a carrion bat", level: "50 ~ 55", dropsRareLoot: true))
        XCTAssertFalse(MobNameConvention.isNamed("a clockwork merchant", level: "?", dropsRareLoot: true))
        XCTAssertFalse(MobNameConvention.isNamed("a cracked skeleton", level: nil, dropsRareLoot: true))
    }

    func testTheClassifierIsTheSameOneThePackGeneratorUses() {
        // One verdict, two consumers - the pane groups and MapAnnotations.Filter never disagree.
        XCTAssertFalse(MapAnnotations.Filter(named: true, common: false).keeps(named: false))
        XCTAssertTrue(MapAnnotations.Filter(named: true, common: false).keeps(named: true))
        XCTAssertTrue(MapAnnotations.Filter(named: true, common: true).keeps(named: false))
    }
}
