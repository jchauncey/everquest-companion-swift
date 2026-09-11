// "What does this thing drop", minus the network (knowledge/src/mobs.rs). Four sources, the first
// three local:
//
//   1. THE SCRAPED MOB CATALOG — the definitive drop table. The wiki's drop list is what the mob CAN
//      drop and it is static content, so it is scraped once and committed, which is why a `/con`
//      answers instantly and offline.
//   2. YOUR OWN LOOT HISTORY, read through `OwnLoot`. Corroboration, not the drop table: it
//      annotates a listed drop with a count, and contributes names of its own only for items the
//      page does not list.
//   3. THE QUEST CATALOG'S `relatedNpcs`, so a quest-relevant mob says so with no network at all.
//   4. THE RUNTIME OVERLAY, where a `knowledge.define` lands.
//
// The alias boundary is AT THE LOOKUP and nowhere else. The log and the catalog can spell one
// creature two ways (hyphen versus space), and the raid roster's `match` list is the one place in
// the tree where two spellings are already STATED to be the same creature. This file reads that
// statement and does no name arithmetic of its own. `display` is untouched throughout and is what
// the record reports as its `name`, so a page reached by the log spelling reads back exactly what
// the log said.
//
// The era annotation runs on every read and is persisted nowhere. It attaches EVIDENCE — the item
// page's era banner token and the zones that page named — and reaches no verdict: there is exactly
// one era rule in this app, and a second opinion computed here would be the beginning of a third.
import Foundation
import EQCompanionCore
import EQData
import EQFold

/// One creature, and every spelling the roster states for it.
public struct Identity: Equatable {
    /// The name to ASK the catalog and the overlay with — the roster's own `name`, which is the
    /// spelling those sources use. Never what the card displays.
    public var canonical: String
    /// Every mob key this creature answers to, canonical key first.
    public var keys: [String]
    /// The roster stated more than one spelling for this creature.
    public var aliased: Bool

    public init(canonical: String, keys: [String], aliased: Bool) {
        self.canonical = canonical; self.keys = keys; self.aliased = aliased
    }
}

/// mob key → the quests that name it under "Related NPCs".
public typealias MobQuestIndex = [String: [JSONValue]]

/// The catalog, keyed BOTH ways a mob can be named, and the alias table.
public final class MobIndex {
    private let byName: [String: JSONValue]
    /// Every alias key of every multi-spelling roster target → its identity.
    private let identityByKey: [String: Identity]
    /// Catalog display names in file order, for `knowledge.search`.
    private let displayNames: [String]

    /// Build both indexes off the committed bytes.
    ///
    /// The catalog is keyed TWICE: by the page's own `|name` (the in-game name a consider line
    /// prints) and then by the wiki PAGE TITLE, which is occasionally the only spelling. The
    /// page-title pass runs second and only fills gaps, so a real mob's own name can never be
    /// displaced by another page's title.
    public static func build() -> MobIndex {
        guard let text = EQData.text("mobs.json"), let file = try? JSONValue.parse(text) else {
            fatalError("mobs.json is not readable")
        }
        // The committed corrections land HERE, on the raw array, because one of them merges two
        // pages that fold to a single `mobKey` - by the time `byName` exists, one of the pair has
        // already been dropped. See MobLootFixes.swift.
        let mobs = MobLootFixes.apply(file["mobs"].array ?? [])
        var byName: [String: JSONValue] = [:]
        byName.reserveCapacity(mobs.count * 2)
        var names: [String] = []
        names.reserveCapacity(mobs.count)
        for m in mobs {
            guard let name = m["name"].string else { continue }
            let key = Mobs.mobKey(name)
            if key.isEmpty { continue }
            names.append(name)
            if byName[key] == nil { byName[key] = m }
        }
        for m in mobs {
            guard let page = m["page"].string else { continue }
            let key = Mobs.mobKey(page)
            if key.isEmpty { continue }
            if byName[key] == nil { byName[key] = m }
        }
        return MobIndex(byName: byName, identityByKey: Mobs.buildIdentities(), displayNames: names)
    }

