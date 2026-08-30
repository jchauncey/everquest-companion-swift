import SwiftUI
import EQCompanionCore

/// The client's own spell table, searched by name/category/class the way the in-game Actions
/// window does it (`spells.search`), with the wiki card and the resist read-out for a pick.
struct SpellsView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var category = ""
    @State private var subcategory = ""
    @State private var classes: Set<String> = []
    @State private var sort = "level"
    @State private var offset = 0
    @State private var result: JSONValue = .null
    @State private var selected: String?
    private let limit = 100

    static let allClasses = ["BER", "BRD", "BST", "CLR", "DRU", "ENC", "MAG", "MNK", "NEC", "PAL", "RNG", "ROG", "SHD", "SHM", "WAR", "WIZ"]

    private struct SpellRow: Identifiable {
        var id: String
        var name: String
        var level: Int
        var classes: String
        var category: String
        var subcategory: String
    }

    private var rows: [SpellRow] {
        (result["spells"].array ?? []).enumerated().map { i, s in
            SpellRow(id: "\(i)|\(s["name"].display)", name: s["name"].string ?? "", level: s["level"].int ?? 0,
                     classes: (s["classes"].array ?? []).map { "\($0["class"].display) \($0["level"].display)" }.joined(separator: ", "),
                     category: s["category"].string ?? "", subcategory: s["subcategory"].string ?? "")
        }
    }

    var body: some View {
        NeedsEngine {
            HSplitView {
                VStack(spacing: 0) {
                    controls
                    if result["spellTable"].string == "missing" {
                        Text("No spells_us.txt at \(result["path"].display) — the client's spell table is what this searches.")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    Table(rows, selection: Binding(get: { selected.flatMap { s in rows.first { $0.name == s }?.id } },
                                                   set: { selected = $0.flatMap { id in rows.first { $0.id == id }?.name } })) {
                        TableColumn("Spell", value: \.name)
                        TableColumn("Level") { Text("\($0.level)").monospacedDigit() }.width(50)
                        TableColumn("Classes", value: \.classes).width(min: 140, ideal: 200)
                        TableColumn("Category", value: \.category).width(min: 100, ideal: 140)
                        TableColumn("Subcategory", value: \.subcategory).width(min: 100, ideal: 140)
                    }
                    footer
                }
                .frame(minWidth: 560, maxWidth: .infinity)
                if let s = selected {
                    VStack(spacing: 0) {
                        KnowledgeCard(domain: "spell", name: s)
                        Divider()
                        ResistReadout(spell: s).frame(height: 120)
                    }
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
                }
            }
            .task(id: "\(text)|\(category)|\(subcategory)|\(classes.sorted().joined())|\(sort)|\(offset)|\(model.epoch ?? 0)") {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { await search() }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Name, category or subcategory", text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Picker("Category", selection: $category) {
                    Text("Any").tag("")
                    ForEach((result["categories"].array ?? []).compactMap { $0["name"].string }, id: \.self) { Text($0).tag($0) }
                    if !category.isEmpty, !(result["categories"].array ?? []).contains(where: { $0["name"].string == category }) { Text(category).tag(category) }
                }.frame(maxWidth: 220)
                Picker("Sub", selection: $subcategory) {
                    Text("Any").tag("")
                    ForEach(subcategories, id: \.self) { Text($0).tag($0) }
                    if !subcategory.isEmpty, !subcategories.contains(subcategory) { Text(subcategory).tag(subcategory) }
                }.frame(maxWidth: 220)
                Picker("Sort", selection: $sort) { Text("Level").tag("level"); Text("Name").tag("name") }.frame(width: 110)
                Spacer()
            }
            HStack(spacing: 4) {
                ForEach(Self.allClasses, id: \.self) { c in
                    Toggle(c, isOn: Binding(get: { classes.contains(c) }, set: { on in if on { classes.insert(c) } else { classes.remove(c) }; offset = 0 }))
                        .toggleStyle(.button).controlSize(.small)
                }
                Button("All") { classes = [] }.controlSize(.small)
            }
        }
        .padding(8)
    }

    private var subcategories: [String] {
        let cats = result["categories"].array ?? []
        let scoped = category.isEmpty ? cats : cats.filter { $0["name"].string == category }
        return Array(Set(scoped.flatMap { ($0["subcategories"].array ?? []).compactMap(\.string) })).sorted()
    }

    private var footer: some View {
        HStack {
            Button { offset = max(0, offset - limit) } label: { Image(systemName: "chevron.left") }.disabled(offset == 0)
            let total = result["total"].int ?? 0
            Text("\(total == 0 ? 0 : offset + 1)–\(min(offset + limit, total)) of \(Format.count(total))").font(.caption).monospacedDigit()
            Button { offset += limit } label: { Image(systemName: "chevron.right") }.disabled(offset + limit >= (result["total"].int ?? 0))
            Spacer()
        }.padding(8)
    }

    private func search() async {
        var p: [String: JSONValue] = ["sort": .string(sort), "offset": .int(Int64(offset)), "limit": .int(Int64(limit))]
        if !text.isEmpty { p["text"] = .string(text) }
        if !category.isEmpty { p["category"] = .string(category) }
        if !subcategory.isEmpty { p["subcategory"] = .string(subcategory) }
        if !classes.isEmpty { p["classes"] = .array(classes.sorted().map { .string($0) }) }
        if let r = try? await model.client.request(Op.spellsSearch, .object(p)) { result = r }
    }
}

/// `resist.spell`: how the client's table says one spell is resisted.
struct ResistReadout: View {
    @Environment(AppModel.self) private var model
    var spell: String
    @State private var r: JSONValue = .null

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Resist (spells_us.txt)").font(.caption).foregroundStyle(.secondary)
            if let s = r["spell"].object {
                Text("Axis: \(s["axis"]?.display ?? "none") · adjust \(s["resistAdj"]?.display ?? "0") · mana \(s["mana"]?.display ?? "") · cast \(Format.clock(ms: s["castMs"]?.int64 ?? 0))")
                    .font(.callout)
                if let slot = s["damageSlot"]?.object {
                    Text("Damage slot: base \(slot["base"]?.display ?? "") calc \(slot["calc"]?.display ?? "") max \(slot["max"]?.display ?? "")").font(.caption)
                }
                if let d = s["debuffSlots"]?.array, !d.isEmpty {
                    Text("Debuffs: " + d.map { "\($0["axis"].display) \($0["amount"].display)" }.joined(separator: ", ")).font(.caption)
                }
            } else if !r.isNull {
                Text("Table \(r["table"].display): nothing for this name.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: spell) { r = (try? await model.client.request(Op.resistSpell, ["name": .string(spell)])) ?? .null }
    }
}
