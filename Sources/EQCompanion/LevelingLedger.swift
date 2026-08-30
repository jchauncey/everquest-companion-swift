// The AA ledger: every rank the log recorded, grouped into ladders and sorted by points invested.
// Ported from src/renderer/src/features/leveling/LvAaLedgerPanel.tsx.
//
// THE LADDER IS AS TALL AS THE ACCOUNT. It is a LEDGER — you read it down — so the panel takes its
// honest height and the footer sits under the last row where a total belongs.
import SwiftUI
import EQCompanionCore

/// How many ladders draw before the rest fold behind `+N more`.
private let ladderTopN = 25

private let paidColor = Color(hex: 0xb07fd0)
private let autoColor = Color(hex: 0x7a7a7a)

private struct AbilityRowView: View {
    var row: LvAaAbilityRow
    var max: Int
    @Binding var open: Set<String>

    private var paid: Bool { row.invested > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if open.contains(row.name) { open.remove(row.name) } else { open.insert(row.name) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open.contains(row.name) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).foregroundStyle(Theme.textFaint)
                    Image(systemName: "sparkles").font(.system(size: 9))
                        .foregroundStyle(paid ? paidColor : autoColor)
                    Text(row.name).font(.caption).foregroundStyle(paid ? Theme.text : Theme.textDim).lineLimit(1)
                    Spacer(minLength: 4)
                    badges
                    Chip(text: "R\(row.topRank)", color: Theme.green)
                        .help("\(row.ranks.count) \(LevelingFormat.plural(row.ranks.count, "rank")) logged, top rank \(row.topRank)")
                    Text(paid ? "\(row.invested) pts" : LevelingFormat.none)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(paid ? Theme.textDim : Theme.textFaint)
                        .frame(width: 48, alignment: .trailing)
                }
                .padding(.vertical, 2).padding(.horizontal, 3)
                .background(alignment: .leading) {
                    // The share of the biggest ladder, as a bar behind the row.
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(paidColor.opacity(0.10))
                            .frame(width: max > 0 ? geo.size.width * Double(row.invested) / Double(max) : 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.contains(row.name) { rungs }
        }
    }

    @ViewBuilder
    private var badges: some View {
        if row.autoRanks > 0 {
            Chip(text: "auto", color: autoColor)
                .help("\(row.autoRanks) \(LevelingFormat.plural(row.autoRanks, "rank")) granted, not bought")
        }
        if row.rebuys > 0 {
            Chip(text: "re-bought ×\(row.rebuys)", color: Theme.gold)
                .help("a rank already owned was purchased again")
        }
        if !row.unlogged.isEmpty {
            let word = LevelingFormat.plural(row.unlogged.count, "rank")
            Chip(text: "\(word) \(LvAaLedger.rangeLabel(row.unlogged)) unlogged", color: Theme.blue)
                .help("\(word) \(LvAaLedger.rangeLabel(row.unlogged)) never appear in this log")
        }
    }

    private var rungs: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(row.ranks, id: \.rank) { r in
                HStack(spacing: 8) {
                    Text("rank \(r.rank)").foregroundStyle(Theme.textDim).frame(width: 48, alignment: .leading)
                    Text(r.cost > 0 ? "\(r.cost) \(LevelingFormat.plural(r.cost, "pt"))" : "granted")
                        .foregroundStyle(r.cost > 0 ? Theme.text : Theme.textFaint)
                        .frame(width: 56, alignment: .leading)
                    if r.buys > 1 { Text("bought \(r.buys)×").foregroundStyle(Theme.textFaint) }
                    Spacer(minLength: 0)
                    Text(Format.date(ms: r.ts)).foregroundStyle(Theme.textFaint)
                }
                .font(.caption2)
            }
        }
        .padding(.leading, 26).padding(.bottom, 3)
    }
}

struct LvAaLedgerPanel: View {
    var rows: [LvAaAbilityRow]
    /// the AA-points-spent headline this footer must equal.
    var allocated: Int
    @State private var open: Set<String> = []
    @State private var showRest = false

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            let summary = LvAaLedger.summary(rows)
            let maxInvested = rows.first?.invested ?? 0
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("AA ABILITIES").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Theme.textDim)
                        Text("(\(summary.abilities))").font(.caption).foregroundStyle(Theme.textFaint)
                    }
                    Text("every rank the log recorded, grouped into ladders and sorted by points invested - click a row for its rungs")
                        .font(.caption2).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(rows.prefix(ladderTopN)) { r in
                        AbilityRowView(row: r, max: maxInvested, open: $open)
                    }
                    if rows.count > ladderTopN {
                        Button { showRest.toggle() } label: {
                            Text("+\(rows.count - ladderTopN) more")
                                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        if showRest {
                            ForEach(rows.dropFirst(ladderTopN)) { r in
                                AbilityRowView(row: r, max: maxInvested, open: $open)
                            }
                        }
                    }
                    Divider().overlay(Theme.border)
                    Text(footer(summary))
                        .font(.caption2).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func footer(_ s: LvAaLedgerSummary) -> String {
        var out = "\(LevelingFormat.grouped(s.invested)) pts across \(s.paidRanks) bought \(LevelingFormat.plural(s.paidRanks, "rank"))"
        if s.autoRanks > 0 { out += " · \(s.autoRanks) granted" }
        return out + " - the same total as the \(LevelingFormat.grouped(allocated)) AA points spent above"
    }
}
