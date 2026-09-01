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

/// A gear column is a `DataColumn` plus what KIND of cell fills it — the table draws the layout,
/// the Gear tab draws the contents.
struct GearColumn: Identifiable, Equatable {
    var column: DataColumn
    var kind: GearColumnKind
    var id: String { column.key }

    init(key: String, label: String, kind: GearColumnKind, defaultWidth: CGFloat,
         trailing: Bool = false, flexible: Bool = false) {
        self.column = DataColumn(key: key, label: label, width: defaultWidth,
                                 trailing: trailing, flexible: flexible)
        self.kind = kind
    }

    var key: String { column.key }
    var label: String { column.label }
    var defaultWidth: CGFloat { column.width }
    var trailing: Bool { column.trailing }
    var flexible: Bool { column.flexible }
}

/// Which numeric columns a given filter earns.
///
/// A column that no row in the current table can fill is worse than absent: it costs width, it
/// offers a sort that orders nothing, and it makes the columns that DO matter harder to compare. So
/// the weapon columns come and go with the filter rather than standing there empty.
enum GearColumnSet {
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
