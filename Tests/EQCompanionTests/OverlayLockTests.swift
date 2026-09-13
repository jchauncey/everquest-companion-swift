import XCTest
import AppKit
@testable import EQCompanion

/// The lock's one rule: click-through serves the GAME, so it holds only while something else is
/// front. When EQ Companion is the active app a locked overlay takes clicks again — without this,
/// the lock button that locked the meter could never unlock it (the original bug: lock once,
/// locked forever unless you knew the menu shortcut).
final class OverlayLockTests: XCTestCase {
    /// A full-screen game under Wine sits at main-menu+1; the overlay must float above THAT while
    /// the game is in front, and fall back below menus and dialogs the moment it is not.
    @MainActor
    func testFloatsAboveAFullScreenGameOnlyWhileTheGameIsInFront() {
        let over = OverlayPanel.level(gameInFront: true)
        XCTAssertGreaterThan(over.rawValue, NSWindow.Level.mainMenu.rawValue + 1, "below Wine's full-screen window")
        XCTAssertLessThan(over.rawValue, NSWindow.Level.screenSaver.rawValue, "would cover system alerts")
        XCTAssertEqual(OverlayPanel.level(gameInFront: false), .floating)
    }

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
