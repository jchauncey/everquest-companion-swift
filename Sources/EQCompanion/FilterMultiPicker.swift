// A multi-select picker for a vocabulary too long to scan.
//
// The Slots and Classes pickers are plain menus because eighteen slots and sixteen classes fit on
// screen and you find the one you want by looking. Zones do not: there are 155 of them, so a menu
// is a scroll through an alphabet hunting for a name you already know. This is the same control
// with two additions - you type to narrow it, and what you have already chosen is pinned to the
// top so taking a zone back off is never a hunt of its own.
//
// SELECTED ROWS IGNORE THE FILTER. They sit above it, always, even when the text you have typed
// does not match them: a control whose whole job is "which zones am I looking at" must be able to
// answer that and let you undo it at any moment, and hiding a selection behind a stale filter is
// how a table ends up filtered by something invisible.
import SwiftUI

/// The one-line summary a picker shows on its face. Past a handful of choices the list stops being
/// readable at a glance, so it becomes a count - the picker itself is where you check the ticks.
func pickerSummary(title: String, empty: String, options: [String],
                   picked: Set<String>, label: (String) -> String = { $0 }) -> String {
    let chosen = options.filter { picked.contains($0) }
    if chosen.isEmpty { return "\(title): \(empty)" }
    let spelled = chosen.map(label).joined(separator: " ")
    if chosen.count <= 4 && spelled.count <= 28 { return "\(title): \(spelled)" }
    return "\(title): \(chosen.count) of \(options.count)"
}

struct FilterMultiPicker: View {
    var title: String
    var empty: String
    var options: [String]
    @Binding var selection: Set<String>
    var placeholder = "Find\u{2026}"

    @State private var open = false
    @State private var filter = ""
    /// The row the arrow keys are on; Return toggles it. Follows the filter, never survives it.
    @State private var highlighted = 0

    /// Chosen first, in their own order, then whatever the typed text matches.
    private var chosen: [String] { options.filter { selection.contains($0) } }

    /// Unselected options the filter admits, best match first. A prefix beats a word start beats a
    /// bare substring, so typing "gu" reaches Guk before it reaches Ruins of Old Guk.
    private var matches: [String] {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        let pool = options.filter { !selection.contains($0) }
        guard !q.isEmpty else { return pool }
        let scored: [(String, Int)] = pool.compactMap { o in
            let s = o.lowercased()
            if s.hasPrefix(q) { return (o, 0) }
            if s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return (o, 1) }
            if s.contains(q) { return (o, 2) }
            return nil
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.0)
    }

    /// What the arrow keys walk: the pinned selection, then the matches.
    private var rows: [String] { chosen + matches }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 5) {
                Text(pickerSummary(title: title, empty: empty, options: options, picked: selection))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9)).opacity(0.7)
            }
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .popover(isPresented: $open, arrowEdge: .bottom) { sheet }
    }

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: filter) { _, _ in highlighted = 0 }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onSubmit { toggleHighlighted() }
                if !selection.isEmpty {
                    Button("Clear") { selection = []; highlighted = 0 }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.gold)
                        .help("Remove every \(title.lowercased()) filter")
                }
            }
            if rows.isEmpty {
                Text("Nothing matches.").font(.caption).foregroundStyle(Theme.textFaint)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element) { i, o in
                                row(o, index: i)
                                // The seam between what is chosen and what is on offer.
                                if i == chosen.count - 1 && !matches.isEmpty {
                                    Divider().overlay(Theme.border).padding(.vertical, 3)
                                }
                            }
                        }
                    }
                    .frame(height: 320)
                    .onChange(of: highlighted) { _, h in
                        guard rows.indices.contains(h) else { return }
                        proxy.scrollTo(rows[h], anchor: .center)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func row(_ o: String, index: Int) -> some View {
        let on = selection.contains(o)
        return Button {
            toggle(o)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Theme.gold : Theme.textFaint)
                Text(o).font(.callout).lineLimit(1)
                    .foregroundStyle(on ? Theme.text : Theme.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(index == highlighted ? Theme.gold.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(o)
    }

    private func toggle(_ o: String) {
        if selection.contains(o) { selection.remove(o) } else { selection.insert(o) }
    }

    private func toggleHighlighted() {
        guard rows.indices.contains(highlighted) else { return }
        let o = rows[highlighted]
        toggle(o)
        // Picking from the matches moves that row up into the pinned block, so the typed text has
        // done its job: clear it and leave the list ready for the next one.
        if !filter.isEmpty { filter = "" }
        highlighted = 0
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(0, highlighted + delta), rows.count - 1)
    }
}
