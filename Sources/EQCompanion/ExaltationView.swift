// The exaltation planner's browser: every effect this app can read off an item page, grouped by
// effect, with the donors that carry it underneath.
//
// A DONOR ROW IS ONE (item, effect, socket). The corpus spells a proc `Combat Effect:`, so the
// segmented control's PROC tab reads `kind: combat` — a planner filtering on the word `proc` would
// show an empty tab. A bare `Effect:` line named no socket and is not here at all: the wiki did not
// say which socket it occupies, and guessing one would put an unextractable effect on a farm list.
//
// R1 IS THE ONLY ARITHMETIC ON THIS SURFACE: focus extracts at +1, click at +2, worn at +3, proc at
// +4, and the chip says so on every row rather than in a legend somebody has to go and find.
import SwiftUI
import EQCompanionCore

struct ExaltationView: View {
    @Environment(AppModel.self) private var model
    @State private var index = GearIndex.shared
    @State private var wishes = WishListStore.shared
    @State private var combo = ModuleSnapshot()

    @State private var socket = "proc"
    @State private var query = ""
    @State private var slot = "ALL"
    @State private var classes: Set<String> = []
    @State private var classesPinned = false
    @State private var trioOnly = true
    @State private var eraOnly = true
    @State private var nonEquip = false
    @State private var open: Set<String> = []

