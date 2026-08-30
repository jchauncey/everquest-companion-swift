import XCTest
@testable import EQCompanion

/// Preferences → Game: the one sentence in the folder card whose words move.
final class GamePageTests: XCTestCase {

    func testTheCountSentenceAgreesWithItsOwnNumber() {
        XCTAssertEqual(GamePage.foundText(1), "Found 1 character log in this folder.")
        XCTAssertEqual(GamePage.foundText(2), "Found 2 character logs in this folder.")
        XCTAssertEqual(GamePage.foundText(11), "Found 11 character logs in this folder.")
    }
}
