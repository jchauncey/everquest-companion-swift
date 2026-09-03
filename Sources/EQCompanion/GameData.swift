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

    static func nameKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The zone fold the Electron app uses (`zoneKey`): lower-case letters and digits only.
    static func zoneKey(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
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
             dropsFrom: (v["dropsFrom"].array ?? []).map { ($0["mob"].string ?? "", $0["zone"].string ?? "") },
             raw: v)
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
    }

    private var mobsCache: [Mob]?
    var mobs: [Mob] {
        if let m = mobsCache { return m }
        let fixes = MobLocFixes.parse(load(roots.data, "mobLocFixes.json"))
        let m = (load(roots.eqlegends, "mobs.json")["mobs"].array ?? []).map { v in
            let page = v["page"].string ?? ""
            let wiki = v["loc"].array ?? []
            // A fix whose guard no longer holds is DEAD, not overriding: the corpus moved on.
            let fix = fixes[page].flatMap { MobLocFixes.guardHolds($0, corpus: wiki) ? $0 : nil }
            return Mob(name: v["name"].string ?? "", page: page, level: v["level"].string ?? "",
                       zones: (v["zones"].array ?? []).compactMap(\.string), drops: (v["drops"].array ?? []).compactMap(\.string),
                       loc: fix?.loc ?? wiki, raw: v, locFix: fix?.why)
        }
        mobsCache = m
        return m
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

    /// The zone row for a log spelling, through the same fold as the Electron app.
    func zone(forLogName raw: String) -> Zone? {
        let k = Self.zoneKey(raw)
        guard !k.isEmpty else { return nil }
        return zones.first { Self.zoneKey($0.name) == k || $0.aliases.contains { Self.zoneKey($0) == k } }
    }

    /// The mob-catalog zone spellings a log zone name reaches: its own name, aliases, and the
    /// verified catalog names.
    func catalogZoneKeys(forLogName raw: String) -> [String] {
        guard let z = zone(forLogName: raw) else { return [Self.zoneKey(raw)] }
        var keys = [Self.zoneKey(z.name)] + z.aliases.map(Self.zoneKey) + z.mobCatalogNames.map(Self.zoneKey)
        keys.append(Self.zoneKey(raw))
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
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
