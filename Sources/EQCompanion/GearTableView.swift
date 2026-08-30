// The gear search table: every equippable page in the committed corpus, filtered and sorted on
// numbers that move with the upgrade slider.
//
// THE SLIDER IS A PURE MAP. `rows.map { $0.scaled(state) }` runs BEFORE filter and sort, so a
// threshold filter and a column sort both read the scaled numbers, and moving the slider costs one
// pass over the corpus rather than an index rebuild.
//
// ABSENT IS NOT ZERO. A cell whose item stated no value for that key renders BLANK and sorts LAST
// in both directions — an item with no `HASTE:` line is not an item with 0% haste.
import SwiftUI
import EQCompanionCore

/// The Effect dropdown's options, verbatim.
private let effectOptions: [(String, String)] = [
    ("any", "Any effect"), ("has", "Has an effect"),
    ("proc", "Proc"), ("worn", "Worn"), ("focus", "Focus"), ("click", "Click")
]

struct GearTableView: View {
    @Environment(AppModel.self) private var model
    @State private var index = GearIndex.shared
    @State private var store = InventoryStore.shared
    @State private var wishes = WishListStore.shared
    @State private var combo = ModuleSnapshot()
    @State private var loot = ModuleSnapshot()

    @State private var query = ""
    @State private var slots: Set<String> = []
    @State private var weapons: Set<String> = []
    @State private var effect = "any"
    @State private var classes: Set<String> = []
    @State private var classesPinned = false
    @State private var eraOnly = true
    @State private var ownedOnly = false
    @State private var tier = 0
    @State private var fraction = 0
    @State private var sortKey = "AC"
    @State private var sortDescending = true
    @State private var opened: GearRow?

    /// The columns the table draws, in order. The Electron table lets a player pick these; the
    /// four core ones plus whatever is being sorted on is what it opens with.
    private var numericColumns: [String] {
        var cols = ["AC", "HP", "MP", "RATIO"]
        if !cols.contains(sortKey) && sortKey != "name" { cols.append(sortKey) }
        return cols
    }

    private var upgradeState: ItemUpgradeState {
        ItemUpgradeState(full: tier, fraction: fraction).normalized
    }

    /// The classes the log says you are playing — the picker's default until the player edits it,
    /// which pins it.
    private var detectedClasses: [String] {
        (combo.state["current"]["slots"].array ?? []).compactMap { slot in
            let c = (slot["candidates"].array ?? []).compactMap(\.string)
            return c.count == 1 ? c[0] : nil
        }
    }

    /// Every item name this character's loot history saw.
    ///
    /// READ FROM THE `loot` MODULE SNAPSHOT, NOT THE `loot.ledger` VIEW. The view source is a
    /// windowed table and its window maxes out at 1000 rows; the owner's own ledger is 2,404, so a
    /// view-backed set would have quietly answered "never looted" for the older 1,400 — the exact
    /// shape of a filter that hides gear the player has held in their hands. The module's state is
    /// the whole array.
    private var lootedNames: Set<String> {
        // The ` +N` comes off first: `Cloak of Flames +4` and `Cloak of Flames` are one item at the
        // counting boundary, which is the join the corpus key is on.
        Set((loot.state.array ?? []).compactMap {
            $0["item"].string.map { GameData.nameKey(parseItemName($0).base) }
        })
    }

