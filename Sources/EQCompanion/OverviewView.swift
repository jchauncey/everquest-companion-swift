import SwiftUI
import Charts
import EQCompanionCore

/// The landing tab: a sheet of statistics about your play. The zone strip, a row of headline
/// numbers, then Leveling (level and AA speed) beside Motes, DPS across every fight, Loot & sales
/// beside Kills, and the recent drops and kills feeds. Every card is a summary of a module the
/// engine already publishes, and links to the tab that holds the detail.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var character = ModuleSnapshot()
    @State private var progression = ModuleSnapshot()
    @State private var loot = ModuleSnapshot()
    @State private var sales = ModuleSnapshot()
    @State private var kills = LiveView()
    @State private var leveling = OverviewLevelingState()
    @State private var drops: [DropRow] = []
    @State private var killSnap = ModuleSnapshot()
    @State private var conSnap = ModuleSnapshot()
    @State private var motes = MoteBreakdown()
    @State private var lootStats = LootSummary()
    @State private var saleStats = SalesSummary()
    @State private var killStats = KillSummary()
    @State private var fights = FightSeries()
    @AppStorage("eq.tab") private var tabRaw: String = Tab.overview.rawValue

    var body: some View {
        NeedsEngine {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    zoneStrip
                    OverviewHeadline(loot: lootStats, sales: saleStats, kills: killStats, motes: motes, fights: fights)
                    HStack(alignment: .top, spacing: 14) {
                        levelingCard.frame(maxWidth: .infinity)
                        OverviewMotesCard(breakdown: motes, trailing: link("Open Motes", .motes)).frame(maxWidth: .infinity)
                    }
                    .cardsFillRow()
                    OverviewFightsCard(fights: fights, trailing: link("Open Combat", .combat))
                    HStack(alignment: .top, spacing: 14) {
                        OverviewLootSalesCard(loot: lootStats, sales: saleStats, trailing: link("All loot", .loot))
                            .frame(maxWidth: .infinity)
                        OverviewKillsCard(kills: killStats, trailing: link("Open Mobs", .mobs)).frame(maxWidth: .infinity)
                    }
                    .cardsFillRow()
                    HStack(alignment: .top, spacing: 14) {
                        dropsCard.frame(maxWidth: .infinity)
                        killsCard.frame(maxWidth: .infinity)
                    }
                    .cardsFillRow()
                }
                .padding(16)
            }
            .background(Theme.background)
            .task(id: "\(model.moduleSeqs["character"] ?? 0)|\(model.epoch ?? 0)") { await character.refresh(model, module: "character") }
            .task(id: "\(model.moduleSeqs["progression"] ?? 0)|\(model.epoch ?? 0)") {
                await progression.refresh(model, module: "progression")
                let snap = OverviewProgression(progression.state)
                let who = character.state["level"]
                let stated: (Int, Int64, String)? = who["level"].int.map { ($0, who["ts"].int64 ?? 0, who["source"].string ?? "ding") }
                leveling = overviewLeveling(snap, statedLevel: stated)
            }
            .task(id: "\(model.moduleSeqs["loot"] ?? 0)|\(model.epoch ?? 0)") {
                await loot.refresh(model, module: "loot")
                drops = buildDropRows(loot.state)
                lootStats = LootSummary.build(LootEvent.parse(loot.state))
                refoldMotes()
            }
            .task(id: "\(model.moduleSeqs["sales"] ?? 0)|\(model.epoch ?? 0)") {
                await sales.refresh(model, module: "sales")
                saleStats = SalesSummary.parse(sales.state)
            }
            .task(id: "\(model.moduleSeqs["kills"] ?? 0)|\(model.epoch ?? 0)") {
                await killSnap.refresh(model, module: "kills")
                killStats = KillSummary.build(KillRecord.index(KillRecord.parse(killSnap.state)))
                refoldMotes()
            }
            .task(id: "\(model.moduleSeqs["consider"] ?? 0)|\(model.epoch ?? 0)") {
                await conSnap.refresh(model, module: "consider")
                refoldMotes()
            }
            .task(id: model.epoch) { kills.bind(model.client, ViewDescriptor(source: "kills.recent", window: (0, 25))) }
            .task(id: model.epoch) { await pollFights() }
            .onDisappear { kills.close() }
        }
    }

    /// The Motes card's numbers: the Motes tab's own rows, summed.
    private func refoldMotes() {
        motes = MoteBreakdown.build(MoteStats.rows(loot: loot.state, kills: killSnap.state, consider: conSnap.state))
    }

    /// Every fight's summary, re-read on a slow cadence: the series moves one point per fight, and
    /// the whole history is thousands of segments, so a per-second poll would be all cost.
    private func pollFights() async {
        while !Task.isCancelled {
            if model.client.isReady,
               let r = try? await model.client.request(Op.combatSnapshot,
                                                       ["opts": ["maxSegments": .int(Int64(Self.fightHistory))]], deadline: 15) {
                fights = FightSeries.build(r["snapshot"]["segments"].array ?? [])
            }
            try? await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }

    /// More fights than any log holds: the combat engine keeps every fight's summary.
    private static let fightHistory = 1_000_000

    // MARK: - Zone strip

    private var zoneStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.textDim)
            Text(character.state["zone"].string ?? "Zone unknown").font(.headline)
            Text("\(model.attached?.name ?? "") · \(model.attached?.server ?? "")").foregroundStyle(Theme.textDim)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }

    private func link(_ text: String, _ tab: Tab) -> AnyView {
        AnyView(Button { tabRaw = tab.rawValue } label: {
            HStack(spacing: 4) { Text(text.uppercased()); Image(systemName: "arrow.up.forward.square") }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.gold)
        }.buttonStyle(.plain))
    }

    // MARK: - Leveling

    private var levelingCard: some View {
        Card("Leveling", trailing: link("Open Leveling", .leveling)) {
            if leveling.empty {
                Text("Nothing folded yet.").foregroundStyle(Theme.textDim)
            } else {
                Text("Last hour").font(.caption).foregroundStyle(Theme.textDim)
                // Fixed-width tiles that wrap: a narrow window moves a tile down rather than
                // squeezing its number and clipping its label.
                FlowLayout(spacing: 8) {
                    ForEach(leveling.tiles) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(t.value).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.gold).monospacedDigit()
                                    .lineLimit(1).fixedSize()
                                if !t.unit.isEmpty { Text(t.unit).font(.caption2).foregroundStyle(Theme.textDim).fixedSize() }
                            }
                            Text(t.label).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        .padding(8)
                        .frame(width: 132, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
                        .help(t.title)
                    }
                }
                spark
                Text("\(leveling.killRate) · \(leveling.activity)\(leveling.offline.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(Theme.textDim)
                if let aa = leveling.aaLine { Text(aa).font(.caption).foregroundStyle(Theme.textDim) }
                if let z = leveling.zoneLine { Text(z).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
                if let h = leveling.history {
                    Text(h + (leveling.verdict.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
                if leveling.atCap { Chip(text: "at cap", color: Theme.orange) }
            }
        }
    }

    private var spark: some View {
        let peak = max(leveling.sparkPeak, 0.0001)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(leveling.spark) { b in
                RoundedRectangle(cornerRadius: 1)
                    .fill(b.zone.isEmpty ? Color.gray : sparkColor(b.zone))
                    .frame(height: max(2, 36 * b.value / peak))
                    .frame(maxWidth: .infinity)
                    .help("\(Format.time(ms: b.t0)) · \(b.zone.isEmpty ? "zone unknown" : b.zone) · \(String(format: "%.2f", b.value)) levels")
            }
        }
        .frame(height: 36)
    }

    private static let zonePalette: [Color] = [Theme.green, Theme.purple, Theme.blue, Theme.orange, Theme.gold, Color(hex: 0xd97fb0), Color(hex: 0x7fd6c2), Color(hex: 0xc0c0c0)]

    private func sparkColor(_ zone: String) -> Color { Self.zonePalette[overviewZoneColorIndex(zone)] }

    // MARK: - Recent drops

    struct DropRow: Identifiable {
        var id: String
        var ts: Int64
        var item: String
        var source: String
        var zone: String
        var count: Int?
        var highlighted: Bool
        var iconId: Int?
    }

    private func buildDropRows(_ state: JSONValue) -> [DropRow] {
        let history = state.array ?? []
        let skyKeys = Set(GameData.shared.skyQuests.flatMap { q in (q["items"].array ?? []).compactMap { $0["name"].string.map(GameData.nameKey) } })
        var rows: [DropRow] = []
        var i = history.count - 1
        while i >= 0, rows.count < 25 {
            let e = history[i]
            i -= 1
            if e["disposition"].string == "destroyed" { continue }
            let name = e["item"].string ?? ""
            let known = GameData.shared.item(named: name)
            let key = GameData.nameKey(name.replacingOccurrences(of: #" \+\d+$"#, with: "", options: .regularExpression))
            let posky = skyKeys.contains(key)
            let flags = (known?.stats["flags"].array ?? []).compactMap(\.string).map { $0.lowercased() }
            let notable = posky || flags.contains("lore item") || (known?.raw["quest"].bool == true) || !(known?.raw["questUses"].array ?? []).isEmpty
            rows.append(DropRow(id: "\(e["ts"].int64 ?? 0)|\(key)|\(i)", ts: e["ts"].int64 ?? 0, item: name,
                                source: e["source"].string ?? "", zone: e["zone"].string ?? "", count: e["count"].int,
                                highlighted: notable, iconId: known?.iconId))
        }
        return rows
    }

    private var dropsCard: some View {
        Card("Recent drops", trailing: link("All loot", .loot)) {
            if drops.isEmpty { Text("Nothing looted yet.").foregroundStyle(Theme.textDim) }
            ForEach(drops) { d in
                HStack(spacing: 8) {
                    Group {
                        if let img = GameData.shared.itemIcon(d.iconId) { Image(nsImage: img).resizable().interpolation(.none) }
                        else { RoundedRectangle(cornerRadius: 3).fill(Theme.paperRaised) }
                    }.frame(width: 18, height: 18)
                    Text((d.count.map { $0 > 1 ? "\($0)× " : "" } ?? "") + d.item)
                        .fontWeight(d.highlighted ? .bold : .regular)
                        .foregroundStyle(d.highlighted ? Theme.gold : Theme.text)
                        .lineLimit(1)
                    Spacer()
                    Text(d.source).foregroundStyle(Theme.textDim).lineLimit(1)
                    Text("· \(d.zone)").foregroundStyle(Theme.textDim).lineLimit(1)
                    Text(Format.time(ms: d.ts)).foregroundStyle(Theme.textFaint).monospacedDigit()
                }
                .font(.callout)
                .padding(.vertical, 1)
                .background(d.highlighted ? Theme.gold.opacity(0.06) : Color.clear)
            }
        }
    }

    // MARK: - Recent kills

    private var killsCard: some View {
        Card("Recent kills", trailing: link("Leveling", .leveling)) {
            if kills.rows.isEmpty, !kills.loading { Text("No kills yet.").foregroundStyle(Theme.textDim) }
            ForEach(kills.rows) { r in
                HStack(spacing: 8) {
                    Text(r["name"].display).lineLimit(1)
                    if r["pet"].bool == true { Chip(text: "pet") }
                    Spacer()
                    Text(r["zone"].display).foregroundStyle(Theme.textDim).lineLimit(1)
                    if r["expStated"].bool == true, let p = r["expPct"].double {
                        Text(String(format: "+%.2f%%", p)).foregroundStyle(Theme.green).monospacedDigit()
                    } else if r["expLine"].bool == true {
                        Text("xp").foregroundStyle(Theme.green)
                    }
                    Text(Format.time(ms: r.at)).foregroundStyle(Theme.textFaint).monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}
