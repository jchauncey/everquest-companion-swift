// THE table. Every column-and-rows surface in the app draws through this.
//
// It began as the Gear tab's own table, and everything hard about it was learned there the
// expensive way — three separate layout bugs that were invisible in the source and only wrong on
// screen, in a codebase where nobody can see the screen. Those lessons are comments here rather
// than in one tab's file, because the second table to want them should not have to rediscover them:
//
//   * A HEADER CELL MUST NOT BE VERTICALLY GREEDY. The resize handle was a `Rectangle` with only a
//     width set; a Shape is flexible on both axes, so it took every point of height the table
//     offered and left the column labels stranded in a band hundreds of points tall.
//   * THE COMPUTED WIDTH MUST BE THE DRAWN WIDTH. The gutter is counted once per column, here and
//     in the rows, and the stacks use `spacing: 0` so there is no second gap to forget. A frame
//     narrower than its content does not clip - it overflows BOTH ways, cutting the first
//     characters off the leftmost column.
//   * THE FLEXIBLE COLUMN ASKS, IT IS NOT TOLD. Handing it "pane minus the fixed columns" makes a
//     row exactly as wide as the space it was offered, with no give — so when the vertical scroller
//     appeared and claimed ~15pt, the row over-committed and slid half of that off the left edge.
//     `maxWidth: .infinity` absorbs whatever is actually given.
//
// WHAT IT OWNS: layout, the header's sort and resize interaction, horizontal scrolling when the
// columns do not fit, and the pinned header. WHAT IT DOES NOT: comparison. The caller hands it rows
// already in order and owns what "sorted by this column" means, because that is domain knowledge —
// an absent stat and an absent zone sort last for the same reason but by different rules.
import SwiftUI
import EQCompanionCore

/// One column: how wide, which way it reads, and whether its header sorts.
struct DataColumn: Identifiable, Equatable {
    /// Also the sort key the header reports.
    var key: String
    var label: String
    var width: CGFloat
    /// Numbers read right; text reads left.
    var trailing = false
    /// Takes any width the window has left over, so the table fills its pane instead of stopping
    /// short with a band of dead space. Exactly one column should carry this.
    var flexible = false
    var sortable = true
    var id: String { key }

    static let minWidth: CGFloat = 44
    static let maxWidth: CGFloat = 600
}

enum DataTableMetrics {
    /// The inset between the sidebar and a tab whose table runs edge to edge.
    ///
    /// Wider than the 12pt the boxed tabs use, and it has to be the SAME on every such tab: the
    /// Loot table sat flush against the sidebar for a release because the Gear tab's gutter was a
    /// literal in one file that the tab beside it never learned about.
    static let tabInset: CGFloat = 20

    /// The gap after every column, and the table's ONLY horizontal gap: the header and row stacks
    /// both use `spacing: 0`, so this appears exactly once per column in both the drawn row and in
    /// `totalWidth`. It is also the resize handle's hit width, which is what fills it in the header.
    static let gutter: CGFloat = 8

    /// The width a row of these columns occupies. Must equal what is drawn - see the file header.
    static func totalWidth(_ cols: [DataColumn], width: (DataColumn) -> CGFloat) -> CGFloat {
        cols.reduce(0) { $0 + width($1) + gutter }
    }
}

/// Column widths the player has dragged, by column key. Only overrides are stored, so a default
/// that improves later improves for everyone who never touched that column.
@MainActor
@Observable
final class ColumnWidths {
    private let storeKey: String
    private var overrides: [String: CGFloat]

    /// `storeKey` scopes one table's widths; two tables never share a drag.
    init(_ storeKey: String, _ d: UserDefaults = .standard) {
        self.storeKey = storeKey
        let raw = d.dictionary(forKey: storeKey) as? [String: Double] ?? [:]
        overrides = raw.mapValues { CGFloat($0) }
    }

    func width(_ c: DataColumn) -> CGFloat { overrides[c.key] ?? c.width }

    func set(_ c: DataColumn, _ w: CGFloat, _ d: UserDefaults = .standard) {
        overrides[c.key] = min(max(w, DataColumn.minWidth), DataColumn.maxWidth)
        d.set(overrides.mapValues { Double($0) }, forKey: storeKey)
    }

    /// Back to the shipped defaults - the escape hatch for a column dragged to nothing.
    func reset(_ d: UserDefaults = .standard) {
        overrides = [:]
        d.removeObject(forKey: storeKey)
    }
}

/// The draggable edge between two column headers.
///
/// ITS HEIGHT IS EXPLICIT, and that is the whole reason this is a named view rather than three
/// lines inline. See the file header: a width-only frame on a Shape eats the table's height.
struct ColumnResizeHandle: View {
    var current: CGFloat
    var set: (CGFloat) -> Void
    var reset: () -> Void

