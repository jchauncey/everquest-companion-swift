import SwiftUI
import EQCompanionCore

/// Name search across every corpus the engine holds (items, mobs, spells, quests) and the card
/// for whatever is picked.
struct KnowledgeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var domain = ""
    @State private var hits: [JSONValue] = []
    @State private var total = 0
    @State private var selected: JSONValue?
    @State private var searching = false

    var body: some View {
        NeedsEngine {
            HSplitView {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search items, mobs, spells…", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await search() } }
                        Picker("", selection: $domain) {
                            Text("All").tag("")
                            Text("Items").tag("item")
                            Text("Mobs").tag("mob")
                            Text("Spells").tag("spell")
                            Text("Quests").tag("quest")
                        }.labelsHidden().frame(width: 100)
                        Button("Search") { Task { await search() } }.keyboardShortcut(.defaultAction)
                        if searching { ProgressView().controlSize(.small) }
                    }.padding(8)
                    List(hits, id: \.self, selection: $selected) { h in
                        HStack {
                            Text(h["domain"].display).font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            Text(h["name"].display)
                        }.tag(h)
                    }
                    .listStyle(.inset)
                    Text(hits.isEmpty ? "" : "\(hits.count) of \(total) matches").font(.caption).foregroundStyle(.secondary).padding(6)
                }
                .frame(minWidth: 320, idealWidth: 380, maxWidth: 480)
                if let s = selected, let n = s["name"].string {
                    KnowledgeCard(domain: s["domain"].string ?? "item", name: n).frame(minWidth: 380, maxWidth: .infinity)
                } else {
                    ContentUnavailableView("Pick a result", systemImage: "book", description: Text("Item cards say what a lore or quest item is for and who drops it; mob cards say what it drops, on the wiki and in your own log; spell cards carry effects, messages and durations."))
                        .frame(minWidth: 380, maxWidth: .infinity)
                }
            }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if !Task.isCancelled { await search() }
            }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { hits = []; total = 0; return }
        searching = true
        defer { searching = false }
        var params: [String: JSONValue] = ["query": .string(q), "limit": 100]
        if !domain.isEmpty { params["domain"] = .string(domain) }
        if let r = try? await model.client.request(Op.knowledgeSearch, .object(params)) {
            hits = r["hits"].array ?? []
            total = r["total"].int ?? hits.count
        }
    }
}
