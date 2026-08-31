import XCTest
import SwiftUI
import AppKit
@testable import EQCompanion

final class GearColumnsTests: XCTestCase {
    @MainActor
    private func store() -> (GearColumnWidths, UserDefaults) {
        let d = UserDefaults(suiteName: "gear-columns-\(UUID().uuidString)")!
        return (GearColumnWidths(d), d)
    }

    @MainActor
    func testAnUntouchedColumnKeepsItsDefault() {
        let (w, _) = store()
        let c = GearColumn(key: "zone", label: "Zone", kind: .text, defaultWidth: 150)
        XCTAssertEqual(w.width(c), 150)
    }

    @MainActor
    func testADraggedWidthPersistsAndIsClamped() {
        let (w, d) = store()
        let c = GearColumn(key: "name", label: "Item", kind: .name, defaultWidth: 300)
        w.set(c, 420, d)
        XCTAssertEqual(w.width(c), 420)
        // A drag past either end is held at the end rather than losing the column.
        w.set(c, 5, d)
        XCTAssertEqual(w.width(c), GearColumn.minWidth)
        w.set(c, 5000, d)
        XCTAssertEqual(w.width(c), GearColumn.maxWidth)

        // It survives a relaunch, and only the dragged column is stored.
        w.set(c, 260, d)
        let reloaded = GearColumnWidths(d)
        XCTAssertEqual(reloaded.width(c), 260)
        XCTAssertEqual(reloaded.width(GearColumn(key: "zone", label: "Zone", kind: .text, defaultWidth: 150)), 150,
                       "a column never dragged still follows the shipped default")

        reloaded.reset(d)
        XCTAssertEqual(GearColumnWidths(d).width(c), 300)
    }

    func testWeaponColumnsFollowTheSlotFilter() {
        func cols(slots: Set<String> = [], weapons: Set<String> = [], sort: String = "AC") -> [String] {
            GearColumnSet.numeric(slots: slots, weapons: weapons, sortKey: sort)
        }
        // Every slot: the table holds weapons, so their columns are there.
        XCTAssertEqual(cols(), ["AC", "HP", "MP", "DMG", "DELAY", "RATIO"])
        // Armour only: damage, delay and ratio would be blank for every row.
        XCTAssertEqual(cols(slots: ["HEAD", "CHEST", "HANDS"]), ["AC", "HP", "MP"])
        // Any weapon slot brings them back, on its own or mixed with armour.
        for s in ["PRIMARY", "SECONDARY", "RANGE", "AMMO"] {
            XCTAssertTrue(cols(slots: [s]).contains("DMG"), "\(s) states damage")
            XCTAssertTrue(cols(slots: [s, "HEAD"]).contains("RATIO"))
        }
        // A weapon TYPE picked is a weapon filter even with no slot chosen.
        XCTAssertTrue(cols(weapons: ["1hs"]).contains("DELAY"))
        XCTAssertTrue(cols(slots: ["HEAD"], weapons: ["1hs"]).contains("DELAY"))
    }

    /// The bug this list shape was meant to make impossible, caught while adding the weapon rule:
    /// the "keep the sorted column visible" rule predates the text columns, and a text sort key
    /// falling into the NUMERIC list draws that column twice - once with its text, once as a
    /// nameless run of blank cells.
    func testATextSortKeyNeverBecomesANumericColumn() {
        for key in ["zone", "owned", "wish", "name", "slot", "classes"] {
            let cols = GearColumnSet.numeric(slots: ["HEAD"], weapons: [], sortKey: key)
            XCTAssertEqual(cols, ["AC", "HP", "MP"], "\(key) is a text column and must not be drawn as a stat")
        }
        // A real stat being sorted on IS added, even when the filter would not have shown it.
        XCTAssertEqual(GearColumnSet.numeric(slots: ["HEAD"], weapons: [], sortKey: "HASTE"),
                       ["AC", "HP", "MP", "HASTE"])
        // ...and is never duplicated when it is already there.
        XCTAssertEqual(GearColumnSet.numeric(slots: [], weapons: [], sortKey: "RATIO"),
                       ["AC", "HP", "MP", "DMG", "DELAY", "RATIO"])
    }

