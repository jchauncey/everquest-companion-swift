// The Overview's statistics cards, each drawn from one summary in OverviewStats.swift: the headline
// numbers, DPS across every fight, loot & sales, and kills. Standalone views taking their data, so
// the sheet composes them and a test can render any one of them.
import SwiftUI
import Charts
import EQCompanionCore

// MARK: - Headline numbers

struct OverviewHeadline: View {
    var loot: LootSummary
    var sales: SalesSummary
    var kills: KillSummary
    var motes: MoteBreakdown
    var fights: FightSeries

    var body: some View {
        FlowLayout(spacing: 10) {
            tile(Format.count(loot.items), "items looted",
                 "\(Format.count(loot.distinct)) different items over \(Format.count(loot.lines)) loot lines")
            tile(Format.count(sales.items), "items sold",
                 "\(Format.count(sales.auto.items)) auto-sold at loot, \(Format.count(sales.vendor.items)) to merchants")
            tile(Coin.text(sales.copper), "earned selling",
                 "Auto-sell \(Coin.text(sales.auto.copper)) · merchants \(Coin.text(sales.vendor.copper))")
            tile(Format.count(kills.kills), "mobs killed", "\(Format.count(kills.distinct)) different mobs")
            tile(Format.count(motes.motes), "motes",
                 motes.perKill.map { String(format: "%.2f per kill", $0) } ?? "no kills counted")
            tile(fights.fights > 0 ? Format.rate(fights.average) : LootFmt.none, "average fight DPS",
                 "Damage over active seconds across \(Format.count(fights.fights)) fights")
        }
    }

    private func tile(_ value: String, _ label: String, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold)).foregroundStyle(Theme.gold).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: 170, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        .help(help)
    }
}

// MARK: - DPS across every fight

struct OverviewFightsCard: View {
    var fights: FightSeries
    var trailing: AnyView

    var body: some View {
        let peak = fights.points.map(\.dps).max() ?? 0
        Card("DPS over time · every fight", trailing: trailing) {
            if fights.points.isEmpty {
                Text("No fights recorded yet.").foregroundStyle(Theme.textDim).frame(height: 120)
            } else {
                Chart {
                    ForEach(fights.points) { p in
                        AreaMark(x: .value("when", p.t), y: .value("dps", p.dps)).foregroundStyle(Theme.gold.opacity(0.18))
                        LineMark(x: .value("when", p.t), y: .value("dps", p.dps)).foregroundStyle(Theme.gold)
                    }
                    RuleMark(y: .value("average", fights.average))
                        .foregroundStyle(Theme.textDim).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                .chartYScale(domain: 0...max(1, peak * 1.05))
                .frame(height: 180)
                HStack(spacing: 12) {
                    Text("\(Format.count(fights.fights)) fights · average \(Format.rate(fights.average)) (dashed)")
                    if let b = fights.best { Text("best \(Format.rate(b.dps)) - \(b.name)").lineLimit(1) }
                    Spacer()
                }
                .font(.caption).foregroundStyle(Theme.textDim)
                Text("Each point is its fights' damage over their active seconds: you, your pet and anyone fighting beside you. Fights under \(Int(FightSeries.minActiveSec)) s are left out.")
                    .font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
    }
}

// MARK: - Loot and sales

struct OverviewLootSalesCard: View {
    var loot: LootSummary
    var sales: SalesSummary
    var trailing: AnyView

    var body: some View {
        Card("Loot & sales", trailing: trailing) {
            if loot.items == 0 && sales.sales == 0 {
                Text("Nothing looted yet.").foregroundStyle(Theme.textDim)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    miniStat("Kept", loot.kept)
                    miniStat("Auto-sold", loot.sold)
                    miniStat("Stored", loot.stored)
                    miniStat("Combined", loot.combined)
                    Spacer()
                }
                if !loot.top.isEmpty {
                    Text("Most looted").font(.caption2).foregroundStyle(Theme.textDim)
                    ForEach(loot.top) { t in
                        HStack {
                            Text(t.item).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text("×\(Format.count(t.count))").monospacedDigit().foregroundStyle(Theme.textDim)
                        }
                        .font(.callout)
                    }
                }
                Divider().overlay(Theme.border)
                HStack(alignment: .firstTextBaseline) {
                    Text("Sold").font(.caption2).foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("\(Format.count(sales.items)) items for \(Coin.text(sales.copper))")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.gold)
                }
                Text("Auto-sell \(Format.count(sales.auto.items)) for \(Coin.text(sales.auto.copper))"
                     + (sales.auto.free > 0 ? " (\(Format.count(sales.auto.free)) for nothing)" : "")
                     + " · merchants \(Format.count(sales.vendor.items)) for \(Coin.text(sales.vendor.copper))")
                    .font(.caption).foregroundStyle(Theme.textDim)
                ForEach(sales.top) { t in
                    HStack {
                        Text(t.item).foregroundStyle(Theme.text).lineLimit(1)
                        Text("×\(Format.count(t.count))").foregroundStyle(Theme.textDim).monospacedDigit()
                        Spacer()
                        Text(Coin.text(t.copper)).monospacedDigit().foregroundStyle(Theme.gold)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func miniStat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Format.count(n)).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.text)
            Text(label).font(.caption2).foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Kills

struct OverviewKillsCard: View {
    var kills: KillSummary
    var trailing: AnyView

    var body: some View {
        Card("Kills", trailing: trailing) {
            if kills.kills == 0 {
                Text("No kills counted yet.").foregroundStyle(Theme.textDim)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Format.count(kills.kills)).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.gold).monospacedDigit()
                    Text("kills of \(Format.count(kills.distinct)) different mobs").font(.caption).foregroundStyle(Theme.textDim)
                    Spacer()
                }
                FlowLayout(spacing: 6) {
                    ForEach(kills.tiers) { t in
                        let s = RaidTier.style(t.tier)
                        HStack(spacing: 5) {
                            Chip(text: s.label, color: s.bg, filled: true).fixedSize()
                            Text(Format.count(t.kills)).font(.callout.monospacedDigit()).foregroundStyle(Theme.text).fixedSize()
                        }
                        .help(s.long)
                    }
                }
                Text("Most killed").font(.caption2).foregroundStyle(Theme.textDim)
                ForEach(kills.top) { t in
                    HStack {
                        Text(t.mob).foregroundStyle(Theme.text).lineLimit(1)
                        Spacer()
                        Text(Format.count(t.kills)).monospacedDigit().foregroundStyle(Theme.textDim)
                    }
                    .font(.callout)
                }
            }
        }
    }
}
