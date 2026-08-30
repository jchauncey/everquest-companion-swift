// The DURATIONS block of the Buffs tab: every spell line this character's log has mined, in two
// grouped tables — Buffs, then Debuffs — with the estimate the app uses, where it came from, and
// the distribution behind it. Ported from `src/renderer/src/features/buffs/BuffStats.tsx`.
//
// It is split out of BuffsView for the same reason the Electron file was: the tab is a header, a
// live section and this, and this is the half with a data pipeline behind it.
//
// THE SEARCH IS A PLAIN CASE-INSENSITIVE SUBSTRING over the spell name, across both classes — not
// the spell catalogue's token machinery. These tables are the only complete list of "spells I could
// tick", and in opt-in mode finding a buff that is not currently up is the whole reason to type.
import SwiftUI
import EQCompanionCore

/// One mined spell line, read out of the `buffs` module snapshot's `stats` map.
struct BuffStatRow: Identifiable, Sendable, Equatable {
    var id: String
    var spell: String
    var cls: String
    var estimateMs: Double?
    var estimatorSource: String?
    var n: Int
    var medianMs: Double?
    var p25: Double?
    var p75: Double?
    var minMs: Double?
    var maxMs: Double?
    /// The spell LINE this row's box keys on (rank-stripped, case-folded).
    var lineKey: String
    /// `spell` lower-cased once, so the search does not fold 200 names per keystroke.
    var searchKey: String
    /// The database's own stated duration, kept for the estimate fallback ladder.
    var dbDurationMs: Double?
}

/// The whole durations table, built once per module seq.
struct BuffStatsTable: Sendable, Equatable {
    var rows: [BuffStatRow] = []
    /// The header chip's `n tracked`: entries with at least one cast→fade pair.
    var tracked = 0
    /// True once a snapshot has been read, so "nothing mined yet" is distinguishable from "not yet".
    var loaded = false
}

enum BuffStatsBuilder {
    /// THE ESTIMATE THE APP USES: `max(DB floor, recent observed max)` as the engine resolved it,
    /// with the pre-`estimateMs` fallbacks the renderer has always kept for older deltas.
    static func estimate(_ s: BuffStatRow) -> (ms: Double?, src: String?) {
        let ms = s.estimateMs ?? s.dbDurationMs ?? s.medianMs
        let src = s.estimatorSource ?? (s.dbDurationMs != nil ? "db" : (s.medianMs != nil ? "observed" : nil))
        return (ms, src)
    }

    /// Read the `stats` map into rows, sorted by sample count then name — the table's own order,
    /// so nothing downstream re-sorts. Pure and off the main actor: it runs in a detached task.
    static func build(stats: JSONValue) -> BuffStatsTable {
        guard let map = stats.object else { return BuffStatsTable(loaded: true) }
        var rows: [BuffStatRow] = []
        rows.reserveCapacity(map.count)
        var tracked = 0
        for (key, s) in map {
            let spell = s["spell"].string ?? key
            let n = s["n"].int ?? 0
            // The header chip counts what has been MINED — a stats entry with at least one
            // measured cast→fade pair. A row that exists only because the database states a
            // duration is not something this log has tracked.
            if n > 0 { tracked += 1 }
            rows.append(BuffStatRow(
                id: key,
                spell: spell,
                cls: s["cls"].string ?? "buff",
                estimateMs: s["estimateMs"].double,
                estimatorSource: s["estimatorSource"].string,
                n: n,
                medianMs: s["medianMs"].double,
                p25: s["p25"].double,
                p75: s["p75"].double,
                minMs: s["minMs"].double,
                maxMs: s["maxMs"].double,
                lineKey: BuffFormat.timerNameKey(spell),
                searchKey: spell.lowercased(),
                dbDurationMs: s["dbDurationMs"].double
            ))
        }
        rows.sort { a, b in a.n != b.n ? a.n > b.n : a.spell.localizedCaseInsensitiveCompare(b.spell) == .orderedAscending }
        return BuffStatsTable(rows: rows, tracked: tracked, loaded: true)
    }
}

/// The durations section: the search field, then one table per class that still has a row.
struct BuffsDurationsSection: View {
    var table: BuffStatsTable
    @State private var query = ""
    @MainActor private var allow: BuffAllowStore { BuffAllowStore.shared }

