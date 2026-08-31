// The gear table's columns: what they are, how wide, and how they sort.
//
// The table used to hard-code its layout in two places - a `header` HStack and a `row` HStack, each
// repeating the same widths - so a column could only be added by editing both and keeping the
// numbers in sync by hand. They are one list now, walked twice, because a header that disagrees
// with its rows is the bug this shape makes impossible.
//
// WIDTHS ARE THE PLAYER'S. Every column carries a default that fits its content (the item names in
// the corpus, the widest class list), and a drag on the header edge overrides it for good. What is
// stored is only what was actually dragged, so a default that improves later improves for everyone
// who never touched that column.
import SwiftUI

/// How a column's cell is filled and sorted.
enum GearColumnKind: Equatable {
    /// The item's name, icon, and era chip.
    case name
    /// A stat from the scaled vector, right-aligned and monospaced.
    case stat
    /// Text off the row.
    case text
    /// The wish-list toggle.
    case wish
}

struct GearColumn: Identifiable, Equatable {
    /// Also the sort key.
    var key: String
    var label: String
    var kind: GearColumnKind
    var defaultWidth: CGFloat
    var trailing = false
    /// Takes any width the window has left over, so the table fills its pane instead of stopping
    /// short with a band of dead space after the last column. Exactly one column should carry this.
    var flexible = false
    var id: String { key }

    static let minWidth: CGFloat = 44
    static let maxWidth: CGFloat = 600
}

/// Which numeric columns a given filter earns.
///
/// A column that no row in the current table can fill is worse than absent: it costs width, it
/// offers a sort that orders nothing, and it makes the columns that DO matter harder to compare. So
/// the weapon columns come and go with the filter rather than standing there empty.
enum GearColumnSet {
    /// The gap after every column, and the table's ONLY horizontal gap: the header and row stacks
    /// both use `spacing: 0`, so this appears exactly once per column in both the drawn row and in
    /// `totalWidth`. It is also the resize handle's hit width, which is what fills it in the header.
    static let gutter: CGFloat = 8

    /// The width a row of these columns occupies.
    ///
    /// This has to equal what is actually drawn, and once did not: it counted the gutter but not
    /// the stacks' own spacing, so the frame the scroll view was given was ~100pt narrower than
    /// its content. A too-narrow frame does not clip on the right - it overflows BOTH ways, which
    /// cut the first characters off every item name and the last off every wish-list button.
    /// `GearColumnsTests` now measures a real row against this number.
    static func totalWidth(_ cols: [GearColumn], width: (GearColumn) -> CGFloat) -> CGFloat {
        cols.reduce(0) { $0 + width($1) + gutter }
    }

    /// Width left over once the columns have taken theirs, for the flexible column to absorb.
    /// Zero when the columns already need more than the pane has - then the table scrolls instead.
    static func slack(_ cols: [GearColumn], available: CGFloat, width: (GearColumn) -> CGFloat) -> CGFloat {
        guard available.isFinite, available > 0 else { return 0 }
        return max(0, available - totalWidth(cols, width: width))
    }

    /// Whether the filter admits an item that could state a damage.
    ///
    /// A weapon TYPE picked says yes outright. NO slot picked also says yes - the table then holds
    /// every weapon in the corpus, and hiding the columns would hide most of what is on screen.
    /// Only an explicit armour-only slot selection says no.
    static func showsWeaponColumns(slots: Set<String>, weapons: Set<String>) -> Bool {
        if !weapons.isEmpty { return true }
        if slots.isEmpty { return true }
        return !slots.isDisjoint(with: weaponEquipSlots)
    }

    /// The numeric columns, in draw order.
    static func numeric(slots: Set<String>, weapons: Set<String>, sortKey: String) -> [String] {
        var cols = ["AC", "HP", "MP"]
        if showsWeaponColumns(slots: slots, weapons: weapons) { cols += gearWeaponColumnKeys }
        // Whatever is being sorted on stays visible - but ONLY when it names a stat. A text column
        // ("zone", "owned", "wish") reaching this list would be drawn a second time, as a numeric
        // column of empty cells beside the real one.
        if gearNumericColumnKeys.contains(sortKey) && !cols.contains(sortKey) { cols.append(sortKey) }
        return cols
    }
}

/// Column widths the player has dragged, by column key. Only overrides are stored.
@MainActor
@Observable
final class GearColumnWidths {
    static let shared = GearColumnWidths()
    private static let key = "eq.gear.columnWidths"

    private var overrides: [String: CGFloat]

    init(_ d: UserDefaults = .standard) {
        let raw = d.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        overrides = raw.mapValues { CGFloat($0) }
    }

    func width(_ c: GearColumn) -> CGFloat { overrides[c.key] ?? c.defaultWidth }

    func set(_ c: GearColumn, _ w: CGFloat, _ d: UserDefaults = .standard) {
        overrides[c.key] = min(max(w, GearColumn.minWidth), GearColumn.maxWidth)
        d.set(overrides.mapValues { Double($0) }, forKey: Self.key)
    }

    /// Back to the shipped defaults - the escape hatch for a column dragged to nothing.
    func reset(_ d: UserDefaults = .standard) {
        overrides = [:]
        d.removeObject(forKey: Self.key)
    }
}

/// The draggable edge between two column headers.
///
/// ITS HEIGHT IS EXPLICIT, and that is the whole reason this is a named view rather than three
/// lines inline. A `Rectangle` is flexible on BOTH axes, so the width-only frame it first had left
/// it hungry for every point of height the table offered it - which silently turned the header into
/// a band of empty space hundreds of points tall with the column labels stranded at the bottom of
/// it. Nothing about that is visible in the source; it is visible only on screen, which is the
/// worst place for this codebase to find a bug. `GearColumnsTests` measures it instead.
struct GearColumnResizeHandle: View {
    /// The column's width now, read at the moment a drag begins.
    var current: CGFloat
    var set: (CGFloat) -> Void
    var reset: () -> Void

    /// Wide enough to grab, short enough that the header row stays a row. The width IS the column
    /// gutter - the handle is what occupies the gap in the header.
    static let hitWidth: CGFloat = GearColumnSet.gutter
    static let hitHeight: CGFloat = 16

    /// The width this column had when the current drag began, so it tracks the pointer instead of
    /// accelerating away from it.
    @State private var base: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: Self.hitWidth, height: Self.hitHeight)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let start = base ?? current
                        if base == nil { base = start }
                        set(start + v.translation.width)
                    }
                    .onEnded { _ in base = nil }
            )
            .onTapGesture(count: 2) { reset() }
            .help("Drag to resize. Double-click to reset every column.")
    }
}
