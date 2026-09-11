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
    /// The spelling that actually answered, when it was not the one asked for.
    @State private var resolved: String?

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
                } else if let r = resolved {
                    // Say whose spelling this record is: the page found is not the name clicked.
                    Text("Listed on the wiki as \u{201C}\(r)\u{201D}.").font(.caption).foregroundStyle(.secondary)
                    RecordView(record: result["record"])
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
        resolved = nil
        guard model.client.isReady else { return }
        let op: String
        switch domain {
        case "item": op = Op.knowledgeItem
        case "mob": op = Op.knowledgeMob
        case "spell": op = Op.knowledgeSpell
        default: error = "No card for a \(domain)."; return
        }
        do {
            var answer = try await model.client.request(op, ["name": .string(name)])
            // A page the naming page spelled with (or without) a leading article. The alternative
            // is not guessed at the engine: the committed corpus is asked which spelling it HAS,
            // and only a spelling it actually carries is requested.
            if answer["found"].bool == false,
               let alt = GameData.shared.articleVariant(domain: domain, of: name) {
                let second = try await model.client.request(op, ["name": .string(alt)])
                if second["found"].bool != false { answer = second; resolved = alt }
            }
            // The mob pages' drop rows, joined here rather than in the engine: `knowledge.item` is
            // an answer the golden oracle pins. Each joined row says `via`. See MobPageDrops.
            result = domain == "item" ? GameData.shared.withMobPageDrops(answer: answer) : answer
            // Then your own log, the way the Loot tab reads it. The card is already drawn by now,
            // so a slow or failed snapshot costs the counts and nothing else.
            if domain == "item", result["found"].bool != false {
                let snap = ModuleSnapshot()
                await snap.refresh(model, module: "loot")
                let state = snap.state
                let events = await Task.detached(priority: .userInitiated) { LootEvent.parse(state) }.value
                result = GameData.shared.withOwnLoot(answer: result, item: resolved ?? name, events: events)
            }
        } catch { self.error = "\(error)" }
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
            // A raw sub-object (the parser's own "stats" vector and its kin) is bookkeeping, not
            // reading matter: folded away by default, one click to unfold.
            CollapsedObject(title: label(key), object: o, label: label)
        case .string(let s) where s.contains("\n") || key == "statsBlock":
            VStack(alignment: .leading, spacing: 2) {
                Text(label(key)).font(.caption).foregroundStyle(.secondary)
                // The wiki text separates every line with a blank one; squeezed here, the block
                // reads like the item window instead of a double-spaced page.
                WikiProse(lines: s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty })
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

/// A row of controls that WRAPS rather than clipping.
///
/// Used by the Maps toolbar and the Gear filters, for the same reason in both: every control in
/// such a row is how you get out of the state you are in, so none of them may fall off the end at a
/// narrow window.
///
/// The `nil` proposal answer is the load-bearing part. A plain `HStack` reports its ideal width as
/// the whole unwrapped line, and an ancestor sized by that ideal becomes wider than the pane it
/// sits in - which does not clip, it CENTRES, dragging every sibling left. That is how the gear
/// filters, off the right edge of a narrow window, pushed the table underneath the sidebar and cut
/// the item names in half. Answering with the widest single child instead says "I can be as narrow
/// as my biggest control", and the row wraps to fit rather than shoving its neighbours aside.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func rows(_ sizes: [CGSize], width: CGFloat) -> [[Int]] {
        var out: [[Int]] = [[]]
        var x: CGFloat = 0
        for (i, s) in sizes.enumerated() {
            let w = s.width
            if !out[out.count - 1].isEmpty && x + spacing + w > width {
                out.append([i])
                x = w
            } else {
                if !out[out.count - 1].isEmpty { x += spacing }
                out[out.count - 1].append(i)
                x += w
            }
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // An unbounded proposal (a split view probing) must not be echoed back as our width —
        // an infinite answer wrecks every ancestor. Answer with the one-line width instead.
        // Nil ("what is your ideal?") gets the widest child — the flow can wrap to that; a flow
        // whose ideal is one unwrapped line makes every ancestor want to be that wide.
        let width: CGFloat
        if let w = proposal.width, w.isFinite { width = w }
        else if proposal.width == nil { width = sizes.map(\.width).max() ?? 0 }
        else { width = sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1)) }
        let lines = rows(sizes, width: width)
        var h: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let lh = line.map { sizes[$0].height }.max() ?? 0
            h += lh + (i > 0 ? lineSpacing : 0)
        }
        return CGSize(width: width, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for line in rows(sizes, width: bounds.width) {
            let lh = line.map { sizes[$0].height }.max() ?? 0
            var x = bounds.minX
            for i in line {
                subviews[i].place(at: CGPoint(x: x, y: y + (lh - sizes[i].height) / 2),
                                  proposal: ProposedViewSize(sizes[i]))
                x += sizes[i].width + spacing
            }
            y += lh + lineSpacing
        }
    }
}

/// Where a wiki link in a record's prose goes. A surface that can host a spell card provides this;
/// where nobody can (a bare list, a tooltip), the link renders as plain text rather than as a
/// button that would do nothing.
struct OpenSpellKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var openSpell: ((String) -> Void)? {
        get { self[OpenSpellKey.self] }
        set { self[OpenSpellKey.self] = newValue }
    }
}

/// The wiki's own prose, with its markup interpreted at the last moment: `[[Soul Leech|…]]` reads
/// as "Soul Leech" and opens the spell when there is somewhere to open it.
struct WikiProse: View {
    var lines: [String]
    @Environment(\.openSpell) private var openSpell

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if WikiMarkup.hasMarkup(line) {
                    // A line with markup is laid out run by run, so the link can be a button. It
                    // wraps at the run boundary rather than mid-word, which the Effect line needs.
                    FlowRow(spacing: 0, lineSpacing: 1) {
                        ForEach(Array(WikiMarkup.runs(line).enumerated()), id: \.offset) { _, run in
                            if let target = run.link, let open = openSpell {
                                Button { open(target) } label: {
                                    Text(run.text).font(.callout.monospaced())
                                        .foregroundStyle(Theme.gold).underline()
                                }
                                .buttonStyle(.plain)
                                .help("What \(target) does")
                            } else {
                                Text(run.text).font(.callout.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    Text(line).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}

/// A record's raw sub-object, collapsed by default.
private struct CollapsedObject: View {
    var title: String
    var object: [String: JSONValue]
    var label: (String) -> String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9))
                    Text(title)
                    Text("(\(object.count))").foregroundStyle(Theme.textFaint)
                }
                .font(.caption).foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(object.keys.sorted(), id: \.self) { k in
                        GridRow {
                            Text(label(k)).foregroundStyle(.secondary)
                            Text(object[k]?.display ?? "")
                        }.font(.callout)
                    }
                }
            }
        }
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