    /// A dungeon night can mine a few hundred lines; the tables are bounded and say so.
    private let maxRows = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Durations").font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint).font(.caption)
                    TextField("Search spells", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 200)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.paperRaised))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            }
            let sections = shownSections
            if sections.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(Theme.textDim)
            } else {
                ForEach(sections) { s in
                    section(cls: s.id, label: s.label, rows: s.rows)
                }
            }
        }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var emptyText: String {
        if table.rows.isEmpty { return table.loaded ? "No buff durations yet." : "Reading the buff model…" }
        return needle.isEmpty ? "No buff durations yet." : "No spells match \"\(query.trimmingCharacters(in: .whitespaces))\"."
    }

    /// Buffs first, then debuffs. A class with no MATCH disappears rather than printing its own
    /// empty state, so a search reads as one list narrowing rather than two tables arguing.
    private var shownSections: [StatsSection] {
        [StatsSection(id: "buff", label: "Buffs", rows: matching("buff")),
         StatsSection(id: "debuff", label: "Debuffs", rows: matching("debuff"))]
            .filter { !$0.rows.isEmpty }
    }

    /// The rows of one class that match the query. Already sorted by the builder.
    private func matching(_ cls: String) -> [BuffStatRow] {
        table.rows.filter { $0.cls == cls && (needle.isEmpty || $0.searchKey.contains(needle)) }
    }

    @ViewBuilder
    private func section(cls: String, label: String, rows: [BuffStatRow]) -> some View {
        let accent = BuffFormat.classAccent(cls)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 8, height: 8)
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.text)
                Text("\(rows.count)").font(.caption).foregroundStyle(Theme.textFaint)
            }
            VStack(spacing: 0) {
                BuffStatsHeaderRow(withBoxes: allow.optIn)
                Divider().overlay(Theme.border)
                ForEach(rows.prefix(maxRows)) { r in
                    BuffStatsRowView(row: r, withBoxes: allow.optIn)
                }
                if rows.count > maxRows {
                    Text("Showing the \(maxRows) most-sampled of \(rows.count). Search to narrow.")
                        .font(.caption).foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                }
            }
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .overlay(alignment: .leading) { Rectangle().fill(accent).frame(width: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct StatsSection: Identifiable {
    var id: String
    var label: String
    var rows: [BuffStatRow]
}

/// The column widths, in one place, so the two tables line up with each other.
private enum StatsColumns {
    static let box: CGFloat = 22
    static let estimate: CGFloat = 128
    static let n: CGFloat = 46
    static let median: CGFloat = 84
    static let iqr: CGFloat = 150
    static let range: CGFloat = 150
}

private struct BuffStatsHeaderRow: View {
    var withBoxes: Bool
    var body: some View {
        HStack(spacing: 8) {
            if withBoxes { Text("on").frame(width: StatsColumns.box, alignment: .leading) }
            Text("Spell").frame(maxWidth: .infinity, alignment: .leading)
            Text("estimate").frame(width: StatsColumns.estimate, alignment: .trailing)
            Text("n").frame(width: StatsColumns.n, alignment: .trailing)
            Text("median").frame(width: StatsColumns.median, alignment: .trailing)
            Text("IQR (p25-p75)").frame(width: StatsColumns.iqr, alignment: .trailing)
            Text("min-max").frame(width: StatsColumns.range, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }
}

/// One stats row. Everything not stated by a source renders as `-`, never as a zero.
private struct BuffStatsRowView: View {
    var row: BuffStatRow
    var withBoxes: Bool

    var body: some View {
        let est = BuffStatsBuilder.estimate(row)
        HStack(spacing: 8) {
            if withBoxes {
                BuffAllowCheck(spell: row.spell, dense: true).frame(width: StatsColumns.box, alignment: .leading)
            }
            Text(row.spell).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            estimateCell(ms: est.ms, src: est.src).frame(width: StatsColumns.estimate, alignment: .trailing)
            Text(row.n == 0 ? "0" : "\(row.n)")
                .foregroundStyle(row.n == 0 ? Theme.textFaint : Theme.text)
                .help(row.n == 0 ? "No cast→fade pair yet" : "")
                .frame(width: StatsColumns.n, alignment: .trailing)
            Text(BuffFormat.duration(row.medianMs)).frame(width: StatsColumns.median, alignment: .trailing)
            Text(pair(row.p25, row.p75)).foregroundStyle(Theme.textDim).frame(width: StatsColumns.iqr, alignment: .trailing)
            Text(pair(row.minMs, row.maxMs)).foregroundStyle(Theme.textFaint).frame(width: StatsColumns.range, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private func pair(_ lo: Double?, _ hi: Double?) -> String {
        guard let lo, let hi else { return "-" }
        return "\(BuffFormat.duration(lo)) - \(BuffFormat.duration(hi))"
    }

    /// The estimate cell: the figure plus a chip naming where it came from. A death bound is a
    /// FLOOR and wears a `≥`, never a bare figure that would read as a measurement.
    @ViewBuilder
    private func estimateCell(ms: Double?, src: String?) -> some View {
        if let ms {
            HStack(spacing: 4) {
                Text(BuffFormat.estimatePrefix(src) + BuffFormat.duration(ms))
                if let src {
                    Text(BuffFormat.sourceChip(src))
                        .font(.system(size: 9))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .overlay(Capsule().stroke(Theme.textFaint))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .help(BuffFormat.estimatorSourceTitle(src))
        } else {
            Text("-")
        }
    }
}
