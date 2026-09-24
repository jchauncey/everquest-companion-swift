// The Motes tab: where the motes come from, as a table you can regroup.
//
// One fold (`MoteStats`) drawn five ways: per mob at a difficulty (the default), or summed by zone,
// by difficulty, by named-vs-trash, or by level band - because "which golem" and "is D3 worth it"
// and "do nameds pay" are the same numbers at different grain. Filters narrow the rows BEFORE the
// regroup, so a zone filter plus "by difficulty" answers "how do Hate's tiers compare".
import SwiftUI
import EQCompanionCore

struct MotesView: View {
    @Environment(AppModel.self) private var model
    @State private var lootSnap = ModuleSnapshot()
    @State private var killSnap = ModuleSnapshot()
    @State private var conSnap = ModuleSnapshot()
    @State private var rows: [MoteRow] = []

    @State private var groupBy: MoteGroupBy = .mob
    @State private var zones: Set<String> = []
    @State private var tiers: Set<String> = []
    @State private var which = "all"          // all | named | trash
    @State private var withMotesOnly = true
    @State private var sortKey = "motes"
    @State private var sortDescending = true
    @State private var widths = ColumnWidths("eq.motes.columnWidths")

    var body: some View {
        NeedsEngine {
            VStack(alignment: .leading, spacing: 8) {
                controls
                summary
                table
            }
            .padding(12)
            .background(Theme.background)
            .task(id: "\(model.moduleSeqs["loot"] ?? 0)|\(model.epoch ?? 0)") { await lootSnap.refresh(model, module: "loot"); refold() }
            .task(id: "\(model.moduleSeqs["kills"] ?? 0)|\(model.epoch ?? 0)") { await killSnap.refresh(model, module: "kills"); refold() }
            .task(id: "\(model.moduleSeqs["consider"] ?? 0)|\(model.epoch ?? 0)") { await conSnap.refresh(model, module: "consider"); refold() }
        }
    }

    // MARK: - The fold

    private func refold() {
        rows = MoteStats.rows(loot: lootSnap.state, kills: killSnap.state, consider: conSnap.state)
    }

    private var filtered: [MoteRow] {
        rows.filter { r in
            if withMotesOnly && r.motes == 0 { return false }
            if !zones.isEmpty && !zones.contains(r.zone) { return false }
            if !tiers.isEmpty && !tiers.contains(String(r.tier)) { return false }
            switch which {
            case "named": return r.named
            case "trash": return !r.named
            default: return true
            }
        }
    }

    private var shown: [MoteRow] {
        MoteStats.group(filtered, by: groupBy)
            .sorted { MoteStats.compare($0, $1, key: sortKey, descending: sortDescending) }
    }

    private var grades: [String] { MoteStats.grades(filtered) }

    // MARK: - Controls

