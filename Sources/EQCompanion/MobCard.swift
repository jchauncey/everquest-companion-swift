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
        /// Every zone this mob could be shown in, when the jump named more than one. The map asks
        /// which to open; empty or one-element means there was nothing to ask.
        var zoneChoices: [ZoneShort] = []
        var mob: String
        var seq: Int
    }

    private(set) var pending: Pending?
    private var seq = 0

    /// Jump to `mob`. Its wiki zones are resolved to known map zones (article-tolerant, so
    /// "Plane of Hate" finds "The Plane of Hate"); a single match opens straight away, several
    /// leave the map to ask which zone the player wants.
    func show(mob: String, zonesLongNames: [String]) {
        var shorts: [ZoneShort] = []
        for long in zonesLongNames {
            guard let s = GameData.shared.zone(forLogName: long)?.short, !shorts.contains(s) else { continue }
            shorts.append(s)
        }
        seq += 1
        pending = Pending(zone: shorts.count == 1 ? shorts[0] : nil,
                          zoneChoices: shorts.count > 1 ? shorts : [],
                          mob: mob, seq: seq)
        UserDefaults.standard.set(Tab.maps.rawValue, forKey: "eq.tab")
    }

    /// The player picked one of a multi-zone jump's choices. Same mob and seq — a resolution of the
    /// pending request, not a new one.
    func resolveChoice(_ zone: ZoneShort) {
        guard let p = pending else { return }
        pending = Pending(zone: zone, zoneChoices: [], mob: p.mob, seq: p.seq)
    }

    /// Jump to a zone stated by its LONG name (a knowledge record's "zone" cell). Article-tolerant,
    /// so a "Plane of Hate" cell opens "The Plane of Hate".
    func showZone(named long: String) {
        guard let short = GameData.shared.zone(forLogName: long)?.short else { return }
        showZone(short)
    }

    /// Jump to a zone alone — the map opens it and nothing is selected.
    func showZone(_ zone: ZoneShort) {
        seq += 1
        pending = Pending(zone: zone, mob: "", seq: seq)
        UserDefaults.standard.set(Tab.maps.rawValue, forKey: "eq.tab")
    }

    func clear() { pending = nil }
}

/// The popover card for one mob: level and zones off the committed catalog, the wiki drop table
/// with every item clickable, and the engine's own record underneath. Clicking a drop swaps the
/// card for that item's scaled stats; Back returns.
struct MobCardView: View {
    var name: String
    var onClose: (() -> Void)? = nil
    @State private var item: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item {
                ItemCardView(name: item, onBack: { self.item = nil }, onClose: onClose)
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
            if let onClose {
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.textFaint)
            }
        }
        if let m, !m.zones.isEmpty {
            Text(m.zones.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.textDim).lineLimit(2)
        }
        if let m {
            Card("DROPS (WIKI)") {
                if m.drops.isEmpty {
                    Text("The page lists no loot for \(m.name).").font(.callout).foregroundStyle(Theme.textFaint)
                } else {
                    // Sized by the list, capped by the card: two drops take two rows, not a box.
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
                    .frame(height: min(CGFloat(m.drops.count) * 21, 150))
                }
            }
        } else {
            Text("The mob catalog has no page for \(name).").font(.caption).foregroundStyle(Theme.textFaint)
        }
        KnowledgeCard(domain: "mob", name: name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
