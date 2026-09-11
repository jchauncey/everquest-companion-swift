// Who drops an item, read off the MOB pages and joined onto the ITEM pages.
//
// The corpus states the drop relation twice, from two scrapes that never agree: `items.json`
// carries each item page's "dropped by" list, `mobs.json` each mob page's loot table. For Plane of
// Hate they share 146 rows out of ~540. The item side is the thinner one — it missed 27 of 52 gear
// drops one player's log recorded, four of them by naming only Plane of Fear for armour that
// dropped in Hate — and every one of those four was already right on the mob page.
//
// So every surface that answers "where does this drop" reads the UNION: the item page's own rows
// first, in its order, then the mob pages' rows it lacks. The Gear table's zone filter, the era
// verdict and the gear→map jump all run on that union, and the item card marks a mob-page row as
// such (`via`) so nobody reads a joined row as the item page's own word.
//
// APP-SIDE BY NECESSITY, not preference. `knowledge.item` is an engine answer the golden oracle
// pins against the Rust engine, which does not join: three of the six pinned items would change.
// The join therefore happens after the engine has answered, in the app, like `mobLocFixes.json`.
//
// The mob side is read AFTER `MobLootFixes` - the two rat pages are one rat here too.
//
// `GameData.rareLootDroppers` (the named-mob classifier's evidence) stays on the item pages
// alone: joining would give every item more droppers and quietly un-name mobs the map names today.
import Foundation
import EQCompanionCore
import EQKnowledge

struct MobPageDrops: Sendable {
    /// `GameData.nameKey(item)` → the mob pages' (mob, zone) rows, in corpus order.
    private let byItem: [String: [GearDrop]]

    static let empty = MobPageDrops(mobs: [])

    /// Off any actor: a fixed `mobs` array in, a value out.
    nonisolated init(mobs: [JSONValue]) {
        var byItem: [String: [GearDrop]] = [:]
        for m in mobs {
            guard let mob = m["name"].string, !mob.isEmpty else { continue }
            let zones = (m["zones"].array ?? []).compactMap(\.string).filter { !$0.isEmpty }
            for d in m["drops"].array ?? [] {
                guard let item = d.string else { continue }
                let key = GameData.nameKey(item)
                if key.isEmpty { continue }
                // A page stating no zone still names a dropper; the zone stays blank.
                let rows = zones.isEmpty ? [GearDrop(mob: mob, zone: "")] : zones.map { GearDrop(mob: mob, zone: $0) }
                byItem[key, default: []].append(contentsOf: rows)
            }
        }
        self.byItem = byItem
    }

    /// `mobs.json` at this URL, corrected by the fixes at that one (the shipped file when nil).
    nonisolated static func load(mobsURL: URL, fixesURL: URL?) -> MobPageDrops {
        guard let d = try? Data(contentsOf: mobsURL), let doc = try? JSONValue.parse(d) else { return .empty }
        var fixes = MobLootFixes.shipped
        if let fixesURL, let f = try? Data(contentsOf: fixesURL), let fdoc = try? JSONValue.parse(f) {
            fixes = MobLootFixes.parse(fdoc)
        }
        return MobPageDrops(mobs: MobLootFixes.apply(doc["mobs"].array ?? [], fixes))
    }

    /// The mob pages' rows for an item that the item page's own rows do not already state.
    nonisolated func additions(for itemKey: String, beyond wiki: [GearDrop]) -> [GearDrop] {
        guard let rows = byItem[itemKey], !rows.isEmpty else { return [] }
        var seen = Set(wiki.map(Self.rowKey))
        var out: [GearDrop] = []
        for r in rows where seen.insert(Self.rowKey(r)).inserted { out.append(r) }
        return out
    }

    /// Item-page rows first, in their order; then what only the mob pages say.
    nonisolated func union(_ wiki: [GearDrop], for itemKey: String) -> [GearDrop] {
        wiki + additions(for: itemKey, beyond: wiki)
    }

    /// One row's identity: the mob under the fold every mob surface uses (case, the backtick the
    /// log writes against the wiki's apostrophe) and the zone under the map's own key, so "Plane of
    /// Hate" and "The Plane of Hate" cannot state one dropper twice.
    nonisolated private static func rowKey(_ d: GearDrop) -> String {
        let mob = d.mob.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        let z = GameData.zoneKey(d.zone)
        return mob + "|" + (z.hasPrefix("the") ? String(z.dropFirst(3)) : z)
    }
}

// MARK: - Your own loot, on the item card

/// The third source of "who drops this": YOUR LOG. The mob card has always carried it
/// (`dropsSeen`); the item card did not, so an Indicolite Helm looted twice off a spite golem
/// showed one wiki dropper and no golem. Here a listed dropper gains `looted: N`, and a corpse no
/// wiki page names becomes its own row marked `via: "your loot"` - a fact about your play, never
/// dressed as a documented drop. Destroys are not acquisitions and name no source; they are out.
enum OwnLootSources {
    struct Source: Equatable { var mob: String; var zone: String?; var count: Int }

    /// Every corpse this item (any `+N` of it) came off, most-looted first, ties by name.
    nonisolated static func sources(for item: String, in events: [LootEvent]) -> [Source] {
        let key = LootName.countKey(item)
        var byMob: [String: Source] = [:]
        for e in events where e.isAcquisition && e.countKey == key {
            guard let mob = e.source?.trimmingCharacters(in: .whitespaces), !mob.isEmpty else { continue }
            var s = byMob[fold(mob)] ?? Source(mob: mob, zone: e.zone, count: 0)
            s.count += e.count
            if s.zone == nil { s.zone = e.zone }
            byMob[fold(mob)] = s
        }
        return byMob.values.sorted { a, b in a.count == b.count ? a.mob < b.mob : a.count > b.count }
    }

    /// The record's `dropsFrom` with your counts on the rows that name your corpses, then the
    /// corpses no row names. `zoneName` turns a log zone ("The Plane of Hate 3 (Fused)") into the
    /// roster's name for the zone cell's map jump; nil keeps the log's own spelling.
    nonisolated static func join(_ record: JSONValue, _ sources: [Source],
                                 zoneName: (String) -> String? = { _ in nil }) -> JSONValue {
        guard !sources.isEmpty, case .object(var o) = record else { return record }
        var rows = (o["dropsFrom"]?.array ?? []).map { $0.object ?? [:] }
        var unplaced = sources
        for i in rows.indices {
            guard let mob = rows[i]["mob"]?.string else { continue }
            if let j = unplaced.firstIndex(where: { fold($0.mob) == fold(mob) }) {
                rows[i]["looted"] = .int(Int64(unplaced[j].count))
                unplaced.remove(at: j)
            }
        }
        for s in unplaced {
            var row: [String: JSONValue] = ["mob": .string(s.mob), "via": .string("your loot"), "looted": .int(Int64(s.count))]
            if let z = s.zone, !z.isEmpty { row["zone"] = .string(zoneName(z) ?? z) }
            rows.append(row)
        }
        o["dropsFrom"] = .array(rows.map { .object($0) })
        return .object(o)
    }

    /// The mob fold every drop surface shares: case, and the backtick the log writes against the
    /// wiki's apostrophe.
    nonisolated static func fold(_ mob: String) -> String {
        mob.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "`", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
    }
}
