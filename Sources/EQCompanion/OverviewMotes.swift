// The Overview's Motes card: where your Motes of Potential came from, by instance difficulty, at a
// glance. It reads the same rows the Motes tab draws (`MoteStats.rows` → `MoteBreakdown`), so the
// card is a summary of that tab and never a second opinion.
//
// One line per difficulty on the ladder (open world, D0…D4, then "not stated"): a bar for the motes
// looted there, sized against the biggest tier, and the per-kill rate beside it — because "which
// difficulty pays" is a rate question and "where did they come from" is a count question, and the
// card answers both without making you pick.
import SwiftUI
import EQCompanionCore

struct OverviewMotesCard: View {
    var breakdown: MoteBreakdown
    var trailing: AnyView

    var body: some View {
        Card("Motes", trailing: trailing) {
            if breakdown.isEmpty {
                Text("No Motes of Potential looted yet.").foregroundStyle(Theme.textDim)
            } else {
                headline
                tierBars
                gradeMix
                topSources
            }
        }
    }

    // MARK: - Headline

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(Format.count(breakdown.motes)).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.gold)
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 1) {
                Text("motes looted").font(.caption).foregroundStyle(Theme.textDim)
                Text("\(perKill(breakdown.perKill)) per kill over \(Format.count(breakdown.kills)) kills")
                    .font(.caption).foregroundStyle(Theme.textDim)
            }
            Spacer()
            if let best = breakdown.bestTier {
                let s = RaidTier.style(best.tier)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Best rate").font(.caption2).foregroundStyle(Theme.textDim)
                    HStack(spacing: 6) {
                        Chip(text: s.label, color: s.bg, filled: true)
                        Text("\(perKill(best.perKill))/kill").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.text)
                    }
                }
                .help("The difficulty with the most motes per kill, among those with at least \(MoteBreakdown.minKillsForBest) kills.")
            }
        }
    }

    // MARK: - By difficulty

    private var tierBars: some View {
        let peak = max(1, breakdown.tiers.map(\.motes).max() ?? 1)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(breakdown.tiers) { t in
                let s = RaidTier.style(t.tier)
                HStack(spacing: 8) {
                    Text(s.long).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        let frac = CGFloat(t.motes) / CGFloat(peak)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Theme.paperRaised)
                            RoundedRectangle(cornerRadius: 3).fill(s.bg)
                                .frame(width: max(t.motes > 0 ? 3 : 0, g.size.width * frac))
                        }
                    }
                    .frame(height: 12)
                    Text(Format.count(t.motes)).font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.gold).frame(width: 52, alignment: .trailing)
                    Text(perKill(t.perKill)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                        .frame(width: 44, alignment: .trailing)
                        .help("\(Format.count(t.motes)) motes from \(Format.count(t.corpses)) corpses over \(Format.count(t.kills)) kills")
                }
            }
            HStack {
                Spacer()
                Text("motes · per kill").font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
    }

    // MARK: - Grades and sources

    @ViewBuilder
    private var gradeMix: some View {
        if !breakdown.grades.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(breakdown.grades, id: \.grade) { g in
                    HStack(spacing: 4) {
                        Text(MoteLadder.label(g.grade)).foregroundStyle(Theme.textDim)
                        Text(Format.count(g.motes)).monospacedDigit().foregroundStyle(Theme.text)
                    }
                    .font(.caption)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.paperRaised))
                }
            }
        }
    }

    @ViewBuilder
    private var topSources: some View {
        if !breakdown.top.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Top sources").font(.caption2).foregroundStyle(Theme.textDim)
                ForEach(breakdown.top) { r in
                    let s = RaidTier.style(r.tier)
                    HStack(spacing: 6) {
                        Chip(text: s.label, color: s.bg, filled: true).fixedSize()
                        Text(r.mob).foregroundStyle(Theme.text).lineLimit(1)
                        if !r.zone.isEmpty { Text("· \(r.zone)").foregroundStyle(Theme.textDim).lineLimit(1) }
                        Spacer()
                        Text(Format.count(r.motes)).monospacedDigit().foregroundStyle(Theme.gold)
                        Text(perKill(r.perKill)).font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func perKill(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? LootFmt.none }
}