    init(byName: [String: JSONValue], identityByKey: [String: Identity], displayNames: [String]) {
        self.byName = byName; self.identityByKey = identityByKey; self.displayNames = displayNames
    }

    /// The catalog's entry for a mob, or nil when it has none.
    public func entry(_ name: String) -> JSONValue? { byName[Mobs.mobKey(name)] }

    /// Resolve any spelling to the one identity the roster states, or to itself when the roster has
    /// never heard of it.
    ///
    /// Total and allocation-light: an unaliased name — nearly every mob — gets a trivial identity
    /// whose `canonical` is the name it was handed, so every downstream read is the read it was
    /// before aliases existed.
    public func identity(_ name: String) -> Identity {
        let key = Mobs.mobKey(name)
        if let known = identityByKey[key] { return known }
        return Identity(canonical: name, keys: key.isEmpty ? [] : [key], aliased: false)
    }

    /// Every catalog display name, for the search surface.
    public func names() -> [String] { displayNames }
}

public enum Mobs {
    /// `consider.rs mob_key`, the fold's own definition — one fold, read here rather than restated.
    public static func mobKey(_ name: String) -> String { ResistCatalog.mobKey(name) }

    /// Read the roster's own statement that two spellings are one creature.
    ///
    /// Targets whose spellings all collapse to ONE key are skipped entirely: they never enter the
    /// map, so `identity` hands back the trivial identity and every caller runs the path it ran
    /// before. A key claimed by two targets keeps the first — silently merging two creatures on a
    /// later scrape is not something this boundary should be able to do by accident.
    static func buildIdentities() -> [String: Identity] {
        guard let text = EQData.text("bosses.json"), let file = try? JSONValue.parse(text) else {
            fatalError("bosses.json is not readable")
        }
        var byKey: [String: Identity] = [:]
        for t in file["targets"].array ?? [] {
            guard let name = t["name"].string else { continue }
            var keys: [String] = []
            for spelling in [name] + (t["match"].array ?? []).compactMap(\.string) {
                let k = mobKey(spelling)
                if !k.isEmpty, !keys.contains(k) { keys.append(k) }
            }
            if keys.count < 2 { continue }
            let id = Identity(canonical: name, keys: keys, aliased: true)
            for k in keys where byKey[k] == nil { byKey[k] = id }
        }
        return byKey
    }

    /// Build the `relatedNpcs` cross-ref off the already-parsed quest catalog.
    public static func questsByMob(_ quests: [JSONValue]) -> MobQuestIndex {
        var byMob: MobQuestIndex = [:]
        for q in quests {
            for npcValue in q["relatedNpcs"].array ?? [] {
                guard let npc = npcValue.string else { continue }
                let key = mobKey(npc)
                if key.isEmpty { continue }
                var uses = byMob[key] ?? []
                if uses.contains(where: { $0["quest"] == q["name"] }) { continue }
                var row: JSONValue = ["quest": q["name"]]
                for (field, from) in [("page", "page"), ("giver", "giver"), ("zone", "startZone")] {
                    if let v = q[from].string { row.set(field, .string(v)) }
                }
                uses.append(row)
                byMob[key] = uses
            }
        }
        return byMob
    }

    /// The quests the local catalog ties to this CREATURE, under every spelling the roster states for
    /// it. De-duped by quest name.
    static func identityQuests(_ index: MobQuestIndex, _ id: Identity) -> [JSONValue] {
        var merged: [JSONValue] = []
        for key in id.keys {
            for q in index[key] ?? [] {
                let name = (q["quest"].string ?? "").lowercased()
                if !merged.contains(where: { ($0["quest"].string ?? "").lowercased() == name }) { merged.append(q) }
            }
        }
        return merged
    }

    /// A catalog entry → the WIKI half of a knowledge record.
    ///
    /// The catalog is compact by design (names only), so a per-drop `rarity` is simply ABSENT here; a
    /// live fallback is where one would come from, and a made-up rarity would not be honest.
    public static func knowledgeFromCatalog(_ display: String, _ entry: JSONValue) -> JSONValue {
        var out: JSONValue = ["name": .string(display), "page": entry["page"], "cached": true]
        if let level = entry["level"].string, !level.isEmpty { out.set("levelText", .string(level)) }
        let zones = (entry["zones"].array ?? []).compactMap(\.string)
        if !zones.isEmpty { out.set("zone", .string(zones.joined(separator: ", "))) }
        let drops: [JSONValue] = (entry["drops"].array ?? []).compactMap(\.string).map { ["item": .string($0)] }
        if !drops.isEmpty { out.set("dropsWiki", .array(drops)) }
        return out
    }