    /// The computed table width must equal the width a row actually draws.
    ///
    /// When it did not - it counted the per-column gutter but not the stack's own spacing - the
    /// frame handed to the scroll view was ~100pt narrower than its content, and the overflow went
    /// BOTH ways: the first characters of every item name and the last of every wish-list button
    /// were cut off. Arithmetic that only has to agree with a layout by convention will drift, so
    /// here the layout is measured and compared against the arithmetic.
    @MainActor
    func testTheComputedWidthIsTheWidthARowDraws() {
        final class Measured: @unchecked Sendable { var width: CGFloat = .nan }

        let cols = [
            GearColumn(key: "name", label: "Item", kind: .name, defaultWidth: 300),
            GearColumn(key: "slot", label: "Slot", kind: .text, defaultWidth: 92),
            GearColumn(key: "AC", label: "AC", kind: .stat, defaultWidth: 42, trailing: true),
            GearColumn(key: "zone", label: "Zone", kind: .text, defaultWidth: 150),
            GearColumn(key: "wish", label: "Wish list", kind: .wish, defaultWidth: 128),
        ]
        let expected = GearColumnSet.totalWidth(cols) { $0.defaultWidth }

        struct Probe: View {
            let cols: [GearColumn]
            let measured: Measured
            var body: some View {
                // The row's exact shape: spacing 0, each cell its width plus one trailing gutter.
                HStack(spacing: 0) {
                    ForEach(cols) { c in
                        Text(c.label)
                            .frame(width: c.defaultWidth, alignment: c.trailing ? .trailing : .leading)
                            .padding(.trailing, GearColumnSet.gutter)
                    }
                    Spacer(minLength: 0)
                }
                .fixedSize()
                .background(GeometryReader { g in
                    Color.clear.onAppear { measured.width = g.size.width }
                })
            }
        }

        let measured = Measured()
        let host = NSHostingView(rootView: Probe(cols: cols, measured: measured))
        host.frame = NSRect(x: 0, y: 0, width: 2000, height: 100)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(measured.width.isNaN, "the probe never laid out - the measurement is meaningless")
        XCTAssertEqual(measured.width, expected, accuracy: 1,
                       "a row draws \(measured.width)pt but the scroll frame is told \(expected)pt - the difference is cut off both ends")
    }

    /// Leftover width goes to the flexible column, and only when there IS leftover.
    func testTheTableFillsItsPaneButNeverStretchesPastIt() {
        let cols = [
            GearColumn(key: "name", label: "Item", kind: .name, defaultWidth: 300),
            GearColumn(key: "zone", label: "Zone", kind: .text, defaultWidth: 150, flexible: true),
        ]
        let need = GearColumnSet.totalWidth(cols) { $0.defaultWidth }   // 300 + 150 + 2 gutters
        XCTAssertEqual(need, 466)

        // A roomy pane: every spare point is the flexible column's, so the table reaches the edge.
        XCTAssertEqual(GearColumnSet.slack(cols, available: 900) { $0.defaultWidth }, 900 - need)
        // Exactly enough, and too little: no stretch, and no negative width - it scrolls instead.
        XCTAssertEqual(GearColumnSet.slack(cols, available: need) { $0.defaultWidth }, 0)
        XCTAssertEqual(GearColumnSet.slack(cols, available: 200) { $0.defaultWidth }, 0)
        // A pane that has not been measured yet must not produce a bogus width.
        XCTAssertEqual(GearColumnSet.slack(cols, available: 0) { $0.defaultWidth }, 0)
        XCTAssertEqual(GearColumnSet.slack(cols, available: .infinity) { $0.defaultWidth }, 0)
        XCTAssertEqual(GearColumnSet.slack(cols, available: .nan) { $0.defaultWidth }, 0)

        // Only the flexible column grows; everything else keeps the width it was given.
        let slack = GearColumnSet.slack(cols, available: 900) { $0.defaultWidth }
        func drawn(_ c: GearColumn) -> CGFloat { c.defaultWidth + (c.flexible ? slack : 0) }
        XCTAssertEqual(drawn(cols[0]), 300)
        XCTAssertEqual(drawn(cols[1]), 150 + slack)
        XCTAssertEqual(GearColumnSet.totalWidth(cols, width: drawn), 900, "the table ends at the pane's edge")
    }

