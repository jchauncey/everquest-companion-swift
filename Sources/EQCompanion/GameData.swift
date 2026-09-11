// The committed game knowledge the Electron app ships — mobs, items, raid targets, Plane of Sky
// quests, the quest corpus, zones, wiki respawn floors — loaded lazily off disk and shared by
// every surface. In a packaged app the files live under `Contents/Resources/data` and
// `Contents/Resources/wiki-images`; from a checkout (`swift run`) they are read straight out of
// the repo, so nothing is duplicated into git.
//
// Names are joined the way the Electron app joins them: lower-cased, whitespace-collapsed
// (`nameKey`). Item entries are keyed that way in `items.json` already.
import Foundation
import AppKit
import EQCompanionCore
import EQData
import EQKnowledge

@MainActor
final class GameData {
    static let shared = GameData()

    struct Roots {
        var data: URL          // items.json, spells.json, respawns.json, classes.json
        var eqlegends: URL     // bosses.json, mobs.json, posky.json, quests.json
        var generated: URL     // zones.json
        var images: URL        // wiki-images/*.png + manifest.json
    }

    let roots: Roots

    init() {
        roots = Self.resolveRoots()
    }

    /// Everything ships in the EQData resource bundle — a `swift run`, a test, and the .app agree.
    static func resolveRoots() -> Roots {
        let d = EQData.dataDir ?? URL(fileURLWithPath: "/nonexistent")
        return Roots(data: d, eqlegends: d, generated: d, images: EQData.imagesDir ?? URL(fileURLWithPath: "/nonexistent"))
    }

    // MARK: - Keys

