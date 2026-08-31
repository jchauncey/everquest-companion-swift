import XCTest
@testable import EQCompanion

final class MobFilterTests: XCTestCase {
    func testLevelRange() {
        XCTAssertEqual(MobsView.levelRange("45"), 45...45)
        XCTAssertEqual(MobsView.levelRange("1-2 or 1-5"), 1...5)
        XCTAssertEqual(MobsView.levelRange("4-6, ~12"), 4...12)
        XCTAssertNil(MobsView.levelRange(""))
        XCTAssertNil(MobsView.levelRange("unknown"))
    }
}