    /// A table too wide for its pane must SCROLL, never spill.
    ///
    /// An HStack offered less width than it needs spreads the overflow both ways, so half of it
    /// lands to the LEFT of the pane - under the sidebar, where it ate the item names. Measured
    /// here as the laid-out origin of the content: negative means it is off the left edge.
    @MainActor
    func testAWideTableScrollsInsteadOfSpillingOverItsLeftEdge() {
        final class Measured: @unchecked Sendable { var minX: CGFloat = .nan }

        struct Probe: View {
            let measured: Measured
            var scrolls: Bool
            private var wide: some View {
                HStack(spacing: 8) {
                    ForEach(0..<8, id: \.self) { i in
                        Text("col\(i)").frame(width: 200, alignment: .leading)
                    }
                }
                .frame(width: 8 * 208, alignment: .leading)
                .background(GeometryReader { g in
                    Color.clear.onAppear { measured.minX = g.frame(in: .named("pane")).minX }
                })
            }
            var body: some View {
                Group {
                    if scrolls { ScrollView(.horizontal) { wide } } else { wide }
                }
                .frame(width: 600, height: 200)
                .coordinateSpace(name: "pane")
            }
        }

        func minX(scrolls: Bool) -> CGFloat {
            let measured = Measured()
            let host = NSHostingView(rootView: Probe(measured: measured, scrolls: scrolls))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 200)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            return measured.minX
        }

        // Unwrapped, 1,664pt of columns in a 600pt pane hang off BOTH sides - this is the bug.
        let bare = minX(scrolls: false)
        XCTAssertFalse(bare.isNaN, "the probe never laid out - the measurement is meaningless")
        XCTAssertLessThan(bare, -100, "an overflowing HStack should be centred, proving the hazard is real")

