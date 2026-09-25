// The Overview's statistics cards, each drawn from one summary in OverviewStats.swift: the headline
// numbers, DPS across every fight, loot & sales, and kills. Standalone views taking their data, so
// the sheet composes them and a test can render any one of them.
import SwiftUI
import Charts
import EQCompanionCore

// MARK: - Headline numbers

/// The sheet's headline numbers, in the Leveling and Combat tabs' card style (`AccentCard`): each its
/// own accent colour and icon, spread across the full width at one height.
struct OverviewHeadline: View {
    var loot: LootSummary
    var sales: SalesSummary
    var kills: KillSummary
    var motes: MoteBreakdown
    var fights: FightSeries

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            card(Format.count(loot.items), "items looted",
                 "\(Format.count(loot.distinct)) different items", color: Theme.blue, icon: "shippingbox.fill")
                .help("\(Format.count(loot.distinct)) different items over \(Format.count(loot.lines)) loot lines")
            card(Format.count(sales.items), "items sold",
                 "\(Format.count(sales.auto.items)) auto · \(Format.count(sales.vendor.items)) merchant",
                 color: Theme.orange, icon: "tag.fill")
                .help("\(Format.count(sales.auto.items)) auto-sold at loot, \(Format.count(sales.vendor.items)) to merchants")
            card(Coin.text(sales.copper), "earned selling", "over \(Format.count(sales.sales)) sales",
                 color: Theme.gold, icon: "dollarsign.circle.fill")
                .help("Auto-sell \(Coin.text(sales.auto.copper)) · merchants \(Coin.text(sales.vendor.copper))")
            card(Format.count(kills.kills), "mobs killed", "\(Format.count(kills.distinct)) different mobs",
                 color: Theme.red, icon: "scope")
            card(Format.count(motes.motes), "motes",
                 motes.perKill.map { String(format: "%.2f per kill", $0) } ?? "no kills counted",
                 color: Theme.purple, icon: "circle.hexagongrid.fill")
            card(fights.fights > 0 ? Format.rate(fights.average) : LootFmt.none, "average fight DPS",
                 "over \(Format.count(fights.fights)) fights", color: Theme.green, icon: "flame.fill")
                .help("Damage over active seconds across \(Format.count(fights.fights)) fights")
        }
        // One height for the row: the tallest card's, the others stretched to it.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func card(_ value: String, _ label: String, _ sub: String, color: Color, icon: String) -> some View {
        AccentCard(color: color, icon: icon, fill: true) {
            Text(value).font(.system(size: 26, weight: .semibold)).foregroundStyle(color).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.callout).foregroundStyle(Theme.text).lineLimit(1)
            Text(sub).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1).minimumScaleFactor(0.8)
        }
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
    /// No link for now: the Mobs page it would open is out of the sidebar until it is revisited.
    var trailing: AnyView? = nil

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
