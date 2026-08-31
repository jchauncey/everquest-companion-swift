// The one search box: zones, mobs and items from anywhere, each hit jumping to the surface that
// owns it — a zone or mob lands on the map (the mob with its card open), an item opens the Gear
// table's card. Built to grow: a new kind is one more section and one more jump.
import SwiftUI
import Observation

/// A request to open the Gear tab on one item's card. Written here, consumed by GearTableView.
@MainActor
@Observable
final class ItemJump {
    static let shared = ItemJump()

    struct Pending: Equatable {
        var name: String
        var seq: Int
    }

    private(set) var pending: Pending?
    private var seq = 0

    func show(name: String) {
        seq += 1
        pending = Pending(name: name, seq: seq)
        UserDefaults.standard.set(Tab.gear.rawValue, forKey: "eq.tab")
        UserDefaults.standard.set("gear", forKey: "eq.gear.tab")
    }

    func clear() { pending = nil }
}

/// One hit, whatever its kind. `subtitle` is the disambiguator (a zone's short, a mob's level and
/// zone, an item's slots).
private struct SearchHit: Identifiable {
    enum Kind: String { case zone, mob, item }
    var kind: Kind
    var title: String
    var subtitle: String
    var act: () -> Void
    var id: String { "\(kind.rawValue)|\(title)" }
}

struct GlobalSearchField: View {
    @State private var query = ""
    @State private var open = false
    @State private var highlighted = 0
    @State private var index = GearIndex.shared

    private var hits: [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2 else { return [] }
        var out: [SearchHit] = []
        // Zones: name or short, prefix before contains.
        let zones = GameData.shared.zones
            .filter { $0.name.lowercased().contains(q) || $0.short.lowercased().contains(q) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(q) || a.short.lowercased().hasPrefix(q)
                let bp = b.name.lowercased().hasPrefix(q) || b.short.lowercased().hasPrefix(q)
                return ap != bp ? ap : a.name < b.name
            }
            .prefix(5)
        for z in zones {
            out.append(SearchHit(kind: .zone, title: z.name, subtitle: z.short) {
                MapJump.shared.showZone(z.short)
            })
        }
        // Mobs: the catalog's own fuzzy ranking.
        for m in MobCatalogIndex.shared.search(query).prefix(8) {
            let sub = [m.level.isEmpty ? nil : "Lvl \(m.level)", m.zones.first].compactMap { $0 }.joined(separator: " · ")
            out.append(SearchHit(kind: .mob, title: m.name, subtitle: sub) {
                MapJump.shared.show(mob: m.name, zonesLongNames: m.zones)
            })
        }
        // Items: the Gear index, ranked the way the wish-list picker ranks.
        let items = index.rows
            .filter { $0.searchKey.contains(q) }
            .sorted { a, b in
                func rank(_ r: GearRow) -> Int {
                    let n = r.name.lowercased()
                    if n.hasPrefix(q) { return 0 }
                    if n.contains(q) { return 1 }
                    return 2
                }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                if a.name.count != b.name.count { return a.name.count < b.name.count }
                return a.name < b.name
            }
            .prefix(8)
        for r in items {
            out.append(SearchHit(kind: .item, title: r.name, subtitle: r.slots.joined(separator: " ")) {
                ItemJump.shared.show(name: r.name)
            })
        }
        return out
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textDim).font(.caption)
            TextField("Search zones, mobs, items…", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 210)
                .onChange(of: query) { _, q in
                    highlighted = 0
                    open = q.trimmingCharacters(in: .whitespaces).count >= 2
                    if open { index.start() }
                }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.escape) { open = false; return .handled }
                .onSubmit { pickHighlighted() }
        }
        // No box of our own: the toolbar already draws a capsule around its items, and a second
        // border inside it reads as two input boxes.
        .padding(.horizontal, 4)
        .popover(isPresented: $open, arrowEdge: .bottom) { results }
    }

    private var results: some View {
        let rows = hits
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        Text("Nothing matches “\(query)”.").font(.caption).foregroundStyle(Theme.textFaint)
                            .padding(8)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, h in
                        if i == 0 || rows[i - 1].kind != h.kind { sectionHeader(h.kind) }
                        Button { pick(h) } label: {
                            HStack(spacing: 8) {
                                Text(h.title).font(.callout).foregroundStyle(Theme.text).lineLimit(1)
                                Spacer(minLength: 6)
                                if !h.subtitle.isEmpty {
                                    Text(h.subtitle).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(i == highlighted ? Theme.gold.opacity(0.22) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(h.id)
                    }
                }
                .padding(8)
            }
            .frame(width: 380, height: 340)
            .background(Theme.background)
            .onChange(of: highlighted) { _, i in
                if rows.indices.contains(i) { proxy.scrollTo(rows[i].id) }
            }
        }
    }

    private func sectionHeader(_ k: SearchHit.Kind) -> some View {
        Text(k == .zone ? "ZONES" : k == .mob ? "MOBS" : "ITEMS")
            .font(.caption2.weight(.bold)).kerning(0.8).foregroundStyle(Theme.textDim)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func move(_ d: Int) {
        let n = hits.count
        guard n > 0 else { return }
        highlighted = min(max(0, highlighted + d), n - 1)
    }

    private func pickHighlighted() {
        let rows = hits
        guard rows.indices.contains(highlighted) else { return }
        pick(rows[highlighted])
    }

    private func pick(_ h: SearchHit) {
        h.act()
        open = false
        query = ""
    }
}