        // Wrapped, the content starts at the pane's own left edge and the rest is scrolled to.
        let scrolled = minX(scrolls: true)
        XCTAssertFalse(scrolled.isNaN)
        XCTAssertEqual(scrolled, 0, accuracy: 1,
                       "the table began \(scrolled)pt left of the pane - that is what covers the item names")
    }

    /// A row of controls must not report an IDEAL width wider than a window.
    ///
    /// This is the mechanism behind "items are cut off on the left" surviving three fixes to the
    /// table itself: the displacement was never in the table. `NavigationSplitView` sizes its
    /// detail column from the content's ideal width (see the note in `RootView`), and an unwrapped
    /// control row's ideal is its whole one-line length. A detail column laid out wider than the
    /// window spills over the sidebar, taking every column of the table with it.
    ///
    /// So the property under test is the one `FlowRow` exists for: asked "what is your ideal?", it
    /// answers with its widest single control - "I can be as narrow as that" - rather than the sum.
    @MainActor
    func testAWrappingControlRowIsNotIdeallyAsWideAsItsWholeLine() {
        let controls = (0..<5).map { "filter\($0)" }

        let bare = NSHostingView(rootView: HStack(spacing: 8) {
            ForEach(controls, id: \.self) { Text($0).frame(width: 200) }
        })
        let wrapped = NSHostingView(rootView: FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(controls, id: \.self) { Text($0).frame(width: 200) }
        })

        // The hazard, stated: an unwrapped row wants the whole line - 5 x 200 plus four gaps.
        XCTAssertEqual(bare.fittingSize.width, 1032, accuracy: 2,
                       "an HStack should ask for its whole line, proving the hazard is real")
        // The fix: no more than one control's worth, so no ancestor is sized past the window.
        XCTAssertEqual(wrapped.fittingSize.width, 200, accuracy: 2,
                       "FlowRow asked for \(wrapped.fittingSize.width)pt; anything near \(bare.fittingSize.width) makes the split view overflow the sidebar")

        // And it still lays every control out - wrapping, not dropping. Constrained to 500pt the
        // five controls need three rows, so it must be taller than the single line an HStack draws.
        let constrained = NSHostingView(rootView: FlowRow(spacing: 8, lineSpacing: 8) {
            ForEach(controls, id: \.self) { Text($0).frame(width: 200) }
        }.frame(width: 500))
        XCTAssertGreaterThan(constrained.fittingSize.height, bare.fittingSize.height,
                             "wrapping means more rows, never fewer controls")
    }

    /// A name cell must FIT its column, so its icon cannot slide off the left edge.
    ///
    /// The icon is first in the cell, and an HStack given less width than it wants centres its
    /// overflow - so a long name pushed the icon left, out of the cell, where the table's edge
    /// sliced it in half. The name is the part that must give way: measured here as the icon's
    /// origin, which may never be negative however long the name is.
    @MainActor
    func testALongItemNameNeverPushesTheIconOffTheCell() {
        final class Measured: @unchecked Sendable { var iconMinX: CGFloat = .nan }

        struct Probe: View {
            let measured: Measured
            var name: String
            var flexible: Bool
            var body: some View {
                HStack(spacing: 6) {
                    Color.gray.frame(width: 24, height: 24)
                        .background(GeometryReader { g in
                            Color.clear.onAppear { measured.iconMinX = g.frame(in: .named("cell")).minX }
                        })
                    Group {
                        if flexible {
                            Text(name).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(name).lineLimit(1)
                        }
                    }
                    Text("out of era").font(.caption)
                }
                .frame(width: 300, alignment: .leading)
                .coordinateSpace(name: "cell")
            }
        }

        func iconMinX(flexible: Bool) -> CGFloat {
            let measured = Measured()
            // Far longer than the 300pt column can hold.
            let name = "Lustrous Russet Breastplate of the Everlasting Ancient Froglok Kings"
            let host = NSHostingView(rootView: Probe(measured: measured, name: name, flexible: flexible))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            return measured.iconMinX
        }

        // Both shapes hold the icon in place - a `lineLimit(1)` Text compresses rather than
        // shoving its neighbours, which is worth recording: it rules the name cell out as the
        // cause of an icon clipped at the table's left edge.
        XCTAssertEqual(iconMinX(flexible: false), 0, accuracy: 1)

        let giving = iconMinX(flexible: true)
        XCTAssertFalse(giving.isNaN)
        XCTAssertEqual(giving, 0, accuracy: 1,
                       "the icon starts \(giving)pt outside its own cell - the name is not giving way")
    }

    /// THE LAYOUT REGRESSION, measured rather than looked at.
    ///
    /// The handle began life as `Rectangle().frame(width: 8)`. A Shape is flexible on both axes, so
    /// a width-only frame takes every point of height offered - and the table offers all of it. The
    /// header became a band hundreds of points tall with the column labels stranded at the bottom
    /// and the rows pushed off screen. Nothing in the source looks wrong; it is only wrong on
    /// screen, which nobody working on this codebase can see. So the size is asserted: hosted in a
    /// tall container, the handle must still be a handle.
    @MainActor
    func testTheResizeHandleDoesNotSwallowTheHeightItIsOffered() {
        let handle = GearColumnResizeHandle(current: 300, set: { _ in }, reset: {})
        let host = NSHostingView(rootView: handle)

        XCTAssertEqual(host.fittingSize.height, GearColumnResizeHandle.hitHeight, accuracy: 1,
                       "the handle's ideal height must be its own, not the container's")
        XCTAssertEqual(host.fittingSize.width, GearColumnResizeHandle.hitWidth, accuracy: 1)
    }

    /// The same invariant where it actually bit: a header row stacked above the scrolling body,
    /// inside a tall container.
    ///
    /// This is measured from the LAID-OUT geometry, not from `fittingSize`. A greedy child does not
    /// change a view's ideal size - it changes how a VStack divides real height between the header
    /// and the rows below it, which is why the bug survived an ideal-size check and had to be seen
    /// on screen. Here the header reports its own height and the test reads it.
    @MainActor
    func testAHeaderRowDoesNotTakeHeightFromTheRowsBelowIt() {
        final class Measured: @unchecked Sendable { var height: CGFloat = 0 }
        let measured = Measured()

        struct Probe: View {
            let measured: Measured
            var body: some View {
                // The table's own shape: header, divider, then the body that should get the rest.
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(["Item", "Slot", "Zone"], id: \.self) { label in
                            HStack(spacing: 0) {
                                Text(label).font(.system(size: 12, weight: .semibold))
                                    .frame(width: 100, alignment: .leading)
                                GearColumnResizeHandle(current: 100, set: { _ in }, reset: {})
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .background(GeometryReader { g in
                        Color.clear.onAppear { measured.height = g.size.height }
                    })
                    Divider()
                    ScrollView { Text("rows").frame(maxWidth: .infinity) }
                }
                .frame(width: 900, height: 800)
            }
        }

        let host = NSHostingView(rootView: Probe(measured: measured))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertGreaterThan(measured.height, 0, "the probe never laid out - the measurement is meaningless")
        XCTAssertLessThan(measured.height, 40,
                          "the header took \(measured.height)pt of the 800pt container - something in it is vertically greedy, and every point it takes is a row the player cannot see")
    }
}
