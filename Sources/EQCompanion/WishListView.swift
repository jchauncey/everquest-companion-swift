// The wish list as a ROUTE: what you are still trying to get, grouped by where it drops, with what
// you already own crossed off.
//
// THE COUNTS ARE TWO DIFFERENT QUESTIONS AND ARE COUNTED DIFFERENTLY ON PURPOSE. The header's
// `N wishes` is the WHOLE document — dismissed rows, fulfilled rows and all — because it answers
// "how long is my list". `N still to find` is what is left after dismissals and the search box but
// BEFORE the era filter, because a wish you cannot reach tonight is still a wish; the era filter
// then says separately how many it is hiding.
import SwiftUI
import EQCompanionCore

struct WishListView: View {
    @Environment(AppModel.self) private var model
    @State private var wishes = WishListStore.shared
    @State private var index = GearIndex.shared
    @State private var store = InventoryStore.shared
    @State private var query = ""
    @State private var eraOnly = true
    @State private var adding = false
    @State private var addQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            if wishes.list.entries.isEmpty {
                empty("Nothing on your wish list yet. Add an item or an exaltation effect and this becomes a route: where it drops, who camps it, and what is left to merge.")
            } else if kept.isEmpty && !wanted.isEmpty {
                empty("Every wish still to find is out of \(currentEraLabel).")
            } else if kept.isEmpty {
                empty(query.isEmpty ? "Nothing left to find." : "No wish on your list matches that.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.zone) { group in
                            Card(group.zone.uppercased(), trailing: AnyView(
                                Text("\(group.rows.count) \(group.rows.count == 1 ? "wish" : "wishes")")
                                    .font(.caption).foregroundStyle(Theme.textFaint))) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(group.rows) { wishRow($0) }
                                }
                            }
                        }
                        if !done.isEmpty { doneStrip }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .onAppear { index.start(); wishes.bind(character: model.attached) }
        .task(id: "inv|\(model.moduleSeqs["outputFiles"] ?? 0)|\(model.epoch ?? 0)") {
            await store.refresh(model, seq: model.moduleSeqs["outputFiles"] ?? 0)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("+ ADD A WISH") { adding = true }
                .buttonStyle(OutlineButtonStyle())
                .popover(isPresented: $adding, arrowEdge: .bottom) { addPopover }
            TextField("Search your wishes", text: $query)
                .textFieldStyle(.roundedBorder).frame(width: 200)
            Button { eraOnly.toggle() } label: {
                Chip(text: "Current era", color: eraOnly ? Theme.gold : Theme.textDim, filled: eraOnly)
            }
            .buttonStyle(.plain)
            .help("Hide wishes whose only known sources are outside \(currentEraLabel).")
            Spacer(minLength: 0)
            let n = wishes.list.entries.count
            Text("\(n) \(n == 1 ? "wish" : "wishes")").font(.caption).foregroundStyle(Theme.textDim)
            Text("/").font(.caption).foregroundStyle(Theme.textFaint)
            Text("\(wanted.count) still to find").font(.caption).foregroundStyle(Theme.textDim)
            if hidden > 0 {
                Text("\u{00b7} \(hidden) out of era, hidden").font(.caption).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "heart").font(.title).foregroundStyle(Theme.textFaint)
            Text(text).font(.callout).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - The fold

    /// One wish, joined to what the corpus and the dump know about it.
    private struct Resolved: Identifiable {
        var entry: WishEntry
        var row: GearRow?
        var id: String { entry.itemKey }
        var era: EraVerdict { row?.era ?? .unknown }
    }

    private var resolved: [Resolved] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return wishes.list.entries.compactMap { e in
            if wishes.list.clearedDone.contains(e.itemKey) { return nil }
            if !needle.isEmpty && !"\(e.name) \(e.effect ?? "")".lowercased().contains(needle) { return nil }
            return Resolved(entry: e, row: index.corpus.byKey[e.itemKey])
        }
    }

    /// A gear wish is fulfilled when the dump names a copy; a donor wish when you hold the donor.
    private func fulfilled(_ r: Resolved) -> Bool {
        let own = store.ownership[r.entry.itemKey]
        return (own?.owned ?? false) || (own?.exaltations ?? 0) > 0
    }

    private var wanted: [Resolved] { resolved.filter { !fulfilled($0) } }
    private var done: [Resolved] { resolved.filter { fulfilled($0) } }
    private var kept: [Resolved] { wanted.filter { !eraOnly || $0.era == .inEra } }
    private var hidden: Int { wanted.count - kept.count }

    /// Grouped by where it drops. The non-zone headings always come after the zones — they are
    /// answers to "there is no camp for this", not camps.
    private var groups: [(zone: String, rows: [Resolved])] {
        var byZone: [String: [Resolved]] = [:]
        for r in kept {
            let zone = r.row?.drops.first?.zone
            let heading: String
            if let zone, !zone.isEmpty { heading = zone }
            else if r.row?.quest == true { heading = "Quests" }
            else if r.row?.playerCrafted == true { heading = "Crafted" }
            else { heading = "No known source" }
            byZone[heading, default: []].append(r)
        }
        let tail: Set<String> = ["Quests", "Crafted", "Zone unstated", "No known source"]
        let zones = byZone.keys.filter { !tail.contains($0) }.sorted()
        let rest = byZone.keys.filter { tail.contains($0) }.sorted()
        return (zones + rest).map { ($0, byZone[$0] ?? []) }
    }

    // MARK: - Rows

    private func wishRow(_ r: Resolved) -> some View {
        let own = store.ownership[r.entry.itemKey]
        return HStack(spacing: 8) {
            if let img = GameData.shared.itemIcon(r.row?.iconId) {
                Image(nsImage: img).resizable().frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(r.entry.name).font(.callout).foregroundStyle(Color(hex: 0x6fbf7f))
                Text(r.entry.effect ?? "gear").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            Spacer(minLength: 8)
            // Where it drops. The wiki names the mob; the level is not in this corpus, so the row
            // says the mob and how many other droppers there are, and nothing it cannot state.
            Text(dropText(r)).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
            if let socket = r.entry.socket, let tier = r.entry.socket.map({ extractionTier($0) }) {
                let cost = extractionCost(tier)
                Chip(text: "needs +\(tier) \u{00b7} \u{2248}\(cost.d0) D0 merges", color: Theme.purple)
                    .help("A \(socketLabels[socket] ?? socket) effect extracts once the donor is merged to +\(tier).")
            }
            if r.era == .outOfEra { Chip(text: "out of era", color: Theme.orange) }
            else if r.era == .unknown { Chip(text: "era?", color: Theme.textFaint) }
            if let own, own.owned { Chip(text: own.cellText, color: Theme.green) }
            else { Chip(text: "still to find", color: Theme.textFaint) }
            Button { wishes.remove(r.entry.itemKey) } label: {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
            .help("Remove from your wish list")
        }
    }

    private func dropText(_ r: Resolved) -> String {
        guard let drops = r.row?.drops, let first = drops.first else {
            if r.row?.quest == true { return "quest reward" }
            if r.row?.playerCrafted == true { return "player crafted" }
            return "no known source"
        }
        let zone = first.zone.isEmpty ? "zone unstated" : first.zone
        let more = drops.count > 1 ? " +\(drops.count - 1) more" : ""
        return "\(first.mob) - \(zone)\(more)"
    }

    private var doneStrip: some View {
        Card("GOT IT", trailing: AnyView(
            Button("CLEAR") { wishes.clearDone(done.map(\.entry.itemKey)) }
                .buttonStyle(OutlineButtonStyle())
                .help("Stop showing these. They stay on your list; nothing is deleted."))) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(done) { r in
                    HStack {
                        Text(r.entry.name).font(.caption).foregroundStyle(Theme.textDim)
                        Spacer()
                        Text(store.ownership[r.entry.itemKey]?.cellText ?? "")
                            .font(.caption2).foregroundStyle(Theme.green)
                    }
                }
                Text("\(done.count) \(done.count == 1 ? "wish" : "wishes") fulfilled")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
    }

    // MARK: - Adding

    private var addPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search every item and effect", text: $addQuery)
                .textFieldStyle(.roundedBorder).frame(width: 320)
            let needle = addQuery.trimmingCharacters(in: .whitespaces).lowercased()
            if needle.count < 2 {
                Text("Type at least two letters to search every item and effect.")
                    .font(.caption).foregroundStyle(Theme.textFaint)
            } else if !index.ready {
                Text("Reading the item database\u{2026}").font(.caption).foregroundStyle(Theme.textFaint)
            } else {
                // Ranked the way the Electron picker ranks: a name that STARTS with what you typed
                // before one that merely contains it, before an effect-only match.
                let hits = index.rows
                    .filter { $0.searchKey.contains(needle) }
                    .sorted { a, b in
                        func rank(_ r: GearRow) -> Int {
                            let n = r.name.lowercased()
                            if n.hasPrefix(needle) { return 0 }
                            if n.contains(needle) { return 1 }
                            return 2
                        }
                        if rank(a) != rank(b) { return rank(a) < rank(b) }
                        if a.name.count != b.name.count { return a.name.count < b.name.count }
                        return a.name < b.name
                    }
                    .prefix(40)
                if hits.isEmpty {
                    Text("Nothing in the item database matches that.")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(hits)) { row in
                                let already = wishes.has(row.key)
                                Button {
                                    wishes.add(WishEntry(itemKey: row.key, name: row.name, kind: "gear",
                                                         addedAt: nowMs(), source: "user"))
                                } label: {
                                    HStack {
                                        Text(row.name).font(.caption).foregroundStyle(Theme.text)
                                        if already { Chip(text: "wished", color: Theme.green) }
                                        Spacer()
                                        Text(row.slots.joined(separator: " "))
                                            .font(.caption2).foregroundStyle(Theme.textFaint)
                                    }
                                    .opacity(already ? 0.55 : 1)
                                }
                                .buttonStyle(.plain)
                                .disabled(already)
                            }
                        }
                    }
                    .frame(width: 320, height: 260)
                }
            }
        }
        .padding(10)
        .background(Theme.paper)
    }
}
