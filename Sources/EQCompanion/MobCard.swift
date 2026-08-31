// The mob card the map shows when a pin is clicked, and the cross-tab jump that opens it: the
// Mobs page's "Show on map" lands here, and the map's pin popover leads item-by-item into the
// same scaled stats the Gear table shows. One card, two doors.
import SwiftUI
import Observation

/// A request to open the Maps tab on a zone and put the camera on a mob. Written by any tab,
/// consumed (and cleared) by MapsView. The seq makes a repeat of the same mob a fresh request.
@MainActor
@Observable
final class MapJump {
    static let shared = MapJump()

    struct Pending: Equatable {
        var zone: ZoneShort?
        var mob: String
        var seq: Int
    }

    private(set) var pending: Pending?
    private var seq = 0

    /// Jump to `mob`, opening the first of its wiki zones that names a known map zone.
    func show(mob: String, zonesLongNames: [String]) {
        let zones = GameData.shared.zones
        let short = zonesLongNames.lazy.compactMap { long in
            zones.first { $0.name.caseInsensitiveCompare(long) == .orderedSame }?.short
        }.first
        seq += 1
        pending = Pending(zone: short, mob: mob, seq: seq)
        UserDefaults.standard.set(Tab.maps.rawValue, forKey: "eq.tab")
    }

    func clear() { pending = nil }
}

/// The popover card for one mob: level and zones off the committed catalog, the wiki drop table
/// with every item clickable, and the engine's own record underneath. Clicking a drop swaps the
/// card for that item's scaled stats; Back returns.
struct MobCardView: View {
    var name: String
    @State private var item: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                ItemScaleView(name: item) { self.item = nil }
            } else {
                mobBody
            }
        }
        .padding(12)
        .frame(width: 380, height: 520, alignment: .topLeading)
        .background(Theme.background)
    }

    @ViewBuilder private var mobBody: some View {
        let m = GameData.shared.mob(named: name)
        HStack(spacing: 8) {
            Text(name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if let l = m?.level, !l.isEmpty { Chip(text: "Lvl \(l)") }
        }
        if let m, !m.zones.isEmpty {
            Text(m.zones.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
        }
        if let m {
            Card("DROPS (WIKI)") {
                if m.drops.isEmpty {
                    Text("The page lists no loot for \(m.name).").font(.callout).foregroundStyle(Theme.textFaint)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(m.drops, id: \.self) { d in
                                Button { item = d } label: {
                                    HStack(spacing: 4) {
                                        Text(d).font(.callout).foregroundStyle(Theme.gold)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Theme.textFaint)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        } else {
            Text("The mob catalog has no page for \(name).").font(.caption).foregroundStyle(Theme.textFaint)
        }
        KnowledgeCard(domain: "mob", name: name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One item at the wiki's upgrade slider: the +N tiers scale every stat exactly as the Gear
/// table scales them (`GearRow.scaled`), because both are the item window's own arithmetic.
struct ItemScaleView: View {
    var name: String
    var onBack: () -> Void

    @State private var index = GearIndex.shared
    @State private var tier = 0
    @State private var fraction = 0

    private var state: ItemUpgradeState { ItemUpgradeState(full: tier, fraction: fraction).normalized }

    private var row: GearRow? {
        index.rows.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            ?? index.rows.first { $0.name.lowercased().hasPrefix(name.lowercased()) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { onBack() } label: {
                HStack(spacing: 3) { Image(systemName: "chevron.left"); Text("Back") }.font(.caption)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.gold)
            Text(name).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
        }
        if let r = row {
            if !r.slots.isEmpty {
                Text(r.slots.joined(separator: " ")).font(.caption).foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 8) {
                Text("Upgrade").font(.caption).foregroundStyle(Theme.textDim)
                Slider(value: Binding(
                    get: { Double(tier) },
                    set: { v in
                        tier = Int(v.rounded())
                        fraction = min(fraction, max(0, (1 << max(0, min(9, tier))) - 1))
                    }), in: 0...Double(GearUpgrade.maxTier), step: 1)
                Text(tier == 0 ? "base" : "+\(tier)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tier == 0 ? Theme.textDim : Theme.gold)
                    .frame(width: 38, alignment: .trailing)
            }
            if tier > 0 && tier < GearUpgrade.maxTier {
                HStack(spacing: 8) {
                    Text("Partial").font(.caption).foregroundStyle(Theme.textDim)
                    Slider(value: Binding(get: { Double(fraction) }, set: { fraction = Int($0.rounded()) }),
                           in: 0...Double((1 << tier) - 1), step: 1)
                    Text("\(fraction)/\(1 << tier)").font(.caption.monospacedDigit()).foregroundStyle(Theme.textDim)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            Text(state.percentLabel).font(.caption).foregroundStyle(tier == 0 && fraction == 0 ? Theme.textFaint : Theme.gold)
            statGrid(r.scaled(state))
            Spacer(minLength: 0)
        } else {
            // Not a gear row (a page, a gem, a quest piece): the knowledge card is what is known.
            KnowledgeCard(domain: "item", name: name)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { index.start() }
        }
    }

    private func statGrid(_ stats: [String: Int]) -> some View {
        let rows = stats.filter { $0.value != 0 }.sorted { $0.key < $1.key }
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 82), spacing: 6)], alignment: .leading, spacing: 4) {
                ForEach(rows, id: \.key) { k, v in
                    HStack(spacing: 3) {
                        Text(k).font(.caption2).foregroundStyle(Theme.textDim)
                        Text(v > 0 ? "+\(v)" : "\(v)").font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.paperRaised))
                }
            }
        }
    }
}
