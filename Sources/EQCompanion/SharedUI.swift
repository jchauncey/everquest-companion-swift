import SwiftUI
import EQCompanionCore

/// Wall-clock milliseconds now.
func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

/// A knowledge card for one name, fetched from the engine's committed corpora on appearance.
struct KnowledgeCard: View {
    @Environment(AppModel.self) private var model
    var domain: String
    var name: String
    @State private var result: JSONValue = .null
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(name).font(.title3.weight(.semibold))
                    Text(domain).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    Spacer()
                }
                if let e = error {
                    Text(e).foregroundStyle(.red).font(.caption)
                } else if result.isNull {
                    ProgressView().controlSize(.small)
                } else if result["found"].bool == false {
                    Text("Nothing on record for this \(domain).").foregroundStyle(.secondary)
                    if !result["record"].isNull { RecordView(record: result["record"]) }
                } else {
                    RecordView(record: result["record"])
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(domain)|\(name)") { await load() }
    }

    private func load() async {
        result = .null
        error = nil
        guard model.client.isReady else { return }
        let op: String
        switch domain {
        case "item": op = Op.knowledgeItem
        case "mob": op = Op.knowledgeMob
        case "spell": op = Op.knowledgeSpell
        default: error = "No card for a \(domain)."; return
        }
        do { result = try await model.client.request(op, ["name": .string(name)]) }
        catch { self.error = "\(error)" }
    }
}

/// Renders an open-shaped record: the keys the corpora are known to carry get their own layout,
/// everything else falls through to a generic key/value grid. Nothing is parsed back out of a
/// string; the engine's own wording is what is shown.
struct RecordView: View {
    var record: JSONValue

    private static let hidden: Set<String> = ["cached", "found", "queried", "name", "key"]
    private static let first: [String] = ["summary", "levelText", "zone", "classes", "spellType", "targetType", "durationText",
                                          "statsBlock", "effects", "msgCastOnYou", "msgCastOnOther", "msgWearsOff", "page"]

    var body: some View {
        let o = record.object ?? [:]
        let keys = Self.first.filter { o[$0] != nil } + o.keys.filter { !Self.first.contains($0) && !Self.hidden.contains($0) }.sorted()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(keys, id: \.self) { k in
                field(k, o[k] ?? .null)
            }
        }
    }

    @ViewBuilder
    private func field(_ key: String, _ v: JSONValue) -> some View {
        switch v {
        case .null:
            EmptyView()
        case .array(let a) where a.isEmpty:
            EmptyView()
        case .array(let a) where a.allSatisfy({ $0.object == nil && $0.array == nil }):
            VStack(alignment: .leading, spacing: 2) {
                Text(label(key)).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(a.enumerated()), id: \.offset) { _, x in Text("• \(x.display)").font(.callout) }
            }
        case .array(let a):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(label(key)) (\(a.count))").font(.caption).foregroundStyle(.secondary)
                ObjectListView(items: a)
            }
        case .object(let o):
            VStack(alignment: .leading, spacing: 2) {
                Text(label(key)).font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(o.keys.sorted(), id: \.self) { k in
                        GridRow {
                            Text(label(k)).foregroundStyle(.secondary)
                            Text(o[k]?.display ?? "")
                        }.font(.callout)
                    }
                }
            }
        case .string(let s) where s.contains("\n") || key == "statsBlock":
            VStack(alignment: .leading, spacing: 2) {
                Text(label(key)).font(.caption).foregroundStyle(.secondary)
                Text(s).font(.callout.monospaced()).textSelection(.enabled)
            }
        default:
            HStack(alignment: .firstTextBaseline) {
                Text(label(key)).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                Text(v.display).font(.callout).textSelection(.enabled)
            }
        }
    }

    private func label(_ key: String) -> String {
        var out = ""
        for ch in key {
            if ch.isUppercase { out += " " }
            out.append(ch)
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

/// A list of same-shaped objects as a compact table: the union of keys as columns.
struct ObjectListView: View {
    var items: [JSONValue]

    var body: some View {
        let keys: [String] = {
            var seen: [String] = []
            for i in items { for k in (i.object ?? [:]).keys where !seen.contains(k) { seen.append(k) } }
            return seen.sorted()
        }()
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    ForEach(keys, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                ForEach(Array(items.prefix(200).enumerated()), id: \.offset) { _, it in
                    GridRow {
                        ForEach(keys, id: \.self) { k in
                            cellView(k, it)
                        }
                    }
                }
            }
        }
    }

    /// A mob, zone or item cell is a door to its own surface; everything else is text. The keys
    /// are the knowledge records' own column names (dropsFrom: mob/zone; drop tables: item).
    @ViewBuilder
    private func cellView(_ key: String, _ row: JSONValue) -> some View {
        let text = cell(row[key])
        switch key {
        case "mob" where !text.isEmpty:
            linkCell(text) {
                let zones = [row["zone"], row["eraZones"]].flatMap { v -> [String] in
                    if let s = v.string { return [s] }
                    return (v.array ?? []).compactMap(\.string)
                }
                MapJump.shared.show(mob: text, zonesLongNames: zones)
            }
        case "zone" where !text.isEmpty:
            linkCell(text) { MapJump.shared.showZone(named: text) }
        case "item" where !text.isEmpty:
            linkCell(text) { ItemJump.shared.show(name: text) }
        default:
            Text(text).font(.callout).lineLimit(1)
        }
    }

    private func linkCell(_ text: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(text).font(.callout).foregroundStyle(Theme.gold).underline().lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cell(_ v: JSONValue) -> String {
        switch v {
        case .array(let a): return a.map(\.display).joined(separator: ", ")
        default: return v.display
        }
    }
}

/// A small stat tile.
struct Stat: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

/// A view-state aware container: loading spinner, error line, or the rows.
struct WindowStatus: View {
    var live: LiveView
    var body: some View {
        if let e = live.error { Text(e).foregroundStyle(.red).font(.caption) }
        else if live.loading { ProgressView().controlSize(.small) }
        else { EmptyView() }
    }
}

extension Row {
    var at: Int64 { self["at"].int64 ?? 0 }
}