    nonisolated static func nameKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The zone fold the Electron app uses (`zoneKey`): lower-case letters and digits only.
    nonisolated static func zoneKey(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// The zone fold, plus its article-flipped sibling: the zone roster spells a plane
    /// "The Plane of Hate" while the mob and item corpora say "Plane of Hate", and that one word
    /// left the plane's mobs off its map and broke the gear→map jump into it. Flipping the leading
    /// "the" (a whole word, so "Theater of Blood" is untouched) lets the two spellings resolve to
    /// each other. The original fold is always first, so an exact match still wins.
    nonisolated static func zoneKeyVariants(_ s: String) -> [String] {
        let k = zoneKey(s)
        guard !k.isEmpty else { return [] }
        if s.lowercased().split(whereSeparator: { $0.isWhitespace }).first == "the" {
            return [k, String(k.dropFirst(3))]
        }
        return [k, "the" + k]
    }

    // MARK: - Loading

    private var cache: [String: JSONValue] = [:]

    private func load(_ root: URL, _ file: String) -> JSONValue {
        if let c = cache[file] { return c }
        let url = root.appendingPathComponent(file)
        let v = (try? Data(contentsOf: url)).flatMap { try? JSONValue.parse($0) } ?? .null
        cache[file] = v
        return v
    }

    // MARK: - Items

    struct Item {
        var key: String
        var page: String
        var stats: JSONValue      // {flags, stats:[{key,value}], saves, effects, exaltationSlots, extras, slot, ac, weight, size, classes, races}
        var iconId: Int?
        var eraTag: String?
        var summary: String?
        var statsBlock: String?
        var dropsFrom: [(mob: String, zone: String)]
        var raw: JSONValue

        var name: String { page }
        var slot: String { stats["slot"].string ?? "" }
        var ac: Int? { stats["ac"].int }
        var classes: [String] { (stats["classes"].array ?? []).compactMap(\.string) }
        var hp: Int? { stat("HP") }
        var mana: Int? { stat("MANA") }
        func stat(_ key: String) -> Int? {
            for s in stats["stats"].array ?? [] where s["key"].string?.uppercased() == key.uppercased() {
                return Int((s["value"].string ?? "").replacingOccurrences(of: "+", with: ""))
            }
            return nil
        }
    }

    private var itemsIndex: [String: JSONValue]?

    var items: [String: JSONValue] {
        if let i = itemsIndex { return i }
        let i = load(roots.data, "items.json")["items"].object ?? [:]
        itemsIndex = i
        return i
    }

    private var rareLootDroppersCache: Set<String>?

    /// The mobs that drop something FEW others drop — one leg of the named-mob verdict
    /// (`MobNameConvention.isNamed`). An item with at most three recorded droppers is somebody's
    /// loot rather than a zone-wide table, and each of its droppers is remembered here by the
    /// lowercased spelling the drop row used.
    var rareLootDroppers: Set<String> {
        if let c = rareLootDroppersCache { return c }
        var out = Set<String>()
        for (_, v) in items {
            let mobs = Set((v["dropsFrom"].array ?? []).compactMap {
                $0["mob"].string?.trimmingCharacters(in: .whitespaces).lowercased()
            })
            if mobs.count <= 3 { out.formUnion(mobs) }
        }
        out.remove("")
        rareLootDroppersCache = out
        return out
    }

    func dropsRareLoot(_ mobName: String) -> Bool {
        rareLootDroppers.contains(mobName.trimmingCharacters(in: .whitespaces).lowercased())
    }

    func item(named name: String) -> Item? {
        var key = Self.nameKey(name)
        var v = items[key]
        // ` +N` is an item-level suffix the log prints and the wiki does not.
        if v == nil, let r = key.range(of: #" \+\d+$"#, options: .regularExpression) {
            key = String(key[..<r.lowerBound])
            v = items[key]
        }
        // A leading article the naming page dropped or added (`Dark Reaver` for `A Dark Reaver`).
        if v == nil {
            for alt in NameArticles.variants(of: name) {
                let k = Self.nameKey(alt)
                if let hit = items[k] { key = k; v = hit; break }
            }
        }
        guard let v else { return nil }
        return item(key: key, v)
    }

    func item(key: String, _ v: JSONValue) -> Item {
        Item(key: key,
             page: v["page"].string ?? key,
             stats: v["stats"],
             iconId: v["iconId"].int,
             eraTag: v["eraTag"].string,
             summary: v["summary"].string,
             statsBlock: v["statsBlock"].string,
             dropsFrom: dropsFrom(itemKey: key, v).map { ($0.mob, $0.zone) },
             raw: v)
    }

    // MARK: - Exaltations

    /// One item's focus-effect exaltation, from `exaltations.json` (scraped from the wiki's
    /// Category:Focus Effects). The item window shows this in the Focus Exaltation slot.
    struct Exaltation: Sendable, Hashable {
        var effect: String
        /// The level the tier's bonus decays past, nil when the effect never decays.
        var decaysAfter: Int?
        /// Coarse family tags (Mana, DoT, Spell Haste, Buffs, DD, Healing, Lifetap, Pets, Misc).
        var category: [String]
        var description: String?
    }

    private var exaltationsCache: [String: Exaltation]?
    /// Focus exaltations keyed by the item's `nameKey` fold, so a lookup matches whatever spelling
    /// the caller has.
    var exaltations: [String: Exaltation] {
        if let c = exaltationsCache { return c }
        var out: [String: Exaltation] = [:]
        for row in load(roots.data, "exaltations.json")["focus"].array ?? [] {
            guard let item = row["item"].string, let effect = row["effect"].string else { continue }
            out[Self.nameKey(item)] = Exaltation(
                effect: effect,
                decaysAfter: row["decaysAfter"].int,
                category: (row["category"].array ?? []).compactMap(\.string),
                description: row["description"].string)
        }
        exaltationsCache = out
        return out
    }

    /// This item's focus exaltation, or nil. Matches by name so a log or wiki spelling both resolve.
    func exaltation(forItem name: String) -> Exaltation? { exaltations[Self.nameKey(name)] }

    /// Every focus effect that appears in the overlay, sorted — the gear page's effect-name filter.
    private var exaltationEffectsCache: [String]?
    var exaltationEffects: [String] {
        if let c = exaltationEffectsCache { return c }
        let e = Set(exaltations.values.map(\.effect)).sorted()
        exaltationEffectsCache = e
        return e
    }

    /// Every category tag present, sorted.
    var exaltationCategories: [String] {
        Set(exaltations.values.flatMap(\.category)).sorted()
    }

    /// Every item, materialized once (11k rows, ~100 ms). For the gear table.
    private var allItemsCache: [Item]?
    var allItems: [Item] {
        if let a = allItemsCache { return a }
        let a = items.map { item(key: $0.key, $0.value) }.sorted { $0.page < $1.page }
        allItemsCache = a
        return a
    }

    // MARK: - Mobs

    struct Mob {
        var name: String
        var page: String
        var level: String
        var zones: [String]
        var drops: [String]
        var loc: [JSONValue]
        var raw: JSONValue
        /// Why this row's `loc` is ours and not the wiki's, when `mobLocFixes.json` corrected it.
        var locFix: String?
        /// Why this row's `drops` are two wiki pages folded into one, when `mobLootFixes.json` did it.
        var lootFix: String?
    }

    private var mobsCache: [Mob]?
    var mobs: [Mob] {
        if let m = mobsCache { return m }
        let fixes = MobLocFixes.parse(load(roots.data, "mobLocFixes.json"))
        // The loot corrections land on the raw array, as they do for the engine's own index: a
        // creature the wiki filed under two pages is one row here, or the map shows two rats.
        let raw = load(roots.eqlegends, "mobs.json")["mobs"].array ?? []
        let lootFixes = MobLootFixes.parse(load(roots.data, "mobLootFixes.json"))
        let fixed = MobLootFixes.apply(raw, lootFixes)
        // An alias that is gone from the fixed array was merged; its `why` marks the survivor.
        let before = Set(raw.compactMap { $0["name"].string }), after = Set(fixed.compactMap { $0["name"].string })
        var lootWhy: [String: String] = [:]
        for a in lootFixes.aliases where before.contains(a.alias) && !after.contains(a.alias) { lootWhy[a.mob] = a.why }
        let m = fixed.map { v in
            let page = v["page"].string ?? ""
            let wiki = v["loc"].array ?? []
            // A fix whose guard no longer holds is DEAD, not overriding: the corpus moved on.
            let fix = fixes[page].flatMap { MobLocFixes.guardHolds($0, corpus: wiki) ? $0 : nil }
            let name = v["name"].string ?? ""
            return Mob(name: name, page: page, level: v["level"].string ?? "",
                       zones: (v["zones"].array ?? []).compactMap(\.string), drops: (v["drops"].array ?? []).compactMap(\.string),
                       loc: fix?.loc ?? wiki, raw: v, locFix: fix?.why, lootFix: lootWhy[name])
        }
        mobsCache = m
        return m
    }

    private var mobPageDropsCache: MobPageDrops?
    /// Who drops what, by the MOB pages (after the loot fixes). See `MobPageDrops`.
    var mobPageDrops: MobPageDrops {
        if let c = mobPageDropsCache { return c }
        let c = MobPageDrops(mobs: mobs.map(\.raw))
        mobPageDropsCache = c
        return c
    }

    /// An item's drop sources as every surface shows them: the item page's rows, then the mob
    /// pages' rows it lacks.
    func dropsFrom(itemKey: String, _ v: JSONValue) -> [GearDrop] {
        let wiki = (v["dropsFrom"].array ?? []).map { GearDrop(mob: $0["mob"].string ?? "", zone: $0["zone"].string ?? "") }
        return mobPageDrops.union(wiki, for: itemKey)
    }

    /// A `knowledge.item` ANSWER (`{found, record}`) with the join applied to the record inside.
    /// The card holds the answer, not the record - joining at the wrong level is a silent no-op.
    func withMobPageDrops(answer: JSONValue) -> JSONValue {
        guard case .object(var o) = answer, let record = o["record"], record.object != nil else { return answer }
        o["record"] = withMobPageDrops(record)
        return .object(o)
    }

    /// A `knowledge.item` answer with YOUR loot joined onto the record's `dropsFrom` - counts on the
    /// droppers it names, a `via: "your loot"` row for a corpse it does not. Log zones resolve to
    /// the roster's names so the zone cell still jumps to the map. See `OwnLootSources`.
    func withOwnLoot(answer: JSONValue, item: String, events: [LootEvent]) -> JSONValue {
        guard case .object(var o) = answer, let record = o["record"], record.object != nil else { return answer }
        let sources = OwnLootSources.sources(for: item, in: events)
        o["record"] = OwnLootSources.join(record, sources) { [self] log in zone(forLogName: log)?.name }
        return .object(o)
    }

    /// A `knowledge.item` record with the mob pages' rows joined onto its `dropsFrom`, each joined
    /// row marked `via: "mob page"` so the card never passes one off as the item page's own.
    func withMobPageDrops(_ record: JSONValue) -> JSONValue {
        guard let name = record["name"].string ?? record["queried"].string else { return record }
        let key = Self.nameKey(ItemNames.itemBaseName(name))
        let wikiRows = record["dropsFrom"].array ?? []
        let wiki = wikiRows.map { GearDrop(mob: $0["mob"].string ?? "", zone: $0["zone"].string ?? "") }
        let extra = mobPageDrops.additions(for: key, beyond: wiki)
        if extra.isEmpty { return record }
        var o = record.object ?? [:]
        o["dropsFrom"] = .array(wikiRows + extra.map {
            var row: [String: JSONValue] = ["mob": .string($0.mob), "via": .string("mob page")]
            if !$0.zone.isEmpty { row["zone"] = .string($0.zone) }
            return .object(row)
        })
        return .object(o)
    }

    private var mobsByZoneCache: [String: [Mob]]?
    /// Mobs by the zone-key fold of every zone spelling the catalog carries.
    var mobsByZone: [String: [Mob]] {
        if let c = mobsByZoneCache { return c }
        var out: [String: [Mob]] = [:]
        for m in mobs { for z in m.zones { out[Self.zoneKey(z), default: []].append(m) } }
        mobsByZoneCache = out
        return out
    }

    private var mobsByNameCache: [String: Mob]?
    func mob(named name: String) -> Mob? {
        if mobsByNameCache == nil {
            var d: [String: Mob] = [:]
            for m in mobs { d[Self.nameKey(m.name)] = m }
            mobsByNameCache = d
        }
        return mobsByNameCache?[Self.nameKey(name)]
    }

    // MARK: - Zones

    struct Zone {
        var short: String
        var name: String
        var aliases: [String]
        var mobCatalogNames: [String]
        var era: String?
    }

    private var zonesCache: [Zone]?
    var zones: [Zone] {
        if let z = zonesCache { return z }
        let z = (load(roots.generated, "zones.json")["zones"].array ?? []).map { v in
            Zone(short: v["short"].string ?? "", name: v["name"].string ?? "",
                 aliases: (v["aliases"].array ?? []).compactMap(\.string),
                 mobCatalogNames: (v["mobCatalogNames"].array ?? []).compactMap(\.string),
                 era: v["era"].string)
        }
        zonesCache = z
        return z
    }

    /// The zone row for a log spelling, through the same fold as the Electron app — article
    /// tolerant, so "Plane of Hate" (the mob/item spelling) finds "The Plane of Hate" (the roster's).
    func zone(forLogName raw: String) -> Zone? {
        let ks = Set(Self.zoneKeyVariants(raw))
        guard !ks.isEmpty else { return nil }
        return zones.first { z in
            !ks.isDisjoint(with: Self.zoneKeyVariants(z.name))
                || z.aliases.contains { !ks.isDisjoint(with: Self.zoneKeyVariants($0)) }
        }
    }

    /// The mob-catalog zone spellings a log zone name reaches: its own name, aliases, and the
    /// verified catalog names.
    func catalogZoneKeys(forLogName raw: String) -> [String] {
        // Every spelling in article-flipped pairs, so a roster name with "The" still reaches mob
        // rows keyed without it (and the reverse). See `zoneKeyVariants`.
        guard let z = zone(forLogName: raw) else { return Self.zoneKeyVariants(raw) }
        let spellings = [z.name] + z.aliases + z.mobCatalogNames + [raw]
        var seen = Set<String>()
        return spellings.flatMap(Self.zoneKeyVariants).filter { seen.insert($0).inserted }
    }

    func mobs(inLogZone raw: String) -> [Mob] {
        var seen = Set<String>()
        var out: [Mob] = []
        for k in catalogZoneKeys(forLogName: raw) {
            for m in mobsByZone[k] ?? [] where seen.insert(m.page).inserted { out.append(m) }
        }
        return out
    }

    // MARK: - Raid targets, Plane of Sky, quests, respawns

    /// `{name, category, match:[...], zone, image}` — 32 rows.
    var raidTargets: [JSONValue] { load(roots.eqlegends, "bosses.json")["targets"].array ?? [] }

    /// `{className, name, giver, rune, reward, rewardStats, rewardPage, items:[{name, count?, ...}], source}` — 95 rows.
    var skyQuests: [JSONValue] { load(roots.eqlegends, "posky.json")["quests"].array ?? [] }

    /// `{name, page, requiredItems:[...]}` — 904 rows.
    var quests: [JSONValue] { load(roots.eqlegends, "quests.json")["quests"].array ?? [] }

    /// `{key, page, text, seconds}` — the wiki's respawn floors.
    var respawns: [JSONValue] { load(roots.data, "respawns.json")["rows"].array ?? [] }

    var classes: JSONValue { load(roots.data, "classes.json") }

    // MARK: - Images

    private var imageByUrl: [String: String]?

    private func manifest() {
        if imageByUrl != nil { return }
        var d: [String: String] = [:]
        for im in load(roots.images, "manifest.json")["images"].array ?? [] {
            if let u = im["url"].string, let f = im["file"].string { d[u] = f }
        }
        imageByUrl = d
    }

    private var imageCache: [String: NSImage] = [:]

    func image(file: String) -> NSImage? {
        if let i = imageCache[file] { return i }
        let url = roots.images.appendingPathComponent(file)
        guard let img = NSImage(contentsOf: url) else { return nil }
        imageCache[file] = img
        return img
    }

    func itemIcon(_ iconId: Int?) -> NSImage? {
        guard let id = iconId else { return nil }
        return image(file: "item-\(id).png")
    }

    /// A wiki image the manifest recorded (boss portraits), by its source URL.
    func image(url: String) -> NSImage? {
        manifest()
        guard let f = imageByUrl?[url] else { return nil }
        return image(file: f)
    }
}
