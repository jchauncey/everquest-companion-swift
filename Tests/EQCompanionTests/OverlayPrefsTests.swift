import XCTest
@testable import EQCompanion

/// The two rules behind the Appearance page's steppers and the overlays' look — the parts that can
/// be checked without a window on screen.
final class OverlayPrefsTests: XCTestCase {

    // MARK: - The transparency grid

    func testTransparencyStepsOntoTheGridFromOffIt() {
        // The shipped 72% is not on the 5% grid: a press SNAPS rather than adding five.
        XCTAssertEqual(OverlayAlphaRange.stepped(72, up: true), 75)
        XCTAssertEqual(OverlayAlphaRange.stepped(72, up: false), 70)
    }

    func testTransparencyStepsWholeCellsWhenAlreadyOnTheGrid() {
        XCTAssertEqual(OverlayAlphaRange.stepped(75, up: true), 80)
        XCTAssertEqual(OverlayAlphaRange.stepped(75, up: false), 70)
    }

    func testTransparencyClampsAtBothEnds() {
        XCTAssertEqual(OverlayAlphaRange.stepped(10, up: false), 10)
        XCTAssertEqual(OverlayAlphaRange.stepped(100, up: true), 100)
    }

    // MARK: - Shared or per overlay

    func testSharedValuesGovernEveryOverlayWhileIndependentIsOff() {
        let prefs = Prefs.shared
        let restore = (prefs.overlayIndependent, prefs.overlayTextScale, prefs.overlayTransparency,
                       prefs.overlayTextScales, prefs.overlaySolidBackground)
        defer {
            (prefs.overlayIndependent, prefs.overlayTextScale, prefs.overlayTransparency,
             prefs.overlayTextScales, prefs.overlaySolidBackground) = restore
        }

        prefs.overlaySolidBackground = false
        prefs.overlayIndependent = false
        prefs.overlayTextScale = 120
        prefs.overlayTransparency = 50
        // The per-overlay value still EXISTS and is still remembered; it is simply not in force.
        prefs.overlayTextScales = [OverlayID.banner: 200]

        XCTAssertEqual(OverlayLook.textScale(OverlayID.banner), 1.2, accuracy: 0.0001)
        XCTAssertEqual(OverlayLook.backgroundAlpha(OverlayID.meter), 0.5, accuracy: 0.0001)

        prefs.overlayIndependent = true
        XCTAssertEqual(OverlayLook.textScale(OverlayID.banner), 2.0, accuracy: 0.0001)
        // An overlay with no value of its own falls back to the shared one it was last drawn at.
        XCTAssertEqual(OverlayLook.textScale(OverlayID.meter), 1.2, accuracy: 0.0001)
    }

    func testSolidBackgroundOutranksTheTransparency() {
        let prefs = Prefs.shared
        let restore = (prefs.overlaySolidBackground, prefs.overlayTransparency)
        defer { (prefs.overlaySolidBackground, prefs.overlayTransparency) = restore }

        prefs.overlayTransparency = 30
        prefs.overlaySolidBackground = true
        for id in OverlayID.all {
            XCTAssertEqual(OverlayLook.backgroundAlpha(id), 1)
        }
    }

    // MARK: - The list the Appearance card draws

    func testEveryOverlayHasALabelAndTheStripsComeLast() {
        XCTAssertEqual(OverlayID.all.count, 4)
        XCTAssertEqual(Array(OverlayID.all.suffix(3)), OverlayID.strips)
        for id in OverlayID.all { XCTAssertNotEqual(OverlayID.label(id), id) }
    }
}
