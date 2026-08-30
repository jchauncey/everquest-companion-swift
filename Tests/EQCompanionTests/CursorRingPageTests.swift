import XCTest
import SwiftUI
@testable import EQCompanion

/// The two pure decisions the cursor ring card makes: the clamps the upstream normalizer applies
/// (`shared/presencePrefs.ts`), and the hex round-trip the colour picker is stored through.
final class CursorRingPageTests: XCTestCase {
    func testSizeClampsToTheUpstreamBounds() {
        XCTAssertEqual(CursorRingLimits.clampSize(0), 20)
        XCTAssertEqual(CursorRingLimits.clampSize(44), 44)
        XCTAssertEqual(CursorRingLimits.clampSize(9999), 200)
    }

    func testThicknessNeverExceedsHalfTheDiameter() {
        XCTAssertEqual(CursorRingLimits.clampThickness(4, size: 44), 4)
        XCTAssertEqual(CursorRingLimits.clampThickness(99, size: 44), 12)
        // The upstream rule: a stroke wider than the radius would fill the ring's own hole.
        XCTAssertEqual(CursorRingLimits.clampThickness(12, size: 20), 10)
        XCTAssertEqual(CursorRingLimits.clampThickness(0, size: 20), 1)
    }

    @MainActor
    func testColorRoundTripsThroughTheStoredHex() {
        for hex in ["#FFFFFF", "#000000", "#D9B25F", "#3366CC"] {
            let color = try? XCTUnwrap(Color(hexString: hex))
            XCTAssertEqual(hexString(of: color!), hex, "round trip of \(hex)")
        }
    }

    @MainActor
    func testMalformedHexKeepsTheDefaultRing() {
        XCTAssertNil(Color(hexString: "not a colour"))
        XCTAssertNil(Color(hexString: "#FFF"))
    }

    /// The ring is a HOLE with a stroke around it: the middle must stay untouched, or the feature
    /// would be a disc over the pointer it is meant to reveal.
    @MainActor
    func testTheRingIsDrawnHollowWithTheChosenColourAtTheRadius() throws {
        let side = CGFloat(60) + CursorRingView.margin * 2
        let view = CursorRingView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        view.apply(size: 60, thickness: 6, color: NSColor(red: 1, green: 0, blue: 0, alpha: 1))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let mid = Int(side / 2)

        let centre = try XCTUnwrap(rep.colorAt(x: mid, y: mid))
        XCTAssertEqual(centre.alphaComponent, 0, accuracy: 0.05, "the pointer must show through")

        // Outer radius 30, a 6px stroke — its middle is 27px out from the centre.
        let stroke = try XCTUnwrap(rep.colorAt(x: mid + 27, y: mid))
        XCTAssertGreaterThan(stroke.alphaComponent, 0.5)
        XCTAssertGreaterThan(stroke.redComponent, 0.5, "the chosen colour, not a grey")
        XCTAssertLessThan(stroke.greenComponent, 0.5)
    }
}
