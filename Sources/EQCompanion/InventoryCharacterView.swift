// The Magelo-style character sheet: identity across the top, the armory grid on the left, what the
// gear adds up to on the right, and the whole rest of the dump underneath.
//
// Everything here comes from two places and says which: the LOG (name, server, level, class
// loadout — the `character` and `combo` modules) and the newest `/outputfile inventory` dump.
//
// WHAT IT DOES NOT SHOW, AND WHY THERE IS NO PANEL APOLOGISING FOR IT: your real AC, HP, mana,
// resists and AA. No `/outputfile` variant exports character stats and no AA export exists at all,
// so the gear panel names its own scope in its heading and there is no empty card explaining a
// permanent absence.
import SwiftUI
import EQCompanionCore

/// The colour the wiki and the client both use for an item name.
private let itemGreen = Color(hex: 0x6fbf7f)

/// A coarse age, in the app's own compact spelling: `16h ago`, `4d ago`.
func inventoryAge(ms: Int64, now: Int64) -> String {
    guard ms > 0 else { return "never" }
    let s = max(0, (now - ms) / 1000)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86_400 { return "\(s / 3600)h ago" }
    return "\(s / 86_400)d ago"
}

struct InventoryCharacterView: View {
    @Environment(AppModel.self) private var model
    @State private var store = InventoryStore.shared
    @State private var combo = ModuleSnapshot()
    @State private var character = ModuleSnapshot()
    @State private var showSteps = false
    @State private var query = ""
    @State private var lane: String = "all"
    @State private var now = nowMs()

