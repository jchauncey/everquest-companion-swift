// The six panes of the Plane of Sky tab. Ports of `PoskyView.tsx`, `QuestFilterBar.tsx`,
// `QuestList.tsx`, `TargetsView.tsx`, `CleanupList.tsx`, `ClassUnlockList.tsx`, `IgnoredList.tsx`.
import SwiftUI
import EQCompanionCore

let SKY_QUEST_PAGE = 40

// MARK: - Quests

struct SkyQuestsPane: View {
    @Bindable var store: SkyStore
    @State private var shown = SKY_QUEST_PAGE

    private var list: [SkyQuestProgress] { store.filtered }

    /// Every narrowing the page cap should reset for — a new selection is a new list, and carrying
    /// a cap from the old one would silently hide rows the user just asked to see.
    private var selectionKey: String {
        "\(store.selectedClasses)|\(store.islands)|\(store.bosses)|\(store.query)|\(store.sort.rawValue)|\(store.hideCompleted)\(store.hideTurnedIn)\(store.hideNoItems)\(store.favoritesOnly)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SkyFilterBar(store: store)
            countsLine
            if store.visible.isEmpty {
                Text(store.quests.isEmpty
                     ? "No Plane of Sky data available."
                     : "Every quest is ignored - the Ignored tab can bring them back.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(list.prefix(shown)) { q in SkyQuestCard(store: store, q: q) }
                    if list.count > shown {
                        HStack(spacing: 8) {
                            Button("Show more (\(list.count - shown) more)") { shown += SKY_QUEST_PAGE }
                                .buttonStyle(OutlineButtonStyle())
                            Button("Show all (\(list.count))") { shown = list.count }
                                .buttonStyle(OutlineButtonStyle())
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .onChange(of: selectionKey) { shown = SKY_QUEST_PAGE }
        }
    }

    private var countsLine: some View {
        Text("\(list.count) of \(store.visible.count) quests · counting from \(store.countSource.phrase)")
            .font(.caption).foregroundStyle(Theme.textDim)
    }
}

struct SkyFilterBar: View {
    @Bindable var store: SkyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SkyMultiSelect(label: "Filter by class", placeholder: "All classes",
                               options: store.classNames, selection: $store.selectedClasses)
                SkyMultiSelect(label: "Filter by island", placeholder: "All islands",
                               options: store.facets.islands, selection: $store.islands)
                SkyMultiSelect(label: "Filter by boss", placeholder: "All bosses",
                               options: store.facets.bosses, selection: $store.bosses)
                TextField("Search quest / item / reward / boss / island", text: $store.query)
                    .textFieldStyle(.roundedBorder).frame(minWidth: 260, maxWidth: 320).font(.caption)
                Picker("Sort", selection: $store.sort) {
                    ForEach(SkySort.allCases) { s in Text(s.label).tag(s) }
                }
                .pickerStyle(.menu).frame(width: 220).font(.caption)
                Spacer(minLength: 0)
            }
            HStack(spacing: 14) {
                SkyCheck(label: "Hide quests I have every item for",
                         help: "Hide quests you already hold every item for. A quest you turn in comes back at zero, because handing it in spends the items, so it stays on this list until you have gathered them again.",
                         on: $store.hideCompleted)
                SkyCheck(label: "Hide quests I have turned in",
                         help: "Hide quests you have handed in at least once, even the ones you are farming again.",
                         on: $store.hideTurnedIn)
                SkyCheck(label: "Only quests with turn-ins", on: $store.hideNoItems)
                SkyCheck(label: "Favorites only", on: $store.favoritesOnly)
                Spacer(minLength: 0)
                SkyInventorySource(store: store)
            }
        }
    }
}

// MARK: - Ready