    /// Wide enough to grab, short enough that the header row stays a row. The width IS the column
    /// gutter - the handle is what occupies the gap in the header.
    static let hitWidth: CGFloat = DataTableMetrics.gutter
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

/// The table itself: a pinned, sortable, resizable header over a scrolling body.
struct DataTableView<Row: Identifiable, Cell: View>: View {
    var columns: [DataColumn]
    /// Already sorted. See the file header on why the component does not compare.
    var rows: [Row]
    var widths: ColumnWidths
    @Binding var sortKey: String
    @Binding var sortDescending: Bool
    /// Shown in place of the rows when there are none — the caller says why, since only it knows.
    var emptyText: String
    /// Drawing thousands of rows costs a frame; the caller words the note about the rest.
    var rowLimit: Int = 500
    var overflowNote: (Int) -> String = { "\(Format.count($0)) more - narrow the filters to see them." }
    /// A row's cell for one column.
    @ViewBuilder var cell: (DataColumn, Row) -> Cell
    /// Clicking anywhere on a row, when the table wants that.
    var onRowTap: ((Row) -> Void)?

    var body: some View {
        GeometryReader { geo in
            // Read the proxy ONCE. A `GeometryProxy` is live, not a snapshot: read again later it
            // answers with the size at THAT moment, not this one.
            let pane = geo.size.width
            let need = DataTableMetrics.totalWidth(columns) { widths.width($0) }
            // A horizontal ScrollView is only reached for when the columns genuinely do not fit:
            // macOS backs it with an NSScrollView that adjusts its own content insets, and with the
            // vertical scroller nested inside it the content sits left of the pane.
            let scrolls = need > pane + 0.5
            Group {
                if rows.isEmpty {
                    Text(emptyText).font(.callout).foregroundStyle(Theme.textDim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                } else if scrolls {
                    ScrollView(.horizontal) { stack(width: need) }
                } else {
                    stack(width: nil)
                }
            }
            .frame(width: pane, height: geo.size.height, alignment: .topLeading)
        }
    }

    /// Header and rows INSIDE the same scroll view, so they share one content width and cannot
    /// disagree about where a column ends. Pinning it also keeps it in view, which a long table
    /// wanted anyway.
    private func stack(width: CGFloat?) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows) { r in
                        row(r)
                        Divider().overlay(Theme.border.opacity(0.5))
                    }
                    if rows.count > rowLimit {
                        Text(overflowNote(rows.count - rowLimit))
                            .font(.caption).foregroundStyle(Theme.textFaint).padding(8)
                    }
                } header: {
                    VStack(spacing: 0) {
                        header
                        Divider().overlay(Theme.border)
                    }
                    .background(Theme.background)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// A column's frame. The flexible one ASKS for the rest rather than being handed a number.
    @ViewBuilder
    private func columnFrame(_ c: DataColumn, _ content: some View) -> some View {
        let alignment: Alignment = c.trailing ? .trailing : .leading
        if c.flexible {
            content.frame(maxWidth: .infinity, alignment: alignment)
        } else {
            content.frame(width: widths.width(c), alignment: alignment)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(columns) { c in
                HStack(spacing: 0) {
                    columnFrame(c, sortHeader(c))
                    ColumnResizeHandle(current: widths.width(c),
                                       set: { widths.set(c, $0) },
                                       reset: { widths.reset() })
                }
            }
        }
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textFaint)
        .padding(.vertical, 5)
    }

    private func sortHeader(_ c: DataColumn) -> some View {
        Button {
            guard c.sortable else { return }
            if sortKey == c.key { sortDescending.toggle() }
            // Numbers open biggest-first, text A-Z. Both are what the column is asked for.
            else { sortKey = c.key; sortDescending = c.trailing }
        } label: {
            HStack(spacing: 2) {
                if c.trailing { Spacer(minLength: 0) }
                Text(c.label).lineLimit(1)
                if sortKey == c.key && c.sortable {
                    Image(systemName: sortDescending ? "chevron.down" : "chevron.up").font(.caption2)
                }
                if !c.trailing { Spacer(minLength: 0) }
            }
            .foregroundStyle(sortKey == c.key && c.sortable ? Theme.gold : Theme.textFaint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!c.sortable)
    }

    private func row(_ r: Row) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { c in
                // The gutter is padding, not a filler view: a `Color` is flexible on both axes and
                // would stretch the row the way it once stretched the header.
                columnFrame(c, cell(c, r))
                    .padding(.trailing, DataTableMetrics.gutter)
            }
        }
        .font(.system(size: 13))
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onRowTap?(r) }
    }
}
