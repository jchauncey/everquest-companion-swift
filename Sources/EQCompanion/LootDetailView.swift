// The Loot tab's item drill-down, as a PANE TAKEOVER rather than a popover — the same decision the
// Electron app made and for the same reason: this is not a peek, it is a second surface (who drops
// it, where, how often against your own kills, and the item window itself), and a modal would put
// all of it in a box floating over the table it covers anyway.
//
// THE BREADCRUMB IS THE ADDRESS. `Loot › <item>` says where you are and its root is a real control,
// with a back chevron beside it for the reader who reaches for one. A takeover with two exits is a
// takeover nobody gets stuck in.
//
// EVERY NUMBER HERE IS SLICED, exactly like the ledger it came from — the counts, the mob table and
// the recency all describe the stretch the control at the top says they do. The inventory estimate
// is NOT: an export is a single observation of what you hold NOW and carries no timestamps at all,
// so cutting it to a window would be inventing dates the file does not have.
import SwiftUI
import EQCompanionCore

/// One mob that has dropped this item for you, and how often per corpse.
private struct LootMobRow: Identifiable {
    var mob: String
    var zone: String
    /// Σ stack sizes off this mob in this zone.
    var drops: Int
    /// Loot LINES. Differs from `drops` exactly when something dropped in stacks.
    var lines: Int
    var last: Int64
    /// Your own kills of this mob, all tiers, from the `kills` module. Nil when it has none on
    /// record — which is a real state, not a zero: the drop may predate this log's kill census.
    var kills: Int?
    var id: String { "\(mob)|\(zone)" }

    /// Drops per corpse, as a percentage. Absent when the kill count is unknown.
    var rate: String {
        guard let k = kills, k > 0 else { return LootFmt.none }
        return LootFmt.dropPct(drops: drops, kills: k)
    }
}

struct LootDetailView: View {
    @Environment(AppModel.self) private var model
    /// The display name the row carried — `Sphinx Claw +1` keeps its suffix here.
    var item: String
    /// The slice's events, every item. Filtering one name out of 2.4k rows is free.
    var events: [LootEvent]
    var slice: LootSlice
    /// What the count source vouches for on this item's counting key.
    var estimate: Int
    /// What the turn-in ledger took off it.
    var consumed: Int
    var onBack: () -> Void

    @State private var kills = ModuleSnapshot()

    private var mine: [LootEvent] {
        let key = item.lowercased()
        return events.filter { $0.itemKey == key }
    }

    private var facts: LootItemFacts { LootKnowledge.shared.facts(item) }

    /// Kills by lower-cased mob name — the `kills` module's own key.
    private var killCounts: [String: Int] {
        var out: [String: Int] = [:]
        for (k, v) in kills.state["mobs"].object ?? [:] { out[k] = v["count"].int }
        return out.compactMapValues { $0 }
    }

    /// One row per (mob, zone), drops descending. A DESTROY NAMES NO MOB and never enters this
    /// table: it happened in your bags.
    private var mobRows: [LootMobRow] {
        let counts = killCounts
        var map: [String: LootMobRow] = [:]
        for e in mine where e.isAcquisition {
            guard let mob = e.source else { continue }
            let zone = e.zone ?? LootZone.unknown
            let id = "\(mob)|\(zone)"
            if map[id] == nil {
                map[id] = LootMobRow(mob: mob, zone: zone, drops: 0, lines: 0, last: 0,
                                     kills: counts[mob.lowercased()])
            }
            map[id]!.drops += e.count
            map[id]!.lines += 1
            map[id]!.last = max(map[id]!.last, e.ts)
        }
        return map.values.sorted { a, b in
            if a.drops != b.drops { return a.drops > b.drops }
            if a.last != b.last { return a.last > b.last }
            return a.mob < b.mob
        }
    }

