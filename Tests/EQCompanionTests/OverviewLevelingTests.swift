import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The Overview leveling card against the owner's real progression snapshot, checked against the
/// numbers the Electron app drew for the same log (its screenshot of 2026-08-28 11:42).
final class OverviewLevelingTests: XCTestCase {
    private func snap() throws -> OverviewProgression {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "progression", withExtension: "json", subdirectory: "Fixtures"))
        return OverviewProgression(try JSONValue.parse(try Data(contentsOf: url)))
    }

    @MainActor
    func testHeadlineTilesMatchTheElectronCard() throws {
        let s = try snap()
        let st = overviewLeveling(s, statedLevel: nil)
        XCTAssertFalse(st.empty)
        XCTAssertEqual(st.level, 41)
        let byId = Dictionary(uniqueKeysWithValues: st.tiles.map { ($0.id, $0) })
        XCTAssertEqual(byId["rate"]?.value, "0.46", "\(st.tiles)")
        XCTAssertEqual(byId["rate"]?.unit, "lvl/hr")
        XCTAssertEqual(byId["aa"]?.value, "2")
        XCTAssertEqual(byId["eta"]?.label, "to level 42")
        XCTAssertTrue(byId["eta"]?.value.hasPrefix("~2h") == true, byId["eta"]?.value ?? "nil")
    }

    @MainActor
    func testSupportingLinesMatch() throws {
        let st = overviewLeveling(try snap(), statedLevel: nil)
        XCTAssertEqual(st.killRate, "66.5 kills/hr")
        XCTAssertEqual(st.activity, "25m active · 34m idle")
        XCTAssertEqual(st.aaLine?.hasPrefix("1.00 AA/hr · 2.00 pts/hr"), true, st.aaLine ?? "nil")
        XCTAssertEqual(st.history, "lvl 36→37 51m · 37→38 1.5h · 38→39 2.9h · 39→40 1.8h · 40→41 1.7h")
        XCTAssertEqual(st.zoneLine?.hasPrefix("in Innothule Swamp: - · - since"), true, st.zoneLine ?? "nil")
        XCTAssertEqual(st.spark.count, 12)
    }
}