struct SkyReadyPane: View {
    @Bindable var store: SkyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SkyCheck(label: "Only quests I have never turned in", on: $store.readyFirstTimeOnly)
                Spacer()
                SkyInventorySource(store: store)
            }
            let ready = store.ready
            if ready.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(countText(ready.count)).font(.caption).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView { LazyVStack(spacing: 6) { ForEach(ready) { SkyQuestCard(store: store, q: $0) } } }
            }
        }
    }

    private var runeNote: String { store.countSource.readsInventory ? " " + SkyNotes.dumpBlindReady : "" }

    private var emptyText: String {
        let n = store.readyRefarmCount
        var s = "Nothing is ready to turn in - a quest lands here the moment you are holding every item it needs, and leaves when you hand them over."
        if store.readyFirstTimeOnly, n > 0 {
            s += " \(n) you have run before \(n == 1 ? "is" : "are") ready now - untick the box to see \(n == 1 ? "it" : "them")."
        }
        return s + runeNote
    }

    private func countText(_ n: Int) -> String {
        var s = "\(n) quest\(n == 1 ? "" : "s") you are holding every item for"
        if store.readyFirstTimeOnly { s += " and have never turned in" }
        s += "."
        let refarm = store.readyRefarmCount
        if store.readyFirstTimeOnly, refarm > 0 {
            s += " \(refarm) more you have run before \(refarm == 1 ? "is" : "are") ready too."
        }
        s += " Holding something you no longer have? Expand the quest and correct the count beside the item."
        return s + runeNote
    }
}

// MARK: - Targets

struct SkyTargetsPane: View {
    @Bindable var store: SkyStore