    var body: some View {
        // ONE pass over the corpus per render: the caption and the table are two readings of the
        // same answer, and computing it twice would double the cost of every keystroke. The loot
        // set is folded once here for the same reason — it is 2,404 rows and both the filter and
        // the Owned column read it.
        let looted = lootedNames
        let result = pipeline(looted)
        return VStack(alignment: .leading, spacing: 8) {
            controls
            caption(result)
            if !index.ready {
                Spacer()
                Text("Reading the item database\u{2026}").font(.callout).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                table(result, looted: looted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear {
            index.start()
            wishes.bind(character: model.attached)
        }
        .task(id: "combo|\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") {
            await combo.refresh(model, module: "combo")
            if !classesPinned { classes = Set(detectedClasses) }
        }
        .task(id: "loot|\(model.moduleSeqs["loot"] ?? 0)|\(model.epoch ?? 0)") {
            await loot.refresh(model, module: "loot")
        }
        .task(id: "inv|\(model.moduleSeqs["outputFiles"] ?? 0)|\(model.epoch ?? 0)") {
            await store.refresh(model, seq: model.moduleSeqs["outputFiles"] ?? 0)
        }
        .sheet(item: $opened) { row in
            VStack(spacing: 0) {
                KnowledgeCard(domain: "item", name: row.name)
                Divider()
                HStack {
                    Spacer()
                    Button("CLOSE") { opened = nil }.buttonStyle(OutlineButtonStyle())
                }.padding(8)
            }
            .frame(width: 560, height: 620)
            .background(Theme.background)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search gear", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 200)
                multiPicker(title: "Slots", empty: "every slot", options: equipSlots, selection: $slots)
                multiPicker(title: "Weapon type", empty: "every kind", options: weaponPicks,
                            selection: $weapons, label: { weaponPickLabel[$0] ?? $0 })
                Picker("", selection: $effect) {
                    ForEach(effectOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(width: 130)
                multiPicker(title: "Classes", empty: "every class", options: classAbbrs,
                            selection: $classes, onEdit: { classesPinned = true })
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                toggleChip("Current era", on: $eraOnly, help: "Hide items from outside \(currentEraLabel)")
                toggleChip("Owned or looted", on: $ownedOnly,
                           help: "Keep only what your newest /outputfile inventory dump names or your loot history saw. Some key rings are not counted - see the Owned column.")
                Divider().frame(height: 18).overlay(Theme.border)
                Text("Simulate upgrade").font(.caption).foregroundStyle(Theme.textDim)
                Slider(value: Binding(
                    get: { Double(tier) },
                    set: { v in
                        tier = Int(v.rounded())
                        fraction = min(fraction, max(0, (1 << max(0, min(9, tier))) - 1))
                    }), in: 0...Double(GearUpgrade.maxTier), step: 1)
                    .frame(width: 170)
                if tier > 0 && tier < GearUpgrade.maxTier {
                    Slider(value: Binding(get: { Double(fraction) }, set: { fraction = Int($0.rounded()) }),
                           in: 0...Double((1 << tier) - 1), step: 1)
                        .frame(width: 110)
                }
                Text(upgradeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tier == 0 && fraction == 0 ? Theme.textDim : Theme.gold)
                    .frame(width: 140, alignment: .leading)
                    .help("What the table is showing: every stat scaled to this upgrade state, the way the item window reads it.")
                Spacer(minLength: 0)
            }
        }
    }

    private var upgradeLabel: String {
        let s = upgradeState
        var out = "Tier \(s.full)"
        if s.full > 0 && s.full < GearUpgrade.maxTier { out += " \u{00b7} \(s.fraction)/\(1 << s.full)" }
        return out + " \u{00b7} " + s.percentLabel
    }

    private func toggleChip(_ label: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Chip(text: label, color: on.wrappedValue ? Theme.gold : Theme.textDim, filled: on.wrappedValue)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func multiPicker(title: String, empty: String, options: [String],
                             selection: Binding<Set<String>>,
                             label: @escaping (String) -> String = { $0 },
                             onEdit: @escaping () -> Void = {}) -> some View {
        Menu {
            Button("Clear") { selection.wrappedValue = []; onEdit() }
            Divider()
            ForEach(options, id: \.self) { o in
                Button {
                    if selection.wrappedValue.contains(o) { selection.wrappedValue.remove(o) }
                    else { selection.wrappedValue.insert(o) }
                    onEdit()
                } label: {
                    Label(label(o), systemImage: selection.wrappedValue.contains(o) ? "checkmark" : "")
                }
            }
        } label: {
            let picked = options.filter { selection.wrappedValue.contains($0) }
            Text(picked.isEmpty ? "\(title): \(empty)" : "\(title): \(picked.map(label).joined(separator: " "))")
                .font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 200)
    }

    // MARK: - The pipeline

    /// Every row at the slider's state — the map that has to be the whole cost of moving it.
    private struct ScaledRow: Identifiable {
        var row: GearRow
        var stats: [String: Int]
        var id: String { row.key }
    }

    private func value(_ r: ScaledRow, _ key: String) -> Double? {
        switch key {
        case "RATIO": return damageRatio(r.stats)
        case "EFF_HP": return gearEffectiveHp(r.stats).map(Double.init)
        default: return r.stats[key].map(Double.init)
        }
    }

    private func pipeline(_ looted: Set<String>) -> (rows: [ScaledRow], total: Int) {
        let all = index.rows
        let state = upgradeState
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        var out: [ScaledRow] = []
        out.reserveCapacity(1024)
        for row in all {
            if !needle.isEmpty && !row.searchKey.contains(needle) { continue }
            if !slots.isEmpty && !row.slots.contains(where: { slots.contains($0) }) { continue }
            if !weapons.isEmpty {
                guard let t = row.weaponType, weapons.contains(where: { weaponPickCovers($0, t) }) else { continue }
            }
            switch effect {
            case "any": break
            case "has": if row.effects.isEmpty { continue }
            default: if !row.effects.contains(where: { $0.socket == effect }) { continue }
            }
            // A page that states NO class list is never hidden by the class picker: `[]` means the
            // wiki declined to say, not that nobody can use it.
            if !classes.isEmpty && !row.classes.isEmpty && !row.classes.contains(where: { classes.contains($0) }) { continue }
            // Note that an UNKNOWN era hides too — the Electron rule, and the honest one for a
            // control whose promise is "only what you can go and get tonight".
            if eraOnly && row.era != .inEra { continue }
            if ownedOnly {
                let own = store.ownership[row.key]
                let has = (own?.owned ?? false) || (own?.exaltations ?? 0) > 0 || looted.contains(row.key)
                if !has { continue }
            }
            out.append(ScaledRow(row: row, stats: row.scaled(state)))
        }

        let key = sortKey
        let sign = sortDescending ? -1.0 : 1.0
        out.sort { a, b in
            if key == "name" {
                let c = a.row.name.localizedCaseInsensitiveCompare(b.row.name)
                return sortDescending ? c == .orderedDescending : c == .orderedAscending
            }
            let av = value(a, key), bv = value(b, key)
            // `nil` sorts LAST in both directions; ties break by name, so the order is total.
            if av == nil && bv == nil { return a.row.name < b.row.name }
            guard let av else { return false }
            guard let bv else { return true }
            if av == bv { return a.row.name < b.row.name }
            return sign * av < sign * bv
        }
        return (out, all.count)
    }

    // MARK: - The caption

    private func caption(_ p: (rows: [ScaledRow], total: Int)) -> some View {
        HStack(spacing: 6) {
            Text("\(Format.count(p.rows.count)) of \(Format.count(p.total)) items")
            if let at = index.corpus.scrapedAt { Text("\u{00b7} wiki data from \(at)") }
            if let at = store.updatedAt {
                Text("\u{00b7} dump \(inventoryAge(ms: at, now: nowMs()))")
            }
            Spacer(minLength: 0)
        }
        .font(.caption).foregroundStyle(Theme.textFaint)
    }

    // MARK: - The table

    private func table(_ result: (rows: [ScaledRow], total: Int), looted: Set<String>) -> some View {
        let rows = result.rows
        let showOwned = !store.ownership.isEmpty || !looted.isEmpty
        return VStack(spacing: 0) {
            header(showOwned: showOwned)
            Divider().overlay(Theme.border)
            if rows.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows.prefix(500)) { r in
                            row(r, showOwned: showOwned, looted: looted)
                            Divider().overlay(Theme.border.opacity(0.5))
                        }
                        if rows.count > 500 {
                            Text("\(Format.count(rows.count - 500)) more - narrow the filters to see them.")
                                .font(.caption).foregroundStyle(Theme.textFaint).padding(8)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyText: String {
        if ownedOnly { return "Nothing here is owned or looted. Ownership is read from your newest /outputfile inventory dump plus this character's loot history." }
        if eraOnly { return "No gear matches these filters - the Current era toggle above may be hiding some." }
        if !classes.isEmpty { return "No gear matches these filters. An item whose page states no class list is never hidden by the Classes picker." }
        return "No gear matches these filters."
    }

    private func header(showOwned: Bool) -> some View {
        HStack(spacing: 8) {
            sortHeader("Item", key: "name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Slot").frame(width: 96, alignment: .leading)
            Text("Classes").frame(width: 90, alignment: .leading)
            ForEach(numericColumns, id: \.self) { c in
                sortHeader(columnLabel(c), key: c).frame(width: 58, alignment: .trailing)
            }
            if showOwned { Text("Owned").frame(width: 130, alignment: .leading) }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
        .padding(.vertical, 4)
    }

    private func columnLabel(_ key: String) -> String {
        if key == "RATIO" { return "Ratio" }
        return key.replacingOccurrences(of: "_", with: " ")
    }

    private func sortHeader(_ label: String, key: String) -> some View {
        Button {
            if sortKey == key { sortDescending.toggle() }
            else { sortKey = key; sortDescending = key != "name" }
        } label: {
            HStack(spacing: 2) {
                Text(label)
                if sortKey == key {
                    Image(systemName: sortDescending ? "chevron.down" : "chevron.up").font(.caption2)
                }
            }
            .foregroundStyle(sortKey == key ? Theme.gold : Theme.textFaint)
        }
        .buttonStyle(.plain)
    }

    private func statText(_ v: Double?, _ key: String) -> String {
        guard let v else { return "" }
        if key == "RATIO" { return String(format: "%.2f", v) }
        if key == "WEIGHT" { return String(format: "%.1f", v) }
        if gearPercentStatKeys.contains(key) { return "\(Int(v))%" }
        return "\(Int(v))"
    }

    private func row(_ r: ScaledRow, showOwned: Bool, looted: Set<String>) -> some View {
        let own = store.ownership[r.row.key]
        let wished = wishes.has(r.row.key)
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                if let img = GameData.shared.itemIcon(r.row.iconId) {
                    Image(nsImage: img).resizable().frame(width: 18, height: 18)
                }
                Button { opened = r.row } label: {
                    Text(r.row.name).foregroundStyle(Color(hex: 0x6fbf7f)).lineLimit(1)
                }
                .buttonStyle(.plain)
                if r.row.era == .outOfEra { Chip(text: "out of era", color: Theme.orange) }
                else if r.row.era == .unknown { Chip(text: "era?", color: Theme.textFaint) }
                Spacer(minLength: 4)
                Button {
                    if wished { wishes.remove(r.row.key) }
                    else { wishes.add(WishEntry(itemKey: r.row.key, name: r.row.name, kind: "gear",
                                                addedAt: nowMs(), source: "user")) }
                } label: {
                    Text(wished ? "ON WISH LIST" : "ADD TO WISH LIST")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(wished ? Theme.green : Theme.gold)
                }
                .buttonStyle(.plain)
                .help(wished ? "Remove from the wish list. It comes off the route with it."
                             : "Add to the wish list, where it joins the route grouped by where it drops.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(r.row.slots.joined(separator: " ")).foregroundStyle(Theme.textDim)
                .frame(width: 96, alignment: .leading).lineLimit(1)
            Text(classText(r.row.classes)).foregroundStyle(Theme.textDim)
                .frame(width: 90, alignment: .leading).lineLimit(1)
                .help(r.row.classes.joined(separator: " "))
            ForEach(numericColumns, id: \.self) { c in
                Text(statText(value(r, c), c)).foregroundStyle(Theme.text).monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            if showOwned {
                Text({ let t = own?.cellText ?? ""
                       return t.isEmpty && looted.contains(r.row.key) ? "Looted" : t }())
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 130, alignment: .leading).lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func classText(_ c: [String]) -> String {
        if c.isEmpty { return "" }
        if c.count >= classAbbrs.count { return "ALL" }
        return c.joined(separator: " ")
    }
}
