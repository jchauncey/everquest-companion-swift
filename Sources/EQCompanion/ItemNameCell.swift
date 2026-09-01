// How an item is named on screen — icon, name, and the chips that qualify it.
//
// The Gear tab and the Loot tab are both ITEM TABLES, and an item should look like itself on
// whichever one you are reading: same artwork, same size, same green, same truncation, and the same
// click opening the same card. They had drifted — Gear drew the icon and Loot did not — which read
// as two different kinds of thing rather than two views of one.
//
// THE NAME IS THE PART THAT GIVES WAY. The icon and the chips are fixed size; the name takes
// whatever is left and truncates. Without that the cell's content can exceed its column, and an
// over-wide HStack is CENTRED rather than clipped — which slides the icon off the left of its own
// cell and slices it against the edge of the table. (That is a real bug this app shipped once; see
// `DataTable`.)
import SwiftUI

/// One qualifier beside an item's name: `quest`, `LORE`, `+1`, `out of era`.
struct ItemChip: Identifiable, Equatable {
    var text: String
    var color: Color
    var id: String { text }
}

struct ItemNameCell: View {
    var name: String
    /// The corpus's icon id when the caller already holds it. When nil the icon is looked up by
    /// NAME, which is what the loot table has — it counts what the log printed, not corpus rows.
    var iconId: Int?
    var chips: [ItemChip] = []
    /// Dimmed for a row that is present but not really loot (an inventory-only entry).
    var dimmed = false
    var onOpen: (() -> Void)?

    /// The green every item name in this app is written in.
    static let nameColor = Color(hex: 0x6fbf7f)
    static let iconSize: CGFloat = 24

    private var icon: NSImage? {
        if let iconId, let img = GameData.shared.itemIcon(iconId) { return img }
        // The article seam applies here too: a log line's spelling and the page's may differ.
        return GameData.shared.item(named: name)?.iconId.flatMap { GameData.shared.itemIcon($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon).resizable()
                    .frame(width: Self.iconSize, height: Self.iconSize)
            } else {
                // A fixed blank keeps every name on the same left edge whether or not the corpus
                // has artwork — a ragged first column is harder to scan than a missing picture.
                Color.clear.frame(width: Self.iconSize, height: Self.iconSize)
            }
            Group {
                if let onOpen {
                    Button(action: onOpen) { label }.buttonStyle(.plain)
                } else {
                    label
                }
            }
            ForEach(chips) { c in Chip(text: c.text, color: c.color) }
            // THE SLACK GOES HERE, at the end — not into the name.
            //
            // The name used to take `maxWidth: .infinity`, which reads as "fill the column": a
            // three-word item then stretched to the full width and pushed its chips against the far
            // edge, stranding them a column's width from the thing they qualify. A chip belongs
            // beside its name. The Spacer absorbs the leftover instead, so name and chips stay
            // packed left, and the name still gives way first when the column is too narrow —
            // a `lineLimit(1)` Text compresses where a fixed-size chip cannot.
            Spacer(minLength: 0)
        }
        .help(name)
    }

    private var label: some View {
        Text(name)
            .foregroundStyle(dimmed ? Theme.textDim : Self.nameColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
