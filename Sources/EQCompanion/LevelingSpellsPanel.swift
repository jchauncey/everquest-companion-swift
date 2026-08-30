// The right column's first panel: of everything the loadout already owns, what is best at the
// level being viewed. It reads no scope and no chart — only the loadout — so it is the reason the
// right column can exist on a log the charts cannot draw.
//
// Ported from src/renderer/src/features/leveling/LvBestSpells*.tsx.
import SwiftUI
import EQCompanionCore

/// How many rows a tab draws before the rest fold behind a disclosure.
private let lvBestSpellsTopN = 10

/// The stepper the unlock panel has too — a second handle on the ONE viewed level.
struct LvLevelStepper: View {
    var level: Int
    var onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { onChange(level - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(level <= 1)
            Text("Level \(level)").font(.caption.weight(.semibold)).foregroundStyle(Theme.gold).monospacedDigit()
            Button { onChange(level + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(level >= 60)
        }
        .font(.caption2)
        .foregroundStyle(Theme.textDim)
    }
}

/// Every row is read at the higher of the rank you have been observed casting and this one, so a
/// spell you already own at a better rank is never pulled down.
struct LvSpellRankSlider: View {
    @Binding var rank: Double

    static func label(_ rank: Int) -> String {
        rank <= 0 ? "base ranks" : "all at \(LvSpellScale.roman(rank))+"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Simulate rank").font(.caption2).foregroundStyle(Theme.textDim)
                Spacer()
                Text(Self.label(Int(rank)))
                    .font(.caption2)
                    .foregroundStyle(rank <= 0 ? Theme.textFaint : Theme.gold)
            }
            Slider(value: $rank, in: 0...Double(LvSpellScale.maxRank), step: 1)
                .controlSize(.mini)
        }
        .help("Every row is read at the higher of the rank you have been observed casting and this one. Damage and healing move with it; mana and cast time are the base figures.")
    }
}

private struct SpellRowView: View {
    var row: LvBestSpellRow
    var columns: [LvBestSpellColumn]
    var ranks: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(row.name).font(.caption.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if row.owned {
                    Text("L\(row.gainedAt)").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                } else if !row.levels.isEmpty {
                    Text(row.levels.prefix(3).map { "\($0.cls) \($0.level)" }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundStyle(Theme.textFaint).lineLimit(1)
                }
                if let label = LvSpellLines.observedLabel(ranks, row.name) {
                    Chip(text: label, color: Theme.green)
                        .help("The highest rank of this spell your log has watched you merge or cast.")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                ForEach(columns) { c in
                    Text(row.text(c))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SpellDisclosure: View {
    var label: String
    var rows: [LvBestSpellRow]
    var columns: [LvBestSpellColumn]
    var ranks: [String: Int]
    @State private var open = false

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            Button { open.toggle() } label: {
                HStack(spacing: 2) {
                    Text(label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 7))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .buttonStyle(.plain)
            if open {
                ForEach(rows) { r in SpellRowView(row: r, columns: columns, ranks: ranks) }
            }
        }
    }
}

struct LvBestSpellsPanel: View {
    var best: LvBestSpells
    var ranks: [String: Int]
    var level: Int
    var loading: Bool
    @Binding var tab: LvBestSpellTab
    @Binding var query: String
    @Binding var simulate: Double
    @Binding var sorts: [LvBestSpellTab: LvBestSpellSort]
    var search: (rows: [LvBestSpellRow], matched: Int, hidden: Int, elsewhere: Int)
    var onLevel: (Int) -> Void

    private var sort: LvBestSpellSort {
        sorts[tab] ?? LvBestSpellSort(column: tab.rankColumn, desc: true)
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                header
                tabs
                TextField("Search all spells", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                LvSpellRankSlider(rank: $simulate)
                if best.classes.isEmpty {
                    Text(loading ? "Reading the spell catalogue…"
                                 : "No class is known for this character yet - the loadout is read from your own /who row.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                } else {
                    columnHeader
                    if searching { searchBody } else { tabBody }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Best at").font(.caption.weight(.bold)).tracking(0.8).foregroundStyle(Theme.textDim)
            LvLevelStepper(level: level, onChange: onLevel)
            // Said once per surface, never on a row: these are base figures with no crits, AA or
            // resist in them.
            Text("directional").font(.caption2).foregroundStyle(Theme.textFaint)
            if tab == .aoe {
                Text(best.aoeTargets).font(.caption2).foregroundStyle(Theme.textFaint)
                    .help(LvAoeSpells.assumptionTitle)
            }
            Spacer(minLength: 0)
            if !best.classes.isEmpty {
                Text(best.classes.joined(separator: "/")).font(.caption2).foregroundStyle(Theme.textFaint)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(LvBestSpellTab.allCases) { t in
                let count = best.tabs[t]?.shown.count ?? 0
                Button { tab = t } label: {
                    Text("\(t.label) (\(count))")
                        .font(.system(size: 10, weight: tab == t ? .bold : .regular))
                        .foregroundStyle(tab == t ? Theme.gold : Theme.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(tab == t ? Theme.gold : Color.clear).frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            ForEach(tab.columns) { c in
                Button {
                    let active = sort.column == c
                    sorts[tab] = LvBestSpellSort(column: c, desc: active ? !sort.desc : true)
                } label: {
                    HStack(spacing: 2) {
                        Spacer(minLength: 0)
                        Text(c.label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(sort.column == c ? Theme.gold : Theme.textDim)
                        if sort.column == c {
                            Image(systemName: sort.desc ? "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                                .font(.system(size: 6)).foregroundStyle(Theme.gold)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(c.title)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var tabBody: some View {
        let table = best.tabs[tab] ?? LvBestSpellsTable()
        if table.shown.isEmpty, table.outOfEra.isEmpty {
            Text("nothing this loadout owns yet").font(.caption).foregroundStyle(Theme.textFaint)
        } else {
            let sorted = LvBestSpellsReadout.sort(table.shown, sort)
            ForEach(sorted.prefix(lvBestSpellsTopN)) { r in
                SpellRowView(row: r, columns: tab.columns, ranks: ranks)
            }
            SpellDisclosure(label: "+\(max(0, sorted.count - lvBestSpellsTopN)) more",
                            rows: Array(sorted.dropFirst(lvBestSpellsTopN)),
                            columns: tab.columns, ranks: ranks)
            SpellDisclosure(label: lvOutOfEraLabel(table.outOfEra.count),
                            rows: LvBestSpellsReadout.sort(table.outOfEra, sort),
                            columns: tab.columns, ranks: ranks)
        }
    }

    @ViewBuilder
    private var searchBody: some View {
        if search.rows.isEmpty {
            Text(search.elsewhere > 0
                 ? "\(search.elsewhere) more match with no \(tab.label) reading"
                 : "nothing in the catalogue matches that")
                .font(.caption).foregroundStyle(Theme.textFaint)
        } else {
            ForEach(search.rows) { r in SpellRowView(row: r, columns: tab.columns, ranks: ranks) }
            if search.hidden > 0 {
                Text("+\(search.hidden) more match, not shown").font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
            if search.elsewhere > 0 {
                Text("\(search.elsewhere) more match with no \(tab.label) reading")
                    .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
            }
        }
    }
}
