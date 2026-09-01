// THE dropdown. Every filter control in the app is one of these two views.
//
// They began as a menu each, and menus cannot hold a text field — so the Zones filter, with 155
// options, was a scroll through an alphabet hunting for a name you already knew. This is that
// control rebuilt as a button and a popover, which can hold whatever it needs to: a filter field, a
// scrolling list of real rows, and a pinned block of what you have already chosen.
//
// ONE COMPONENT, TWO SHAPES. `FilterMultiPicker` takes a `Set` and toggles; `FilterOnePicker` takes
// a single value and closes on pick. They share `PickerSheet` below, so the two cannot drift into
// looking like different controls — which is exactly what the menus they replaced had done, some
// bordered and some borderless, some sized to their text and some to a fixed frame.
//
// SELECTED ROWS IGNORE THE FILTER (multi only). They sit above it, always, even when the text you
// have typed does not match them: a control whose job is "which zones am I looking at" must be able
// to answer that and let you undo it at any moment, and hiding a selection behind a stale filter is
// how a table ends up filtered by something invisible.
import SwiftUI

/// One row: the value that is stored, and the text that is read. They differ wherever the corpus's
/// spelling is not the player's - `1hs` is "One-handed slashing".
struct PickerOption: Identifiable, Hashable {
    var value: String
    var label: String
    var id: String { value }

    init(_ value: String, _ label: String? = nil) {
        self.value = value
        self.label = label ?? value
    }
}

extension Array where Element == PickerOption {
    /// Plain strings, where value and label are the same word.
    static func of(_ values: [String], label: (String) -> String = { $0 }) -> [PickerOption] {
        values.map { PickerOption($0, label($0)) }
    }
}

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

// MARK: - The shared face and sheet

/// A list long enough that reading it beats scanning it. Below this the filter field is hidden -
/// six options do not need to be searched, and a search box over them is furniture.
private let filterFieldThreshold = 12

/// The button every picker wears, so they are one control at a glance.
private struct PickerFace: View {
    var text: String
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                Text(text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9)).opacity(0.7)
            }
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }
}

/// The popover: an optional filter field, then rows. `pinned` is drawn above a divider and is not
/// filtered; `rest` is what the typed text admits.
private struct PickerSheet: View {
    var placeholder: String
    var showsFilter: Bool
    var pinned: [PickerOption]
    var rest: [PickerOption]
    var isOn: (PickerOption) -> Bool
    /// Multi-select draws boxes and stays open; single draws checks and closes.
    var multi: Bool
    var onClear: (() -> Void)?
    var onPick: (PickerOption) -> Void

    @Binding var filter: String
    @Binding var highlighted: Int

