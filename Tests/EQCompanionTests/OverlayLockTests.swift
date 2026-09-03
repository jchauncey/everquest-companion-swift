import XCTest
@testable import EQCompanion

/// The lock's one rule: click-through serves the GAME, so it holds only while something else is
/// front. When EQ Companion is the active app a locked overlay takes clicks again — without this,
/// the lock button that locked the meter could never unlock it (the original bug: lock once,
/// locked forever unless you knew the menu shortcut).
final class OverlayLockTests: XCTestCase {
    @MainActor
    func testClickThroughOnlyWhileLockedAndTheAppIsInBackground() {
        XCTAssertTrue(OverlayPanel.clickThrough(movable: false, appActive: false),
                      "locked + game in front: clicks pass through")
        XCTAssertFalse(OverlayPanel.clickThrough(movable: false, appActive: true),
                       "locked + EQ Companion active: the lock button must be clickable")
        XCTAssertFalse(OverlayPanel.clickThrough(movable: true, appActive: false),
                       "unlocked is never click-through")
        XCTAssertFalse(OverlayPanel.clickThrough(movable: true, appActive: true))
    }
}
