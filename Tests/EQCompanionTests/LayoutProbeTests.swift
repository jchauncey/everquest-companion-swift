import XCTest
import SwiftUI
import AppKit
@testable import EQCompanion

/// Hosts a tab the way the window does and reports the size it CLAIMS. A tab that answers with
/// an unbounded or absurd size is the one that wrecks the split view.
final class LayoutProbeTests: XCTestCase {
    @MainActor
    @discardableResult
    private func probe<V: View>(_ name: String, _ v: V) -> CGSize {
        let host = NSHostingView(rootView: AnyView(v.environment(AppModel.shared)))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let intrinsic = host.intrinsicContentSize
        print("PROBE \(name): fitting=\(fit) intrinsic=\(intrinsic)")
        return fit
    }

    @MainActor
    func testTabs() {
        probe("Overview", OverviewView())
        probe("Maps", MapsView())
        probe("Combat", CombatView())
        probe("Mobs", MobsView())
        probe("Root", RootView())
        // The detail column pins its ideal size (RootView); a tab hosted that way must answer
        // with the pin, never with its own unwrapped header width.
        let pinned = probe("Maps@detail", MapsView().frame(minWidth: 480, idealWidth: 800, maxWidth: .infinity, minHeight: 360, idealHeight: 600, maxHeight: .infinity))
        XCTAssertEqual(pinned.width, 800)
        XCTAssertEqual(pinned.height, 600)
    }
}
