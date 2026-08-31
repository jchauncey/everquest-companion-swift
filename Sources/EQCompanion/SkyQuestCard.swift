// One quest's row: the summary line, the item chips under it, and the table the chevron reveals.
// A port of `features/posky/QuestAccordion.tsx` + `QuestItemsTable.tsx` + `ItemOverrides.tsx`.
import SwiftUI
import EQCompanionCore

struct SkyQuestCard: View {
    @Bindable var store: SkyStore
    var q: SkyQuestProgress
    @State private var expanded = false

    private var shared: [SkySharedItem] { store.sharedItems[q.key] ?? [] }
    /// A caption about what is LEFT: the mobs still standing between this quest and its turn-in.
    private var killTargets: [SkyKillTarget] { q.missing.isEmpty ? [] : skyQuestKillTargets(q.items) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            chips
            if expanded { details }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    // MARK: Summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(spacing: 2) {
                SkyStarButton(starred: store.isQuestFavorite(q.key),
                              help: "Pin this quest to the top of the list") { store.toggleQuestFavorite(q.key) }
                SkyIgnoreButton(ignored: false) { store.toggleQuestIgnored(q.key) }
            }
            .padding(.top, 2)
            Chip(text: q.className, color: Theme.purple).frame(width: 92, alignment: .leading)
            titles
            Spacer(minLength: 8)
            trailing
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(q.name).font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
            if let reward = q.reward {
                Text("→ \(reward)").font(.caption).foregroundStyle(Theme.gold)
                    .help(q.rewardStats ?? "")
            }
            if let giver = q.giver {
                Text("Turn in → \(giver)").font(.caption).foregroundStyle(Theme.textDim)
            }
            if !killTargets.isEmpty {
                Text(skyKillTargetLabel(killTargets)).font(.caption).foregroundStyle(Theme.textDim)
                    .help(killTargets.map(\.facts).joined(separator: "\n"))
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if !shared.isEmpty {
                Chip(text: "\(shared.count) shared", color: Theme.blue)
                    .help("Shares \(shared.count) item\(shared.count == 1 ? "" : "s") with other Sky quests - expand for details")
            }
            SkyTurnInBadge(q: q)
            // Both, always: the badge is history, the pill beside it is the present. Collapsing them
            // into one is what used to make a re-run invisible.
            Chip(text: q.missing.isEmpty ? "Ready to turn in" : "\(q.missing.count) of \(q.items.count) missing",
                 color: q.missing.isEmpty ? Theme.green : Theme.textDim)
            SkyProgressBar(have: q.haveCount, need: q.needCount, ratio: q.ratio)
            Button { expanded.toggle() } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
        }
    }

    private var chips: some View {
        FlowRow(spacing: 4, lineSpacing: 4) {
            ForEach(q.items.sorted { store.isItemFavorite($0.name) && !store.isItemFavorite($1.name) }) { it in
                itemChip(it)
            }
        }
        .padding(.leading, 164)
    }

    private func itemChip(_ it: SkyItemProgress) -> some View {
        let fav = store.isItemFavorite(it.name)
        let color = fav ? Theme.orange : (it.done ? Theme.green : Theme.textDim)
        return Button { store.toggleItemFavorite(it.name) } label: {
            HStack(spacing: 4) {
                Image(systemName: fav ? "star.fill" : (it.done ? "checkmark.circle.fill" : "circle"))
                    .font(.system(size: 9))
                Text(it.need > 1 ? "\(it.name) \(it.have)/\(it.need)" : it.name).font(.caption2)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.6)))
            .opacity(it.done && !fav ? 0.65 : 1)
        }
        .buttonStyle(.plain)
        .help(it.stats ?? it.name)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Theme.border)
            toolbar
            if let stats = q.rewardStats {
                Text(stats).font(.caption.monospaced()).foregroundStyle(Theme.textDim).textSelection(.enabled)
            }
            if !shared.isEmpty { sharedSection }
            itemsTable
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if let rune = q.rune { Chip(text: "Rune: \(rune)") }
            if let giver = q.giver { Chip(text: "Giver: \(giver)") }
            Spacer()
            Text(q.turnIns > 0 ? SkyTurnIns.badgeLabel(q.turnIns) : "Not turned in yet")
                .font(.caption2).foregroundStyle(Theme.textDim)
            Button { store.undoTurnIn(q.key) } label: { Image(systemName: "minus") }
                .buttonStyle(.plain).font(.caption)
                .disabled(q.evidence != nil || q.turnIns <= q.logTurnIns)
                .help(undoHelp)
            Button { store.recordTurnIn(q.key) } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).font(.caption)
                .help("Record another turn-in. The items it required are subtracted, so the quest goes back to what you hold toward running it again.")
        }
    }

    private var undoHelp: String {
        if q.evidence != nil { return "This count comes from the reward in your inventory export, so it cannot be taken back here" }
        if q.turnIns == 0 { return "Nothing to take back" }
        if q.turnIns <= q.logTurnIns { return "This count comes from your log, so it cannot be taken back here" }
        return "Take back the most recent turn-in you recorded by hand"
    }

    private var sharedSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Shared items - other Sky quests contending for these drops")
                .font(.caption2).foregroundStyle(Theme.textDim)
            ForEach(shared) { si in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(si.name).font(.caption.weight(.semibold)).frame(width: 150, alignment: .leading)
                    FlowRow(spacing: 4, lineSpacing: 4) {
                        ForEach(si.quests) { sq in
                            Button { store.revealQuest(sq.name) } label: {
                                Chip(text: store.ambiguousNames.contains(sq.name) ? "\(sq.className) · \(sq.name)" : sq.name,
                                     color: Theme.blue)
                            }
                            .buttonStyle(.plain)
                            .help(sq.reward.map { "Reward for \(sq.className) · \(sq.name): \($0)" } ?? "")
                        }
                    }
                }
            }
        }
    }

    private var itemsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Item"); Text("Have"); Text("Dropped by"); Text("Where")
            }
            .font(.caption2.weight(.semibold)).foregroundStyle(Theme.textFaint)
            ForEach(q.items) { it in
                GridRow {
                    Text(it.name).font(.caption).foregroundStyle(it.done ? Theme.green : Theme.text)
                        .help(it.stats ?? it.name)
                    SkyHaveCell(store: store, it: it)
                    Text(dropperLabel(it)).font(.caption).foregroundStyle(Theme.textDim)
                        .help(it.droppers.map(\.facts).joined(separator: "\n"))
                    Text(it.place).font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        }
    }

    /// The first three droppers, then `+N more`; when the catalog knows none, posky's own `who`
    /// wording stands in rather than an empty cell.
    private func dropperLabel(_ it: SkyItemProgress) -> String {
        if it.droppers.isEmpty { return it.who.joined(separator: ", ") }
        let shown = it.droppers.prefix(3).map(\.name).joined(separator: ", ")
        let more = it.droppers.count - 3
        return more > 0 ? "\(shown) +\(more) more" : shown
    }
}