    private var detectedClasses: [String] {
        (combo.state["current"]["slots"].array ?? []).compactMap { s in
            let c = (s["candidates"].array ?? []).compactMap(\.string)
            return c.count == 1 ? c[0] : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            classRow
            filterRow
            if !index.ready {
                Spacer()
                Text("Reading the item database\u{2026}").font(.callout).foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if groups.isEmpty {
                Spacer()
                Text(emptyText).font(.callout).foregroundStyle(Theme.textDim)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                list
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear { index.start(); wishes.bind(character: model.attached) }
        .task(id: "combo|\(model.moduleSeqs["combo"] ?? 0)|\(model.epoch ?? 0)") {
            await combo.refresh(model, module: "combo")
            if !classesPinned { classes = Set(detectedClasses) }
        }
    }

    private var classRow: some View {
        HStack(spacing: 6) {
            Text("Classes").font(.caption).foregroundStyle(Theme.textDim)
            ForEach(classAbbrs, id: \.self) { c in
                Button {
                    classesPinned = true
                    if classes.contains(c) { classes.remove(c) } else { classes.insert(c) }
                } label: {
                    Chip(text: c, color: classes.contains(c) ? Theme.gold : Theme.textFaint,
                         filled: classes.contains(c))
                }
                .buttonStyle(.plain)
            }
            if !classes.isEmpty {
                Button("CLEAR") { classes = []; classesPinned = true }.buttonStyle(OutlineButtonStyle())
            }
            Spacer(minLength: 0)
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            SegmentPicker(selection: $socket, options: [
                ("proc", "PROC"), ("worn", "WORN"), ("focus", "FOCUS"), ("click", "CLICK")
            ])
            TextField("Search effect or item", text: $query)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            Picker("", selection: $slot) {
                Text("All slots").tag("ALL")
                ForEach(equipSlots, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            Text("Group by: Effect").font(.caption).foregroundStyle(Theme.textFaint)
            chip("Usable by these classes", $trioOnly,
                 "Hide donors none of the classes in the filter can use")
            chip("Current era", $eraOnly, "Hide donors from outside \(currentEraLabel)")
            chip("Non-equippable", $nonEquip, "Show items whose page states no equipment slot")
            Spacer(minLength: 0)
        }
    }

    private func chip(_ label: String, _ on: Binding<Bool>, _ help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Chip(text: label, color: on.wrappedValue ? Theme.gold : Theme.textDim, filled: on.wrappedValue)
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: - The fold

    private var filtered: [DonorRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return index.donors.filter { d in
            if !nonEquip && d.slots.isEmpty { return false }
            if d.socket != socket { return false }
            if slot != "ALL" && !d.slots.contains(slot) { return false }
            // A donor whose page states NO class list is kept: `[]` means the wiki declined to
            // say, and hiding it would be an assertion nobody made.
            if trioOnly && !classes.isEmpty && !d.classes.isEmpty
                && !d.classes.contains(where: { classes.contains($0) }) { return false }
            if eraOnly && d.era != .inEra { return false }
            if !needle.isEmpty && !d.searchKey.contains(needle) { return false }
            return true
        }
    }

    /// Group by: Effect. The key is the effect name VERBATIM — no normalization, because two
    /// spellings the wiki keeps apart are two effects until somebody measures otherwise. Groups run
    /// by donor count descending, then by name.
    private var groups: [(effect: String, rows: [DonorRow])] {
        var byEffect: [String: [DonorRow]] = [:]
        for d in filtered { byEffect[d.effect, default: []].append(d) }
        return byEffect.map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.rows.count != $1.rows.count ? $0.rows.count > $1.rows.count : $0.effect < $1.effect }
    }

    private var emptyText: String {
        let head = "No effects match these filters"
        var parts: [String] = []
        let bySocket = index.donors.filter { $0.socket == socket }
        let outOfEra = bySocket.filter { $0.era != .inEra }.count
        let slotless = bySocket.filter { $0.slots.isEmpty }.count
        if eraOnly && outOfEra > 0 { parts.append("\(outOfEra) outside \(currentEraLabel)") }
        if !nonEquip && slotless > 0 { parts.append("\(slotless) with no equipment slot") }
        if parts.isEmpty { return head + "." }
        return "\(head) - but \(parts.joined(separator: " and ")) are hidden by the toggles above."
    }

    // MARK: - The list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(groups.prefix(300), id: \.effect) { group in
                    header(group)
                    if open.contains(group.effect) {
                        ForEach(group.rows) { donorRow($0) }
                    }
                    Divider().overlay(Theme.border.opacity(0.5))
                }
            }
        }
    }

    private func header(_ group: (effect: String, rows: [DonorRow])) -> some View {
        Button {
            if open.contains(group.effect) { open.remove(group.effect) } else { open.insert(group.effect) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: open.contains(group.effect) ? "chevron.down" : "chevron.right")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
                Text(group.effect).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                Chip(text: socketLabels[socket] ?? socket, color: Theme.blue)
                Chip(text: "+\(extractionTier(socket)) to extract", color: Theme.textDim)
                if group.rows.contains(where: \.hasteLocked) {
                    Chip(text: "haste - can't move", color: Theme.orange)
                        .help("Haste never travels as an exaltation.")
                }
                Spacer(minLength: 0)
                Text("\(group.rows.count) \(group.rows.count == 1 ? "donor" : "donors")")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func donorRow(_ d: DonorRow) -> some View {
        let wished = wishes.has(d.key)
        return HStack(spacing: 8) {
            if let img = GameData.shared.itemIcon(d.iconId) {
                Image(nsImage: img).resizable().frame(width: 18, height: 18)
            }
            Text(d.name).font(.caption).foregroundStyle(Color(hex: 0x6fbf7f))
            ForEach(d.slots, id: \.self) { Chip(text: $0, color: Theme.textFaint) }
            if d.slots.isEmpty { Chip(text: "no slot", color: Theme.textFaint) }
            if d.classes.isEmpty { Chip(text: "class unknown", color: Theme.textFaint) }
            Chip(text: "+\(d.tierRequired) to extract", color: Theme.textDim)
                .help("This effect only extracts once the donor is merged to +\(d.tierRequired).")
            if d.hasteLocked { Chip(text: "haste - can't move", color: Theme.orange) }
            if d.era == .outOfEra { Chip(text: "out of era", color: Theme.orange) }
            else if d.era == .unknown { Chip(text: "era?", color: Theme.textFaint) }
            Spacer(minLength: 8)
            Text(sourceText(d)).font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(1)
            Button {
                if wished { wishes.remove(d.key) }
                else {
                    wishes.add(WishEntry(itemKey: d.key, name: d.name, kind: "donor",
                                         effect: d.effect, socket: d.socket,
                                         addedAt: nowMs(), source: "user"))
                }
            } label: {
                Text(wished ? "ON WISH LIST" : "ADD TO WISH LIST")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(wished ? Theme.green : Theme.gold)
            }
            .buttonStyle(.plain)
            .disabled(d.slots.isEmpty)
        }
        .padding(.leading, 26)
        .padding(.vertical, 2)
    }

    private func sourceText(_ d: DonorRow) -> String {
        guard let first = d.drops.first else {
            if d.quest { return "quest reward" }
            if d.playerCrafted { return "player crafted" }
            return "no known source"
        }
        let zone = first.zone.isEmpty ? "zone unstated" : first.zone
        let more = d.drops.count > 1 ? " +\(d.drops.count - 1) more" : ""
        return "\(first.mob) - \(zone)\(more)"
    }
}
