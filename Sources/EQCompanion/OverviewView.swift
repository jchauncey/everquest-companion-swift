import SwiftUI
import Charts
import EQCompanionCore

/// The landing tab: a sheet of statistics about your play. The zone strip, a row of headline
/// numbers, then Leveling (your whole playtime: level, hours, levels, AA, kills, a bar a day) beside Motes, DPS across every fight, Loot & sales
/// beside Kills, and the recent drops and kills feeds. Every card is a summary of a module the
/// engine already publishes, and links to the tab that holds the detail.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @State private var character = ModuleSnapshot()
    @State private var progression = ModuleSnapshot()
    @State private var loot = ModuleSnapshot()
    @State private var sales = ModuleSnapshot()
    @State private var kills = LiveView()
    @State private var playtime = OverviewPlaytime()
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
                        OverviewKillsCard(kills: killStats).frame(maxWidth: .infinity)
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
                playtime = overviewPlaytime(snap, statedLevel: stated)
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

    /// All of your play, like every other card here (OverviewPlaytime.swift): level, time played,
    /// what it bought, and a bar per day you played.
    private var levelingCard: some View {
        Card("Leveling", trailing: link("Open Leveling", .leveling)) {
            if playtime.empty {
                Text("Nothing folded yet.").foregroundStyle(Theme.textDim)
            } else {
                Text("Since \(Format.date(ms: playtime.sinceTs))").font(.caption).foregroundStyle(Theme.textDim)
                FlowLayout(spacing: 8) {
                    ForEach(playtimeTiles) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.value).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.gold).monospacedDigit()
                                .lineLimit(1).fixedSize()
                            Text(t.label).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                        }
                        .padding(8)
                        .frame(width: 150, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
                        .help(t.title)
                    }
                }
                if !playtime.days.isEmpty { playDays }
                if let h = playtime.history {
                    Text(h).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                }
            }
        }
    }

    private var playtimeTiles: [OverviewLevelingTile] {
        let p = playtime
        let hrs = { (ms: Double) in OverviewWords.duration(ms) }
        var tiles: [OverviewLevelingTile] = []
        if let l = p.level {
            tiles.append(.init(id: "level", value: String(l), unit: "",
                               label: p.firstLevel.map { $0 < l ? "level · from \($0)" : "level" } ?? "level",
                               title: p.swaps > 0 ? "\(p.swaps) class \(p.swaps == 1 ? "swap" : "swaps") reset the level along the way" : "The level the log last stated"))
        }
        tiles.append(.init(id: "played", value: hrs(Double(p.playedMs)), unit: "",
                           label: "played · \(hrs(Double(p.activeMs))) active",
                           title: "Online time since your first logged activity; active is the time with a kill, experience or loot at most 5 minutes apart"))
        tiles.append(.init(id: "levels", value: String(p.levelUps), unit: "",
                           label: p.activePerLevelMs.map { "levels · \(hrs($0)) each" } ?? "levels gained",
                           title: "Level-ups logged; the average is active time per level"))
        tiles.append(.init(id: "aa", value: String(p.aa), unit: "",
                           label: p.aaPerActiveHour.map { "AA · \(OverviewWords.small($0))/hr" } ?? "AA earned",
                           title: "Ability points from the gain lines; the rate is per active hour"))
        tiles.append(.init(id: "kills", value: Format.count(p.kills), unit: "",
                           label: p.killsPerActiveHour.map { "kills · \(OverviewWords.small($0))/hr" } ?? "kills",
                           title: "Your kills (yours and your pet's killing blows); the rate is per active hour"))
        return tiles
    }

    /// Active hours on each day you played.
    private var playDays: some View {
        Chart(playtime.days) { d in
            BarMark(x: .value("Day", Date(timeIntervalSince1970: Double(d.start) / 1000), unit: .day),
                    y: .value("Active hours", Double(d.activeMs) / 3_600_000))
                .foregroundStyle(Theme.gold.opacity(d.levels >= 1 ? 1 : 0.6))
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { if let h = v.as(Double.self) { Text("\(Int(h))h").font(.caption2) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: true).font(.caption2)
            }
        }
        .frame(height: 90)
        .help("Active hours per day you played - brighter on a day with a level gained. " +
              "\(playtime.days.count) days since \(Format.date(ms: playtime.sinceTs)).")
    }

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