/// `Turned in`, or what a derived witness claims — the reward in your export can only have come
/// from handing this quest in.
struct SkyTurnInBadge: View {
    var q: SkyQuestProgress

    var body: some View {
        if let e = q.evidence {
            Chip(text: e.badge, color: Theme.blue).help(e.hover)
        } else if q.turnIns > 0 {
            Chip(text: SkyTurnIns.badgeLabel(q.turnIns), color: Theme.green)
                .help(q.turnIns > 1
                      ? "Turned in \(q.turnIns) times. Each turn-in spends the items it required, so the progress beside this is what you hold toward doing it again."
                      : "Turned in once. The items it required were spent, so the progress beside this is what you hold toward doing it again.")
        }
    }
}

/// `have/need`, the pencil that states a count by hand, and the note for an item no dump can see.
struct SkyHaveCell: View {
    @Bindable var store: SkyStore
    var it: SkyItemProgress
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        if editing {
            HStack(spacing: 2) {
                TextField("I hold", text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: 54).font(.caption)
                    .onSubmit(commit)
                Button { commit() } label: { Image(systemName: "checkmark") }.buttonStyle(.plain).font(.caption)
                Button { editing = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).font(.caption)
            }
        } else {
            HStack(spacing: 4) {
                Text("\(it.have)/\(it.need)").font(.caption).monospacedDigit()
                if it.have < it.need, it.override == nil, it.dumpBlind {
                    Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                        .help(SkyNotes.dumpBlindItem)
                }
                if let o = it.override {
                    Button { store.setItemCount(it.name, nil) } label: { Chip(text: "By hand: \(o.count)", color: Theme.orange) }
                        .buttonStyle(.plain)
                        .help("You stated \(o.count) of these on \(Format.stamp(ms: o.setAt)). Anything looted since then is counted on top, and any turn-in recorded since then is taken off. Click to go back to counting from the log and the export.")
                }
                Button { text = String(it.held); editing = true } label: {
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Correct this count by hand - for an item you destroyed, gave away or never had. The log and the export cannot see any of those, so this is how you tell the app.")
            }
        }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let n = Int(t), n >= 0 { store.setItemCount(it.name, n) }
        editing = false
    }
}
