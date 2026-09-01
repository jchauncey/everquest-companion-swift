import XCTest
import SwiftUI
@testable import EQCompanion

/// The item name cell both item tables draw. Its job is to make an item look like itself on the
/// Gear tab and the Loot tab alike — same artwork, same name, same click.
final class ItemNameCellTests: XCTestCase {
    /// The loot table has no icon id: it counts what the LOG printed, not corpus rows. So the cell
    /// resolves artwork by name, and that lookup has to survive the spellings a log actually
    /// carries - notably the ` +N` variants the game drops broadly.
    @MainActor
    func testArtworkResolvesFromALogsSpellingOfAnItem() {
        let g = GameData.shared
        func icon(_ name: String) -> Int? { g.item(named: name)?.iconId }

        // A plain name the corpus carries.
        XCTAssertNotNil(icon("Bone Chips"), "a common quest drop should have artwork")
        // The counting boundary: the log writes `+1`, the wiki page does not.
        XCTAssertEqual(icon("Bone Chips +1"), icon("Bone Chips"),
                       "a +N variant is the same item and must show the same picture")
        // And the article seam, which the same lookup crosses.
        XCTAssertEqual(icon("Dark Reaver"), icon("A Dark Reaver"))
    }

    /// Every icon the cell can show must actually load — an id the manifest has no file for would
    /// silently draw nothing, which reads as "this item has no picture".
    @MainActor
    func testTheIconsTheLootTableWantsActuallyLoad() {
        let g = GameData.shared
        var asked = 0, drew = 0
        for item in g.allItems.prefix(400) {
            guard let id = item.iconId else { continue }
            asked += 1
            if g.itemIcon(id) != nil { drew += 1 }
        }
        XCTAssertGreaterThan(asked, 50, "the corpus should state plenty of icon ids")
        XCTAssertGreaterThan(Double(drew) / Double(asked), 0.5,
                             "only \(drew) of \(asked) stated icons have a file - the artwork is mostly missing")
    }

    /// A chip belongs BESIDE its name, not at the far edge of the column.
    ///
    /// The name once took `maxWidth: .infinity`, so a short item stretched across the whole column
    /// and left its `quest` chip stranded hundreds of points away from the word it qualifies.
    /// Measured as the chip's distance from the end of the name.
    @MainActor
    func testAChipSitsBesideItsNameRatherThanAtTheColumnsEdge() {
        final class Measured: @unchecked Sendable {
            var nameEnd: CGFloat = .nan
            var chipStart: CGFloat = .nan
        }

        struct Probe: View {
            let measured: Measured
            var body: some View {
                ItemNameCell(name: "Bone Chips", iconId: nil,
                             chips: [ItemChip(text: "quest", color: Theme.gold)])
                    // A column far wider than the content needs - where the gap used to open up.
                    .frame(width: 500, alignment: .leading)
                    .coordinateSpace(name: "cell")
                    .background(GeometryReader { _ in Color.clear })
            }
        }

        // The chip's own frame is read through the cell's coordinate space by hosting the pieces
        // the same way the cell stacks them.
        let measured = Measured()
        struct Pieces: View {
            let measured: Measured
            var body: some View {
                HStack(spacing: 6) {
                    Color.clear.frame(width: ItemNameCell.iconSize, height: ItemNameCell.iconSize)
                    Text("Bone Chips").lineLimit(1)
                        .background(GeometryReader { g in
                            Color.clear.onAppear { measured.nameEnd = g.frame(in: .named("cell")).maxX }
                        })
                    Chip(text: "quest", color: Theme.gold)
                        .background(GeometryReader { g in
                            Color.clear.onAppear { measured.chipStart = g.frame(in: .named("cell")).minX }
                        })
                    Spacer(minLength: 0)
                }
                .frame(width: 500, alignment: .leading)
                .coordinateSpace(name: "cell")
            }
        }

        let host = NSHostingView(rootView: Pieces(measured: measured))
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertFalse(measured.nameEnd.isNaN, "the probe never laid out")
        XCTAssertLessThan(measured.chipStart - measured.nameEnd, 20,
                          "the chip starts \(measured.chipStart - measured.nameEnd)pt after the name ends - it has been pushed to the column's edge")
        XCTAssertLessThan(measured.chipStart, 250, "name and chip must pack left, not spread across 500pt")
    }

    /// The cell renders at a sane width whether or not it has a picture, so a column of items with
    /// mixed artwork keeps one left edge.
    @MainActor
    func testTheCellIsTheSameShapeWithAndWithoutArtwork() {
        let withArt = NSHostingView(rootView: ItemNameCell(name: "Bone Chips", iconId: nil))
        let without = NSHostingView(rootView: ItemNameCell(name: "No Such Item At All", iconId: nil))
        XCTAssertEqual(withArt.fittingSize.height, without.fittingSize.height, accuracy: 1,
                       "a missing icon must not change the row's height")
        XCTAssertGreaterThanOrEqual(without.fittingSize.width, ItemNameCell.iconSize,
                                    "the blank keeps the name off the cell's left edge")
    }
}