    var body: some View {
        let model = store.targets
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SkyCheck(label: "Only quests I have never turned in", on: $store.targetsFirstTimeOnly)
                Spacer()
                SkyInventorySource(store: store)
            }
            if model.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(countText(model.mobs.count)).font(.caption).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(skyGroupTargetsByIsland(model.mobs)) { g in
                            islandSection(g)
                        }
                        remainder("Random drops - any Plane of Sky mob can drop these", model.randomDrop)
                        remainder("No known source - the drop data does not say who carries these", model.unsourced)
                    }
                }
            }
        }
    }

    private func islandSection(_ g: SkyTargetIslandGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(g.island ?? "Island not stated - the drop data does not say where these are")
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
            ForEach(g.mobs) { t in targetRow(t) }
        }
    }

    private func targetRow(_ t: SkyTargetMob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(t.mob.name).font(.callout.weight(.semibold)).help(t.mob.facts)
                if t.islands.count > 1 {
                    Text(skyIslandLabel(t.islands)).font(.caption2).foregroundStyle(Theme.textDim)
                }
                Spacer()
                Chip(text: "\(t.covers) item\(t.covers == 1 ? "" : "s")")
            }
            ForEach(t.items) { neededLine($0) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func neededLine(_ it: SkyNeededItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(it.shortfall)x").font(.caption).monospacedDigit().foregroundStyle(Theme.textDim)
            Text(it.name).font(.caption.weight(.semibold))
            Text("- " + questsLabel(it)).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
        }
    }

    /// The quests that want it, or a count when there are too many to read at a glance.
    private func questsLabel(_ it: SkyNeededItem) -> String {
        if it.quests.count > 4 { return "(\(it.quests.count) quests)" }
        return it.quests.map { $0.need > 1 ? "\($0.questName) x\($0.need)" : $0.questName }.joined(separator: ", ")
    }

    @ViewBuilder private func remainder(_ title: String, _ items: [SkyNeededItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                ForEach(items) { neededLine($0) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
    }

    private var behindTheBox: String {
        let n = store.targetsRefarmCount
        guard store.targetsFirstTimeOnly, n > 0 else { return "" }
        return " \(n) quest\(n == 1 ? "" : "s") you have run before still want\(n == 1 ? "s" : "") items - untick the box to hunt for \(n == 1 ? "it" : "them") too."
    }

    private var emptyText: String {
        "Nothing left to hunt - every quest you are tracking is ignored, holding everything it needs, or \(store.targetsFirstTimeOnly ? "already turned in" : "wanting nothing")." + behindTheBox
    }

    private func countText(_ n: Int) -> String {
        (n == 0
         ? "No kill targets right now - what is left is below."
         : "\(n) mob\(n == 1 ? "" : "s") still worth killing - island by island, and inside an island the ones that close the most of what is left come first.")
        + behindTheBox
    }
}

// MARK: - Cleanup

struct SkyCleanupPane: View {
    @Bindable var store: SkyStore

    var body: some View {
        let rows = store.cleanupRows
        VStack(alignment: .leading, spacing: 8) {
            Text(SKY_CLEANUP_CAVEAT)
                .font(.caption).foregroundStyle(Theme.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.orange.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.orange.opacity(0.4)))
            HStack { Spacer(); SkyInventorySource(store: store) }
            if rows.isEmpty {
                Text("Nothing here to destroy - every Sky item you are holding is still wanted by a quest you have not turned in.")
                    .font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\(rows.count) item\(rows.count == 1 ? "" : "s") no un-turned-in quest still needs.")
                    .font(.caption).foregroundStyle(Theme.textDim)
                ScrollView { LazyVStack(alignment: .leading, spacing: 8) { ForEach(rows) { row($0) } } }
            }
        }
    }

    private func row(_ r: SkyCleanupRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(r.name).font(.callout.weight(.semibold))
                Text("x\(r.quantity)").font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
            }
            ForEach(r.turnIns) { t in
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(t.heading) · \(t.timesLine)\(t.reward.map { " · reward: \($0)" } ?? "")")
                        .font(.caption).foregroundStyle(Theme.textDim)
                    Text(t.decisionLine + (t.setsLine.map { ", \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(t.keep ? Theme.orange : Theme.textDim)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

// MARK: - Classes

struct SkyClassesPane: View {
    @Bindable var store: SkyStore

    var body: some View {
        let rows = store.classRows
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("No Plane of Sky data available, so there are no classes to track.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            } else {
                Text(note(rows)).font(.caption).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView { LazyVStack(spacing: 2) { ForEach(rows) { row($0) } } }
            }
        }
    }

    private func note(_ rows: [SkyClassUnlockRow]) -> String {
        let observed = rows.filter { $0.source == .observed }.count
        let derived = rows.filter { $0.source == .derived }.count
        return "Fewest tests left first. Click a class to see its quests. Star a class to pin it to the top. \(observed) unlocked by a line in your log, \(derived) read from a complete set of turn-ins. Turning in a Sky test prints nothing about unlocking, so a complete set is our reading and not the game saying so; a class can also unlock at level 11 or from a token, which is why a logged unlock outranks the count."
    }

    private func row(_ r: SkyClassUnlockRow) -> some View {
        HStack(spacing: 12) {
            SkyStarButton(starred: store.classFavorites.contains(r.className),
                          help: "Pin \(r.className) to the top") { store.toggleClassFavorite(r.className) }
            Text(r.className).font(.callout.weight(.semibold)).frame(width: 130, alignment: .leading)
            Text("\(r.turnedIn) of \(r.total)").font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 64, alignment: .leading).monospacedDigit()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.paperRaised).frame(height: 6)
                    Capsule().fill(r.unlocked ? Theme.green : Theme.gold)
                        .frame(width: geo.size.width * (r.total == 0 ? 0 : Double(r.turnedIn) / Double(r.total)), height: 6)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
            Chip(text: r.label, color: r.unlocked ? Theme.green : Theme.textDim, filled: r.unlocked)
                .frame(width: 190, alignment: .trailing)
                .help(r.unlockedAt.map { "Your log said so at \(Format.stamp(ms: $0))" } ?? "")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { store.showClassQuests(r.className) }
    }
}

// MARK: - Ignored

struct SkyIgnoredPane: View {
    @Bindable var store: SkyStore

    var body: some View {
        let rows = store.ignored
        VStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("No ignored quests - hide one with the eye icon on its row and it lands here.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            } else {
                Text("\(rows.count) quest\(rows.count == 1 ? "" : "s") hidden from the list, filters and counts.")
                    .font(.caption).foregroundStyle(Theme.textDim)
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { q in
                            HStack(spacing: 12) {
                                SkyIgnoreButton(ignored: true) { store.toggleQuestIgnored(q.key) }
                                Chip(text: q.className, color: Theme.purple).frame(width: 92, alignment: .leading)
                                Text(q.name).font(.callout.weight(.semibold)).frame(width: 220, alignment: .leading)
                                if let r = q.reward { Text("→ \(r)").font(.caption).foregroundStyle(Theme.gold) }
                                Spacer()
                                SkyTurnInBadge(q: q)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }
}