    /// Attach the two LOCAL sources to a record, on EVERY read.
    ///
    /// Never baked into anything persisted: your own loot history changes with every corpse, and the
    /// quest catalog ships with the app, so remembering either would immediately be stale.
    ///
    /// It reads by IDENTITY rather than by the one name the caller happened to hold — the own-loot
    /// index files a drop under the corpse's LOG name while a boss card asks with the ROSTER name.
    /// What comes back is still `dropsSeen`, so alias-gathered loot is never dressed up as
    /// documented drops.
    public static func mergeLocalKnowledge(_ base: JSONValue, _ id: Identity, _ quests: MobQuestIndex,
                                           _ loot: OwnLoot) -> JSONValue {
        var out = base
        let seen = loot.dropsAcross(id.keys)
        if seen.isEmpty {
            out.remove("dropsSeen")
        } else {
            out.set("dropsSeen", .array(seen.map(seenDrop)))
        }
        let local = identityQuests(quests, id)
        if !local.isEmpty {
            // The page's own related-quest links and the catalog's `relatedNpcs` are two views of
            // one relation, so de-dupe by quest name; local wins, because it carries giver and zone.
            var merged = local
            for u in out["quests"].array ?? [] {
                let name = (u["quest"].string ?? "").lowercased()
                if !merged.contains(where: { ($0["quest"].string ?? "").lowercased() == name }) { merged.append(u) }
            }
            out.set("quests", .array(merged))
        }
        return out
    }

    /// One seen drop, on the wire.
    static func seenDrop(_ d: SeenDrop) -> JSONValue {
        ["item": .string(d.item), "count": .int(d.count), "lastTs": .int(d.lastTs)]
    }

    /// The drop list, carrying what each ITEM PAGE says about its era.
    ///
    /// A drop the corpus has no page for comes back unchanged, and so does a page that states neither
    /// an era banner nor a drop zone: absent is the honest answer and the renderer draws it as `era?`
    /// rather than as a verdict. `dropsSeen` is deliberately untouched — those are items YOU pulled
    /// off this corpse, a fact about your own play and not a claim about what the server ships.
    public static func annotateDropEras(_ record: JSONValue, _ items: ItemDb) -> JSONValue {
        guard let drops = record["dropsWiki"].array, !drops.isEmpty else { return record }
        var out = record
        out.set("dropsWiki", .array(drops.map { annotateDrop($0, items) }))
        return out
    }

    /// One drop, annotated. Only the ZONE half of the page's drop-source list is era evidence, and a
    /// zone named by several of its mobs is one zone. Order is the page's, which no fold depends on.
    static func annotateDrop(_ drop: JSONValue, _ items: ItemDb) -> JSONValue {
        guard let item = drop["item"].string else { return drop }
        guard let entry = items.get(ItemNames.itemKey(item)) else { return drop }
        var zones: [String] = []
        for source in entry["dropsFrom"].array ?? [] {
            if let zone = source["zone"].string, !zones.contains(zone) { zones.append(zone) }
        }
        let era = entry["eraTag"].string
        if era == nil, zones.isEmpty { return drop }
        var out = drop
        if let era { out.set("eraTag", .string(era)) }
        if !zones.isEmpty { out.set("eraZones", .array(zones.map { .string($0) })) }
        return out
    }

    /// The record for a mob no committed source and no overlay entry carries.
    ///
    /// `offline: true` for the reason `Items.unanswered` states: this engine ran no lookup, so it
    /// cannot claim the real negative `notFound` means. The local half is merged on top by the caller.
    public static func unanswered(_ display: String) -> JSONValue {
        ["name": .string(display), "cached": false, "offline": true]
    }
}
