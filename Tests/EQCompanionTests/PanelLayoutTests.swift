import XCTest
@testable import EQCompanion

/// The draggable board's rules: what a saved string means, how a stale one is repaired, and where a
/// drop puts a panel.
final class PanelLayoutTests: XCTestCase {
    private let defaults = PanelLayout(columns: [["pace", "progress"], ["spells", "ledger"]])

    func testTheSavedStringRoundTrips() {
        let l = PanelLayout(columns: [["spells", "pace"], ["ledger", "progress"]])
        XCTAssertEqual(PanelLayout.decode(l.encoded), l)
        XCTAssertEqual(PanelLayout.decode("a|"), PanelLayout(columns: [["a"], []]), "an emptied column survives")
    }

    func testNothingSavedIsTheDefault() {
        XCTAssertEqual(PanelLayout.normalized(.decode(""), defaults: defaults), defaults)
    }

    func testAStaleLayoutDropsTheUnknownAndPlacesTheMissing() {
        // Saved by a build that had a "retired" panel and not yet "ledger", with a duplicate.
        let saved = PanelLayout.decode("spells,retired,pace|progress,spells")
        let fixed = PanelLayout.normalized(saved, defaults: defaults)
        XCTAssertEqual(fixed.columns, [["spells", "pace"], ["progress", "ledger"]])
    }

    func testAThirdSavedColumnIsFoldedAway() {
        let fixed = PanelLayout.normalized(.decode("pace|spells|ledger,progress"), defaults: defaults)
        XCTAssertEqual(fixed.columns.count, 2)
        XCTAssertEqual(Set(fixed.columns.flatMap { $0 }), ["pace", "progress", "spells", "ledger"])
    }

    func testDroppingOnAPanelPutsTheDraggedOneAboveIt() {
        var l = defaults
        l.move("ledger", before: "pace")
        XCTAssertEqual(l.columns, [["ledger", "pace", "progress"], ["spells"]])
        l.move("progress", before: "ledger")
        XCTAssertEqual(l.columns, [["progress", "ledger", "pace"], ["spells"]], "within a column too")
        let before = l
        l.move("pace", before: "pace")
        l.move("nope", before: "pace")
        XCTAssertEqual(l, before, "onto itself or an unknown id changes nothing")
    }

    func testDroppingUnderAColumnPutsItAtTheBottom() {
        var l = defaults
        l.move("spells", toEndOf: 0)
        XCTAssertEqual(l.columns, [["pace", "progress", "spells"], ["ledger"]])
        l.move("ledger", toEndOf: 0)
        XCTAssertEqual(l.columns, [["pace", "progress", "spells", "ledger"], []], "a column can be emptied")
        l.move("pace", toEndOf: 1)
        XCTAssertEqual(l.columns, [["progress", "spells", "ledger"], ["pace"]])
    }
}
