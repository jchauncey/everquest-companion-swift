// Panels in two columns you can rearrange by dragging. Each panel carries a grip at its top edge;
// drop it on another panel to put it above that one, or on the space under a column to put it at the
// bottom of that column. The arrangement is a `PanelLayout`, saved as a string on `Prefs`.
//
// The layout rules live in `PanelLayout` (pure, tested); the view only draws columns and turns drops
// into `move` calls. Drag payloads are prefixed with the board's id, so a panel cannot be dropped
// onto another board and a stray text drag is ignored.
import SwiftUI

/// Which panel sits in which column, top to bottom.
struct PanelLayout: Equatable {
    var columns: [[String]]

    /// `a,b|c,d` → [[a, b], [c, d]].
    static func decode(_ text: String) -> PanelLayout {
        PanelLayout(columns: text.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.split(separator: ",").map(String.init) })
    }

    var encoded: String { columns.map { $0.joined(separator: ",") }.joined(separator: "|") }

    /// The saved layout made to fit the panels this build has: unknown ids dropped, duplicates kept
    /// once, missing ids placed where the default puts them, and exactly `defaults.columns.count`
    /// columns. A saved string from an older build can never hide a panel.
    static func normalized(_ saved: PanelLayout, defaults: PanelLayout) -> PanelLayout {
        let known = Set(defaults.columns.flatMap { $0 })
        let n = defaults.columns.count
        var seen = Set<String>()
        var cols: [[String]] = (0..<n).map { i in
            guard i < saved.columns.count else { return [] }
            return saved.columns[i].filter { known.contains($0) && seen.insert($0).inserted }
        }
        for (i, col) in defaults.columns.enumerated() {
            for id in col where !seen.contains(id) {
                cols[i].append(id)
                seen.insert(id)
            }
        }
        return PanelLayout(columns: cols)
    }

    /// Put `id` directly above `target`. A no-op when either is unknown or they are the same.
    mutating func move(_ id: String, before target: String) {
        guard id != target, contains(id), contains(target) else { return }
        remove(id)
        for c in columns.indices {
            if let i = columns[c].firstIndex(of: target) { columns[c].insert(id, at: i); return }
        }
    }

    /// Put `id` at the bottom of column `column`.
    mutating func move(_ id: String, toEndOf column: Int) {
        guard contains(id), columns.indices.contains(column) else { return }
        remove(id)
        columns[column].append(id)
    }

    func contains(_ id: String) -> Bool { columns.contains { $0.contains(id) } }

    private mutating func remove(_ id: String) {
        for c in columns.indices { columns[c].removeAll { $0 == id } }
    }
}

struct PanelBoard: View {
    /// Namespaces drag payloads: `<board>:<panel id>`.
    var board: String
    @Binding var layout: PanelLayout
    /// Titles for the drag preview, by panel id.
    var titles: [String: String]
    /// The panel's content, or nil when it has nothing to draw right now (it keeps its place).
    var panel: (String) -> AnyView?

    @State private var targeted: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(layout.columns.enumerated()), id: \.offset) { index, column in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(column, id: \.self) { id in
                        if let content = panel(id) { slot(id, content) }
                    }
                    columnEnd(index)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func payload(_ id: String) -> String { "\(board):\(id)" }

    private func dropped(_ items: [String]) -> String? {
        guard let item = items.first, item.hasPrefix(board + ":") else { return nil }
        return String(item.dropFirst(board.count + 1))
    }

    private func slot(_ id: String, _ content: AnyView) -> some View {
        content
            .overlay(alignment: .top) { grip(id) }
            .overlay(alignment: .top) {
                // Where the dragged panel will land: a line along this panel's top edge.
                if targeted == id {
                    Capsule().fill(Theme.gold).frame(height: 3).offset(y: -7)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let moving = dropped(items) else { return false }
                withAnimation(.easeInOut(duration: 0.15)) { layout.move(moving, before: id) }
                return true
            } isTargeted: { on in
                if on { targeted = id } else if targeted == id { targeted = nil }
            }
    }

    private func grip(_ id: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textFaint)
            .frame(width: 44, height: 12)
            .contentShape(Rectangle())
            .padding(.top, 1)
            .help("Drag to move this panel")
            .draggable(payload(id)) {
                Text(titles[id] ?? id)
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
            }
    }

    /// The space under a column: dropping here puts the panel at the bottom of that column, and an
    /// emptied column still has somewhere to drop.
    private func columnEnd(_ index: Int) -> some View {
        let key = "#end\(index)"
        return RoundedRectangle(cornerRadius: 8)
            .strokeBorder(targeted == key ? Theme.gold : Color.clear, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .frame(maxWidth: .infinity, minHeight: layout.columns[index].isEmpty ? 120 : 48)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let moving = dropped(items) else { return false }
                withAnimation(.easeInOut(duration: 0.15)) { layout.move(moving, toEndOf: index) }
                return true
            } isTargeted: { on in
                if on { targeted = key } else if targeted == key { targeted = nil }
            }
    }
}

/// A scroll area as tall as its content up to `maxHeight`, and scrolling past it: a short list
/// takes its own height, a long one stops growing the page.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
        }
        .frame(height: min(max(height, 1), maxHeight))
    }
}
