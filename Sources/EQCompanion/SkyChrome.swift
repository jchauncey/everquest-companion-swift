// The small pieces every Plane of Sky tab shares: the multi-select facet pickers, the
// "Count items from" control with the `/outputfile inventory` freshness line under it, the
// progress bar, and the star / ignore buttons.
import SwiftUI
import EQCompanionCore

/// A closed-list picker that narrows by OR inside itself. Empty is no filter — nothing here ever
/// substitutes a selection of its own.
struct SkyMultiSelect: View {
    var label: String
    var placeholder: String
    var options: [String]
    @Binding var selection: [String]
    var width: CGFloat = 190

    /// A stored pick the data no longer offers stays in the list, so the user can SEE the chip
    /// that is hiding everything and take it off.
    private var offered: [String] {
        var out = options
        let known = Set(options)
        for p in selection where !known.contains(p) { out.append(p) }
        return out
    }

    var body: some View {
        Menu {
            if !selection.isEmpty {
                Button("Clear") { selection = [] }
                Divider()
            }
            ForEach(offered, id: \.self) { o in
                Button {
                    if selection.contains(o) { selection.removeAll { $0 == o } } else { selection.append(o) }
                } label: {
                    Label(o, systemImage: selection.contains(o) ? "checkmark" : "")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.caption2).foregroundStyle(Theme.textFaint)
                Text(selection.isEmpty ? placeholder : selection.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(selection.isEmpty ? Theme.textDim : Theme.gold)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The count-source dropdown plus the freshness line that hangs under it. The line is only about
/// the dump, so it appears only while a source that READS the dump is picked — under `log` the file
/// could be a year old and not one number on screen would differ.
struct SkyInventorySource: View {
    @Environment(AppModel.self) private var model
    @Bindable var store: SkyStore
    @State private var showSteps = false

    private static let steps = [
        "Stand at a banker and open your Bank.",
        "Open Dragon's Hoard too - it only dumps while its window is open.",
        "Open your Tradeskill Depot once if you keep anything in it.",
        "Type /outputfile inventory.",
        "Wind Runes and other currency-tab items are never in the dump - the game leaves them out."
    ]

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Picker("Count items from", selection: $store.countSource) {
                ForEach(SkyCountSource.allCases) { s in Text(s.label).tag(s) }
            }
            .pickerStyle(.menu)
            .frame(width: 300)
            .font(.caption)
            line
            if showSteps {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s)").font(.caption2).foregroundStyle(Theme.textDim)
                    }
                }
                .padding(8)
                .frame(maxWidth: 380, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            }
        }
    }

    @ViewBuilder private var line: some View {
        if store.countSource.readsInventory {
            HStack(spacing: 6) {
                Text("/outputfile inventory").font(.caption2.monospaced()).foregroundStyle(Theme.textFaint)
                Button("Refresh") { store.reloadInventory(model) }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Theme.gold)
                Button(showSteps ? "Hide steps" : "How") { showSteps.toggle() }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(Theme.gold)
                Text(SkyAge.updated(store.inventoryUpdatedAt)).font(.caption2).foregroundStyle(Theme.textFaint)
                Text("·").font(.caption2).foregroundStyle(Theme.textFaint)
                Text(SkyAge.loaded(store.inventoryLoadedAt)).font(.caption2)
                    .foregroundStyle(stale ? Theme.orange : Theme.textFaint)
            }
            .help(store.inventoryError ?? store.inventoryPath ?? "")
        } else if store.inventoryLoadedAt != nil {
            Text("Inventory export loaded but not counted - switch to Both to include it.")
                .font(.caption2).foregroundStyle(Theme.textFaint)
        }
    }

    /// Provably newer on disk than the copy we hold — a fact about two instants, not a threshold.
    private var stale: Bool {
        guard let u = store.inventoryUpdatedAt, let r = store.inventoryLoadedAt else { return false }
        return u - r > 1000
    }
}

/// `0/3 items` over a bar, with the percentage on the right — the accordion's progress block.
struct SkyProgressBar: View {
    var have: Int
    var need: Int
    var ratio: Double

    var body: some View {
        let pct = Int((ratio * 100).rounded())
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(have)/\(need) items").font(.caption2).foregroundStyle(Theme.textDim)
                Spacer()
                Text("\(pct)%").font(.caption2).foregroundStyle(Theme.textDim).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.paperRaised).frame(height: 4)
                    Capsule().fill(pct >= 100 ? Theme.green : Theme.gold)
                        .frame(width: geo.size.width * min(1, max(0, ratio)), height: 4)
                }
            }
            .frame(height: 4)
        }
        .frame(width: 150)
    }
}

struct SkyStarButton: View {
    var starred: Bool
    var help: String
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: starred ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(starred ? Theme.orange : Theme.textFaint)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SkyIgnoreButton: View {
    var ignored: Bool
    var toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: ignored ? "eye" : "eye.slash")
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
        }
        .buttonStyle(.plain)
        .help(ignored ? "Bring this quest back to the list" : "Hide this quest - it lands on the Ignored tab")
    }
}

/// A checkbox with the Electron tab's own hover text.
struct SkyCheck: View {
    var label: String
    var help: String = ""
    @Binding var on: Bool

    var body: some View {
        Toggle(isOn: $on) { Text(label).font(.caption) }
            .toggleStyle(.checkbox)
            .help(help)
    }
}

/// The wording every surface that can be fooled by a Wind Rune shares.
enum SkyNotes {
    static let dumpBlindItem = "Wind Runes sit in the currency tab, and the game never puts currency-tab items in an /outputfile inventory dump - re-exporting cannot help. Only the looted log can see one, so a rune you already hold reads 0 here if it dropped before this log began. Use the pencil to state how many you hold."
    static let dumpBlindReady = "Wind Runes are never in an /outputfile inventory dump - the game leaves currency-tab items out, so only the looted log can count one. If a quest is missing here because its rune reads 0, expand it and state the rune count by hand."
}