    private var rows: [PickerOption] { pinned + rest }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsFilter || onClear != nil {
                HStack(spacing: 6) {
                    if showsFilter {
                        TextField(placeholder, text: $filter)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: filter) { _, _ in highlighted = 0 }
                            .onKeyPress(.downArrow) { move(1); return .handled }
                            .onKeyPress(.upArrow) { move(-1); return .handled }
                            .onSubmit { pickHighlighted() }
                    }
                    if let onClear {
                        Button("Clear") { onClear(); highlighted = 0 }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.gold)
                    }
                }
            }
            if rows.isEmpty {
                Text("Nothing matches.").font(.caption).foregroundStyle(Theme.textFaint)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, o in
                                row(o, index: i)
                                // The seam between what is chosen and what is on offer.
                                if i == pinned.count - 1 && !rest.isEmpty {
                                    Divider().overlay(Theme.border).padding(.vertical, 3)
                                }
                            }
                        }
                    }
                    .frame(height: min(320, CGFloat(rows.count) * 24 + 8))
                    .onChange(of: highlighted) { _, h in
                        guard rows.indices.contains(h) else { return }
                        proxy.scrollTo(rows[h].id, anchor: .center)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    private func row(_ o: PickerOption, index: Int) -> some View {
        let on = isOn(o)
        return Button { onPick(o) } label: {
            HStack(spacing: 6) {
                Image(systemName: multi ? (on ? "checkmark.square.fill" : "square")
                                        : (on ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 11))
                    .foregroundStyle(on ? Theme.gold : Theme.textFaint)
                Text(o.label).font(.callout).lineLimit(1)
                    .foregroundStyle(on ? Theme.text : Theme.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(index == highlighted ? Theme.gold.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(o.id)
    }

    private func pickHighlighted() {
        guard rows.indices.contains(highlighted) else { return }
        onPick(rows[highlighted])
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(0, highlighted + delta), rows.count - 1)
    }
}

/// Unselected options the filter admits, best match first: a prefix beats a word start beats a bare
/// substring, so typing "gu" reaches Guk before The Ruins of Old Guk.
private func matching(_ pool: [PickerOption], _ filter: String) -> [PickerOption] {
    let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return pool }
    let scored: [(PickerOption, Int)] = pool.compactMap { o in
        let s = o.label.lowercased()
        if s.hasPrefix(q) { return (o, 0) }
        if s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return (o, 1) }
        if s.contains(q) { return (o, 2) }
        return nil
    }
    return scored.sorted { $0.1 == $1.1 ? $0.0.label < $1.0.label : $0.1 < $1.1 }.map(\.0)
}

// MARK: - Multi-select

struct FilterMultiPicker: View {
    var title: String
    var empty: String
    var options: [PickerOption]
    @Binding var selection: Set<String>
    var placeholder = "Find\u{2026}"

    @State private var open = false
    @State private var filter = ""
    @State private var highlighted = 0

    /// Convenience for the common case: plain strings, optionally relabelled.
    init(title: String, empty: String, options: [String], selection: Binding<Set<String>>,
         label: @escaping (String) -> String = { $0 }, placeholder: String = "Find\u{2026}") {
        self.init(title: title, empty: empty, options: .of(options, label: label),
                  selection: selection, placeholder: placeholder)
    }

    init(title: String, empty: String, options: [PickerOption], selection: Binding<Set<String>>,
         placeholder: String = "Find\u{2026}") {
        self.title = title
        self.empty = empty
        self.options = options
        self._selection = selection
        self.placeholder = placeholder
    }

    /// What is chosen, pinned above the rest — INCLUDING a pick the options no longer offer.
    ///
    /// A stored selection the data has stopped listing is the worst kind of filter: it hides
    /// everything and cannot be seen, let alone removed. So an orphan is drawn from its own stored
    /// value rather than dropped, and taking it off is the same click as any other row.
    private var chosen: [PickerOption] {
        let known = Set(options.map(\.value))
        return options.filter { selection.contains($0.value) }
            + selection.subtracting(known).sorted().map { PickerOption($0) }
    }

    var body: some View {
        let rest = matching(options.filter { !selection.contains($0.value) }, filter)
        PickerFace(text: pickerSummary(title: title, empty: empty,
                                       options: options.map(\.value), picked: selection,
                                       label: { v in options.first { $0.value == v }?.label ?? v })) {
            open = true
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            PickerSheet(placeholder: placeholder,
                        showsFilter: options.count >= filterFieldThreshold,
                        pinned: chosen, rest: rest,
                        isOn: { selection.contains($0.value) },
                        multi: true,
                        onClear: selection.isEmpty ? nil : { selection = [] },
                        onPick: { toggle($0) },
                        filter: $filter, highlighted: $highlighted)
        }
    }

    private func toggle(_ o: PickerOption) {
        if selection.contains(o.value) { selection.remove(o.value) } else { selection.insert(o.value) }
        // Picking from the matches moves that row up into the pinned block, so the typed text has
        // done its job: clear it and leave the list ready for the next one.
        if !filter.isEmpty { filter = "" }
        highlighted = 0
    }
}

// MARK: - Single-select

/// The same control for a one-of-many choice. There is no pinned block - with one selection the
/// list is short enough to see it - and picking closes the popover, because the choice is complete.
struct FilterOnePicker: View {
    var title: String
    var options: [PickerOption]
    @Binding var selection: String
    var placeholder = "Find\u{2026}"
    /// Shown on the face when the selection names no option (a value the corpus no longer carries).
    var unknownLabel = "\u{2014}"

    @State private var open = false
    @State private var filter = ""
    @State private var highlighted = 0

    init(title: String, options: [String], selection: Binding<String>,
         label: @escaping (String) -> String = { $0 }, placeholder: String = "Find\u{2026}") {
        self.init(title: title, options: .of(options, label: label),
                  selection: selection, placeholder: placeholder)
    }

    init(title: String, options: [PickerOption], selection: Binding<String>,
         placeholder: String = "Find\u{2026}") {
        self.title = title
        self.options = options
        self._selection = selection
        self.placeholder = placeholder
    }

    var body: some View {
        let current = options.first { $0.value == selection }?.label ?? unknownLabel
        PickerFace(text: title.isEmpty ? current : "\(title): \(current)") { open = true }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                PickerSheet(placeholder: placeholder,
                            showsFilter: options.count >= filterFieldThreshold,
                            pinned: [], rest: matching(options, filter),
                            isOn: { $0.value == selection },
                            multi: false,
                            onClear: nil,
                            onPick: { pick($0) },
                            filter: $filter, highlighted: $highlighted)
            }
    }

    private func pick(_ o: PickerOption) {
        selection = o.value
        filter = ""
        highlighted = 0
        open = false
    }
}
