import XCTest
import EQCompanionCore
@testable import EQCompanion

/// The corrections overlay is the one place the app is allowed to disagree with the wiki about a
/// mob's position, so both halves of the bargain are checked: the fix reaches the pins, and the
/// guard retires it the moment the corpus states something else.
final class MobLocFixesTests: XCTestCase {
    private func fix(was: JSONValue, loc: [JSONValue]) -> MobLocFixes.Fix {
        let file = JSONValue.object(["fixes": .array([.object(["page": .string("P"), "was": was, "loc": .array(loc)])])])
        return MobLocFixes.parse(file)["P"]!
    }

    func testGuardHoldsOnlyWhileTheCorpusStatesTheWrongValue() {
        let f = fix(was: .object(["ns": .int(550), "ew": .int(-220)]),
                    loc: [.object(["ns": .int(550), "ew": .int(-720)])])
        XCTAssertTrue(MobLocFixes.guardHolds(f, corpus: [.object(["ns": .double(550), "ew": .double(-220)])]),
                      "int corpus and double fix state the same position")
        // The wiki fixed it, or restated it: the correction is dead, and fresh data wins.
        XCTAssertFalse(MobLocFixes.guardHolds(f, corpus: [.object(["ns": .int(550), "ew": .int(-720)])]))
        XCTAssertFalse(MobLocFixes.guardHolds(f, corpus: []))
        // An unguarded fix always applies.
        let free = fix(was: .null, loc: [.object(["ns": .int(1), "ew": .int(2)])])
        XCTAssertTrue(MobLocFixes.guardHolds(free, corpus: []))
    }

    /// The shipped fix must reach `GameData.mobs` - a fix whose guard has gone stale silently
    /// stops correcting anything, which is exactly the failure this asserts against.
    @MainActor
    func testShippedSageFixIsLiveAndLandsInTheScribeAndSageRoom() throws {
        guard let sage = GameData.shared.mobs.first(where: { $0.page == "A ghoul sage" }) else {
            return XCTFail("the corpus has no A ghoul sage page")
        }
        XCTAssertNotNil(sage.locFix, "the fix's guard no longer holds - the corpus moved")
        XCTAssertEqual(sage.loc.first?["ew"].double, -720)
        XCTAssertEqual(sage.loc.first?["ns"].double, 550)
        XCTAssertEqual(sage.loc.first?["pct"].double, 34, "the page's own percentage is kept")

        // The point of the fix: the sage pins beside the scribe, in the room both share.
        guard let scribe = GameData.shared.mobs.first(where: { $0.page == "A ghoul scribe" }),
              let sagePin = MapPaneRows.pins(sage).first,
              let scribePin = MapPaneRows.pins(scribe).first else { return XCTFail("no pins") }
        XCTAssertEqual(sagePin.x, scribePin.x, accuracy: 30)
        XCTAssertEqual(sagePin.y, scribePin.y, accuracy: 30)

        // And the pane says whose position it is.
        let row = MapPaneRows.rows(from: [sage]).first
        XCTAssertEqual(row?.note, "position corrected")
    }
}