    private var zoneOptions: [String] {
        Array(Set(rows.map(\.zone))).filter { !$0.isEmpty }.sorted()
    }
    private var tierOptions: [String] {
        Array(Set(rows.map(\.tier))).sorted().map(String.init)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 8, lineSpacing: 8) {
                Picker("", selection: $groupBy) {
                    ForEach(MoteGroupBy.allCases) { g in Text(g.label).tag(g) }
                }
                .pickerStyle(.segmented).frame(width: 420)
                .help("The same numbers at a coarser grain. A group's rate is its corpses over its kills, never an average of averages.")
                FilterMultiPicker(title: "Zones", empty: "everywhere", options: zoneOptions, selection: $zones,
                                  placeholder: "Find a zone\u{2026}")
                FilterMultiPicker(title: "Difficulty", empty: "every tier", options: tierOptions, selection: $tiers,
                                  label: { ZoneTier.longLabel(Int($0) ?? ZoneTier.unknown) },
                                  placeholder: "Find a tier\u{2026}")
                Picker("", selection: $which) {
                    Text("All mobs").tag("all"); Text("Named").tag("named"); Text("Trash").tag("trash")
                }
                .pickerStyle(.segmented).frame(width: 220)
                Button { withMotesOnly.toggle() } label: {
                    Chip(text: "Only mobs that gave a mote", color: withMotesOnly ? Theme.gold : Theme.textDim, filled: withMotesOnly)
                }
                .buttonStyle(.plain)
                .help("Off, every counted kill is a row, and a zero is a fact about that mob rather than an absence from the table.")
            }
        }
    }

    private var summary: some View {
        let rs = filtered
        let kills = rs.reduce(0) { $0 + $1.kills }, corpses = rs.reduce(0) { $0 + $1.corpses }, motes = rs.reduce(0) { $0 + $1.motes }
        return HStack(spacing: 14) {
            stat("Kills", Format.count(kills))
            stat("Corpses with a mote", Format.count(corpses))
            stat("Motes", Format.count(motes))
            stat("Drop rate", kills > 0 ? String(format: "%.1f%%", min(100, Double(corpses) / Double(kills) * 100)) : LootFmt.none)
            stat("Motes per kill", kills > 0 ? String(format: "%.2f", Double(motes) / Double(kills)) : LootFmt.none)
            Spacer()
            Text("Rates are yours: a corpse a group-mate looted leaves the kill in your count and the mote out of your log.")
                .font(.caption2).foregroundStyle(Theme.textFaint).lineLimit(2)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(Theme.textDim)
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.text)
        }
    }

    // MARK: - The table

    private var columns: [DataColumn] {
        var cols: [DataColumn] = [DataColumn(key: "mob", label: groupBy == .mob ? "Mob" : groupBy.label, width: 260)]
        if groupBy == .mob || groupBy == .zone {
            if groupBy == .mob { cols.append(DataColumn(key: "zone", label: "Zone", width: 170)) }
            cols.append(DataColumn(key: "tier", label: "Difficulty", width: 110))
        }
        if groupBy == .mob {
            cols.append(DataColumn(key: "level", label: "Level", width: 60, trailing: true))
            cols.append(DataColumn(key: "named", label: "Kind", width: 84))
        }
        cols += [
            DataColumn(key: "kills", label: "Kills", width: 64, trailing: true),
            DataColumn(key: "corpses", label: "Corpses w/ mote", width: 110, trailing: true),
            DataColumn(key: "rate", label: "Drop rate", width: 80, trailing: true),
            DataColumn(key: "motes", label: "Motes", width: 64, trailing: true),
            DataColumn(key: "perKill", label: "Per kill", width: 70, trailing: true)
        ]
        for g in grades { cols.append(DataColumn(key: "grade:" + g, label: MoteLadder.label(g), width: 90, trailing: true)) }
        cols.append(DataColumn(key: "last", label: "Last", width: 130, trailing: true))
        return cols
    }

    private var table: some View {
        DataTableView(
            columns: columns, rows: shown, widths: widths,
            sortKey: $sortKey, sortDescending: $sortDescending,
            emptyText: rows.isEmpty
                ? "No motes in this log yet. They arrive as `--You have looted a Mote of Potential from <mob>'s corpse.--` lines."
                : "Nothing matches the filters.",
            cell: { c, r in cell(c, r) },
            onRowTap: groupBy == .mob ? { r in MapJump.shared.show(mob: r.mob, zonesLongNames: r.zone.isEmpty ? [] : [r.zone]) } : nil)
    }

    private static let when: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f
    }()

    @ViewBuilder
    private func cell(_ c: DataColumn, _ r: MoteRow) -> some View {
        switch c.key {
        case "mob": Text(r.mob).foregroundStyle(groupBy == .mob ? Theme.gold : Theme.text).lineLimit(1)
        case "zone": Text(r.zone.isEmpty ? LootFmt.none : r.zone).foregroundStyle(Theme.textDim).lineLimit(1)
        case "tier":
            let s = RaidTier.style(r.tier)
            Chip(text: s.long, color: s.bg, filled: true).help(s.long)
        case "level": Text(r.level.map(String.init) ?? LootFmt.none).monospacedDigit().foregroundStyle(Theme.textDim)
        case "named": Chip(text: r.named ? "named" : "trash", color: r.named ? Theme.gold : Theme.textDim)
        case "kills": Text(Format.count(r.kills)).monospacedDigit()
        case "corpses": Text(Format.count(r.corpses)).monospacedDigit()
        case "rate": Text(r.rate.map { String(format: "%.1f%%", $0 * 100) } ?? LootFmt.none).monospacedDigit()
                .foregroundStyle(r.rate == nil ? Theme.textFaint : Theme.text)
        case "motes": Text(Format.count(r.motes)).monospacedDigit().foregroundStyle(Theme.gold)
        case "perKill": Text(r.perKill.map { String(format: "%.2f", $0) } ?? LootFmt.none).monospacedDigit()
                .foregroundStyle(r.perKill == nil ? Theme.textFaint : Theme.text)
        case "last": Text(r.lastTs > 0 ? Self.when.string(from: Date(timeIntervalSince1970: Double(r.lastTs) / 1000)) : LootFmt.none)
                .font(.caption).foregroundStyle(Theme.textDim)
        default:
            if c.key.hasPrefix("grade:") {
                let n = r.byGrade[String(c.key.dropFirst(6))] ?? 0
                Text(n > 0 ? Format.count(n) : LootFmt.none).monospacedDigit().foregroundStyle(n > 0 ? Theme.text : Theme.textFaint)
            } else { Text("") }
        }
    }
}