    private var seq: Int { model.moduleSeqs["outputFiles"] ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                identity
                banner
                if store.ready && store.path == nil {
                    instructions
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        paperDoll
                        gearStats.frame(width: 300)
                    }
                    carryAllPanel
                }
            }
            .padding(12)
        }
        .background(Theme.background)
        .task(id: "\(seq)|\(model.epoch ?? 0)") { await store.refresh(model, seq: seq) }
        .task(id: "combo|\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") {
            await combo.refresh(model, module: "combo")
        }
        .task(id: "char|\(model.moduleSeqs["character"] ?? 0)|\(model.epoch ?? 0)") {
            await character.refresh(model, module: "character")
        }
        .task {
            // The banner's age is ambient state, and it is coarse, so a minute is plenty.
            while !Task.isCancelled {
                now = nowMs()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    // MARK: - Identity

    /// Three facts, three sources, and each one is allowed to be absent. The dump carries none of
    /// them: it has no header and no character metadata — the name and server appear only in its
    /// FILENAME.
    private var identity: some View {
        let snap = character.state["character"]
        let name = snap["name"].string ?? model.attached?.name
        let server = snap["server"].string ?? model.attached?.server
        let level = character.state["level"]["level"].int
        let source = character.state["level"]["source"].string
        let current = combo.state["current"]

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(name ?? "No character").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
            if let server { Text(server).font(.caption).foregroundStyle(Theme.textFaint) }
            if let level {
                HStack(spacing: 4) {
                    Text("Level \(level)").font(.callout.weight(.medium)).foregroundStyle(Theme.textDim)
                    if source == "who" { Text("/who").font(.caption2).foregroundStyle(Theme.textFaint) }
                }
            }
            if let slots = current["slots"].array, !slots.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, slot in
                        let candidates = (slot["candidates"].array ?? []).compactMap(\.string)
                        // An unresolved slot stays unresolved on screen: `—` for nothing named,
                        // `CLR|PAL` when the log never said which.
                        Chip(text: candidates.isEmpty || candidates.count >= 16 ? "\u{2014}" : candidates.joined(separator: "|"),
                             color: candidates.count == 1 ? Theme.gold : Theme.orange)
                    }
                    Chip(text: comboProvenanceLabel(current), color: Theme.green)
                }
            } else if combo.state.isNull == false {
                Text("No loadout read yet - one appears as soon as the log names classes you played.")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 0)
        }
    }

    /// The strongest provenance in the interval — `user` beats `who` beats `inferred`.
    private func comboProvenanceLabel(_ interval: JSONValue) -> String {
        let slots = interval["slots"].array ?? []
        if slots.contains(where: { $0["provenance"].string == "user" }) { return "you set this" }
        if slots.contains(where: { $0["provenance"].string == "who" }) { return "stated by /who" }
        return "inferred"
    }

    // MARK: - The freshness line

    /// The command, ONE clause of why it is worth typing, how to type it so it captures
    /// everything, and how old the file is — read from the file's own mtime, so it is WHEN THE
    /// PLAYER DUMPED, never when we read it.
    private var banner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(InventoryStore.command).font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(Theme.gold)
                Text(InventoryStore.why).font(.caption).foregroundStyle(Theme.textDim)
                    .lineLimit(1).truncationMode(.tail)
                Button(showSteps ? "HIDE" : "HOW") { showSteps.toggle() }
                    .buttonStyle(OutlineButtonStyle())
                Spacer(minLength: 0)
                if let at = store.updatedAt {
                    Text("updated \(inventoryAge(ms: at, now: now))")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                        .help(Format.stamp(ms: at))
                } else {
                    Text("not yet run").font(.caption).foregroundStyle(Theme.orange)
                }
                Button("REFRESH") {
                    Task { await store.refresh(model, seq: seq, force: true) }
                }
                .buttonStyle(OutlineButtonStyle())
            }
            if showSteps {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(InventoryStore.steps, id: \.self) { s in
                        Text("\u{2022} \(s)").font(.caption).foregroundStyle(Theme.textDim)
                    }
                }
            }
            if let e = store.error {
                Text(e).font(.caption).foregroundStyle(Theme.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    /// Shown only while there is no dump to read — teaching a command to someone who already ran
    /// it is worse than saying nothing.
    private var instructions: some View {
        Card("FILL THIS IN FROM THE GAME") {
            Text("Type /outputfile inventory in EverQuest. Every slot below fills with what you are wearing, straight away - leave this tab open and watch it happen.")
                .font(.callout).foregroundStyle(Theme.textDim)
        }
    }

    // MARK: - The armory grid

    private var paperDoll: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                column(.left)
                column(.right)
            }
            // The bottom row wraps rather than shrinking — a weapon name is world-supplied text.
            let bottom = store.cells.filter { $0.column == .bottom }
            VStack(spacing: 6) {
                ForEach(0..<max(1, (bottom.count + 3) / 4), id: \.self) { rowIndex in
                    HStack(spacing: 6) {
                        ForEach(bottom.dropFirst(rowIndex * 4).prefix(4)) { cell in
                            SlotTile(cell: cell)
                        }
                    }
                }
            }
            if !store.unplaced.isEmpty {
                Card("ALSO EQUIPPED") {
                    VStack(spacing: 6) { ForEach(store.unplaced) { SlotTile(cell: $0) } }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func column(_ c: SheetColumn) -> some View {
        VStack(spacing: 6) {
            ForEach(store.cells.filter { $0.column == c }) { SlotTile(cell: $0) }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - What the gear adds up to

    private var gearStats: some View {
        Card("STATS FROM GEAR", trailing: AnyView(Chip(text: "with +N", color: Theme.textFaint))) {
            VStack(alignment: .leading, spacing: 2) {
                statRow("AC", "\(signed(store.totals.ac))")
                ForEach(store.totals.stats) { statRow($0.label, signed($0.total)) }
                ForEach(store.totals.saves) { statRow($0.label, signed($0.total)) }
                // Percentages are STATED, never added: whether worn haste stacks is a game rule
                // no source in this app states.
                ForEach(store.totals.unsummed) { u in
                    statRow(u.label, u.values.joined(separator: "  "))
                }
                Divider().overlay(Theme.border).padding(.vertical, 4)
                // A count, not a caveat: it says how much of your gear these numbers cover.
                Text("\(store.totals.counted) of \(store.totals.counted + store.totals.unknown) worn items"
                     + (store.totals.unknown > 0 ? " \u{00b7} \(store.totals.unknown) not in the item database" : ""))
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : "\(n)" }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(Theme.textDim)
            Spacer(minLength: 8)
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
        }
    }

    // MARK: - Everything you carry

    /// The other half of the same file: where is everything else. Two controls, one axis each —
    /// the box asks WHAT (a substring of the item's name) and the chips ask WHERE.
    private var carryAllPanel: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = store.carry.rows.filter { row in
            (lane == "all" || row.lane == lane) && (needle.isEmpty || row.searchKey.contains(needle))
        }
        return Card("EVERYTHING YOU CARRY") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                    laneChip(id: "all", label: "All", count: store.carry.rows.count)
                    ForEach(store.carry.lanes) { laneChip(id: $0.id, label: $0.label, count: $0.count) }
                    Spacer(minLength: 0)
                }
                if rows.isEmpty {
                    Text(store.carry.rows.isEmpty
                         ? "Nothing to list yet - the dump has not been read."
                         : "Nothing here matches that.")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                } else {
                    HStack {
                        Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Location").frame(width: 200, alignment: .leading)
                        Text("Count").frame(width: 54, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                HStack {
                                    Text(row.name).foregroundStyle(Theme.text)
                                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                                    Text(row.location).foregroundStyle(Theme.textDim)
                                        .frame(width: 200, alignment: .leading).lineLimit(1)
                                    Text("\(row.count)").foregroundStyle(Theme.textDim)
                                        .frame(width: 54, alignment: .trailing).monospacedDigit()
                                }
                                .font(.caption)
                                .padding(.vertical, 3)
                                Divider().overlay(Theme.border.opacity(0.5))
                            }
                        }
                    }
                    .frame(height: 260)
                }
            }
        }
    }

    private func laneChip(id: String, label: String, count: Int) -> some View {
        Button { lane = id } label: {
            Chip(text: "\(label) \(count)", color: lane == id ? Theme.gold : Theme.textDim, filled: lane == id)
        }
        .buttonStyle(.plain)
    }
}

/// One cell: icon, slot label, the item name with its exaltations, or a quiet empty line.
struct SlotTile: View {
    var cell: SheetCell

    var body: some View {
        HStack(spacing: 7) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(cell.label).font(.caption2).foregroundStyle(Theme.textFaint)
                if let item = cell.item {
                    // The ` +N` is kept: the thing the player owns is `Executioners Hood +3`, and
                    // a tile quietly showing the base name would answer a question nobody asked.
                    Text(item.name).font(.caption).foregroundStyle(itemGreen)
                        .lineLimit(1).truncationMode(.tail)
                    if !item.exaltations.isEmpty {
                        // Printed with ` (Exaltation)` already removed — the row of chips is
                        // already saying that by existing.
                        HStack(spacing: 3) {
                            ForEach(Array(item.exaltations.enumerated()), id: \.offset) { _, n in
                                Chip(text: n, color: Theme.purple)
                            }
                        }
                    }
                } else {
                    Text("empty").font(.caption).foregroundStyle(Theme.textFaint.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
    }

    @ViewBuilder private var icon: some View {
        if let item = cell.item, let img = GameData.shared.item(named: item.baseName).flatMap({ GameData.shared.itemIcon($0.iconId) }) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: 26, height: 26)
        } else {
            RoundedRectangle(cornerRadius: 4).fill(Theme.paperRaised).frame(width: 26, height: 26)
        }
    }
}