    /// Zones this item has dropped in for you, most drops first.
    private var zoneRows: [(zone: String, drops: Int)] {
        var map: [String: Int] = [:]
        for e in mine where e.isAcquisition { map[e.zone ?? LootZone.unknown, default: 0] += e.count }
        return map.map { (zone: $0.key, drops: $0.value) }
            .sorted { $0.drops == $1.drops ? $0.zone < $1.zone : $0.drops > $1.drops }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summary
                        mobTable
                        zoneList
                    }
                    .padding(14)
                }
                .frame(minWidth: 420, maxWidth: .infinity)
                // THE item card — the knowledge record with the upgrade slider on top, the same
                // surface the Gear peek and the map's mob card draw.
                ItemCardView(name: LootName.normalize(item))
                    .padding(.vertical, 8)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
            }
        }
        .task(id: "\(model.moduleSeqs["kills"] ?? 0)|\(model.epoch ?? 0)") { await kills.refresh(model, module: "kills") }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.gold)
                .help("Back to the loot list")
            Button("Loot", action: onBack)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            Text("›").foregroundStyle(Theme.textFaint)
            if let icon = GameData.shared.itemIcon(facts.iconId) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text(item).font(.title3.weight(.semibold)).foregroundStyle(Theme.gold)
            ForEach(Array(facts.chips.enumerated()), id: \.offset) { _, c in
                Chip(text: c.0, color: LootChipColor.of(c.1))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var summary: some View {
        let drops = mine.filter { !$0.isDestroyed }.reduce(0) { $0 + $1.count }
        let lines = mine.count
        let last = mine.map(\.ts).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Stat(label: "Drops", value: Format.count(drops))
                Stat(label: "Loot lines", value: Format.count(lines))
                Stat(label: "In inventory (est.)", value: estimate > 0 ? "~\(estimate)" : LootFmt.none)
                Stat(label: "Last looted", value: last > 0 ? Format.stamp(ms: last) : LootFmt.none)
            }
            Text("Over \(slice.caption). Drops count stack sizes, so one \u{201C}2 Bone Chips\u{201D} line is two drops.")
                .font(.caption).foregroundStyle(Theme.textDim)
            if consumed > 0 {
                Text("\(consumed) handed in to an NPC per the turn-in ledger, and subtracted from the estimate.")
                    .font(.caption).foregroundStyle(Theme.orange)
            }
            if let s = GameData.shared.item(named: item)?.summary {
                Text(s).font(.callout).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mobTable: some View {
        Card("WHO DROPPED IT") {
            if mobRows.isEmpty {
                Text("No loot line for this item names a mob in \(slice.caption). A combine or a bag "
                     + "destroy carries no source, and neither does a drop from before this log.")
                    .font(.caption).foregroundStyle(Theme.textDim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        Text("Mob").gridColumnAlignment(.leading)
                        Text("Zone")
                        Text("Drops").gridColumnAlignment(.trailing)
                        Text("Your kills").gridColumnAlignment(.trailing)
                        Text("Drop rate").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.textDim)
                    ForEach(mobRows.prefix(40)) { r in
                        GridRow {
                            Text(r.mob).foregroundStyle(Theme.text).lineLimit(1)
                            Text(r.zone).foregroundStyle(Theme.textDim).lineLimit(1)
                            Text(Format.count(r.drops)).monospacedDigit()
                            Text(r.kills.map { Format.count($0) } ?? LootFmt.none)
                                .monospacedDigit().foregroundStyle(Theme.textDim)
                            Text(r.rate).monospacedDigit().foregroundStyle(r.kills == nil ? Theme.textFaint : Theme.green)
                        }
                        .font(.callout)
                    }
                }
                // The honesty rule this table runs on: a rate is drops per corpse of YOUR OWN kills
                // of that mob, which is a perceived rate over your sample and not the game's table.
                Text("Drop rate is this item's drops divided by your own kills of that mob "
                     + "(every tier, from the kills module) — a perceived rate over your sample, "
                     + "never the game's own table. A dash means no kill of that mob is on record.")
                    .font(.caption).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var zoneList: some View {
        Card("WHERE IT DROPPED") {
            if zoneRows.isEmpty {
                Text("No zone on record for this item in \(slice.caption).")
                    .font(.caption).foregroundStyle(Theme.textDim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    ForEach(Array(zoneRows.prefix(20).enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.zone).foregroundStyle(Theme.text).lineLimit(1)
                            Text(Format.count(r.drops)).monospacedDigit().gridColumnAlignment(.trailing)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }
}

/// One palette for the ledger's state chips, so a word means the same colour on every Loot surface.
enum LootChipColor {
    static func of(_ kind: String) -> Color {
        switch kind {
        case "sky": return Theme.gold
        case "lore": return Theme.orange
        case "quest": return Theme.purple
        case "tradeskill": return Theme.blue
        case "upgrade": return Theme.green
        // A destroy is the one row that says an item LEFT — the strongest thing a bag-history row
        // can say, and the only one the held counts subtract for.
        case "destroyed": return Theme.orange
        case "sold": return Theme.textFaint
        case "combined": return Theme.green
        default: return Theme.blue
        }
    }
}
