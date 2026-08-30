// The Plane of Sky data layer: the committed quest bundle, the item-name counting key, the
// Sky mob drop index and the island derivations. Ports of `lib/itemName.ts`,
// `features/posky/poskyDroppers.ts` and `features/posky/skyMobIslands.ts` — same folds, same
// orders, same refusals to guess.
import Foundation
import EQCompanionCore

// MARK: - Item names

enum SkyName {
    /// ` +N` is an upgrade suffix the log prints and the wiki does not; the counting boundary
    /// strips it, so `Sphinx Claw` and `Sphinx Claw +1` are one held item for quest purposes.
    static func normalize(_ name: String) -> String {
        var i = name.endIndex
        var digits = 0
        while i > name.startIndex {
            let j = name.index(before: i)
            guard name[j].isNumber else { break }
            digits += 1
            i = j
        }
        guard digits > 0, i > name.startIndex else { return name }
        let plus = name.index(before: i)
        guard name[plus] == "+", plus > name.startIndex else { return name }
        let space = name.index(before: plus)
        guard name[space] == " " else { return name }
        return String(name[..<space])
    }

    static func countKey(_ name: String) -> String { normalize(name).lowercased() }

    /// Wind Runes live in the currency tab, which no `/outputfile inventory` dump ever contains.
    static func isCurrency(_ name: String) -> Bool {
        normalize(name).lowercased().hasPrefix("wind rune")
    }
}

// MARK: - The committed quests

struct SkyItemDef: Hashable {
    var name: String
    var who: [String]
    var place: String       // posky's stated `where`, e.g. "Island 3"
    var count: Int
    var page: String?
    var stats: String?
}

struct SkyQuestDef: Hashable, Identifiable {
    var key: String         // "Bard::Bard Test of Brass"
    var className: String
    var name: String
    var giver: String?
    var rune: String?
    var reward: String?
    var rewardStats: String?
    var items: [SkyItemDef]
    var id: String { key }
}

enum SkyCatalog {
    /// `${className}::${name}` — the Electron app's `questKey`, verbatim.
    static func questKey(className: String, name: String) -> String { "\(className)::\(name)" }

    @MainActor
    static func quests() -> [SkyQuestDef] { quests(from: GameData.shared.skyQuests) }

    /// The mapping, over rows rather than over the singleton, so a test can hand it the committed
    /// file directly.
    static func quests(from rows: [JSONValue]) -> [SkyQuestDef] {
        rows.map { v in
            let className = v["className"].string ?? ""
            let name = v["name"].string ?? ""
            return SkyQuestDef(
                key: questKey(className: className, name: name),
                className: className,
                name: name,
                giver: v["giver"].string,
                rune: v["rune"].string,
                reward: v["reward"].string,
                rewardStats: v["rewardStats"].string,
                items: (v["items"].array ?? []).map { it in
                    SkyItemDef(name: it["name"].string ?? "",
                               who: (it["who"].array ?? []).compactMap(\.string),
                               place: it["where"].string ?? "",
                               count: it["count"].int ?? 0,
                               page: it["page"].string,
                               stats: it["stats"].string)
                })
        }
    }
}

// MARK: - Droppers

struct SkyMob: Hashable, Identifiable {
    var name: String
    var page: String
    var level: String
    var zones: [String]
    var id: String { page }

    /// `Gorgalosk · level 55 · Plane of Sky` — the hover roster the Quests and Targets tabs share.
    var facts: String {
        var parts = [name]
        if !level.isEmpty { parts.append("level \(level)") }
        if !zones.isEmpty { parts.append(zones.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Name, then page — a total order, so a list of droppers never shuffles.
func skyDropperOrder(_ a: SkyMob, _ b: SkyMob) -> Bool {
    let an = a.name.lowercased(), bn = b.name.lowercased()
    if an != bn { return an < bn }
    return a.page < b.page
}

/// The Sky half of the mob catalog, inverted: which mobs drop each item, and each mob by name.
/// Only mobs the catalog files under Plane of Sky are in it — an item that also drops elsewhere is
/// not a reason to send a player out of the zone.
struct SkyDropperIndex {
    private var byItem: [String: [SkyMob]] = [:]
    private var byName: [String: SkyMob] = [:]

    /// Built from catalog rows, so a test can hand it the committed file rather than the singleton.
    init(catalog: [(mob: SkyMob, drops: [String])]) {
        for entry in catalog {
            for drop in entry.drops {
                let k = SkyName.countKey(drop)
                if k.isEmpty { continue }
                byItem[k, default: []].append(entry.mob)
            }
            let nk = entry.mob.name.lowercased()
            if byName[nk] == nil { byName[nk] = entry.mob }
        }
        for k in byItem.keys { byItem[k]?.sort(by: skyDropperOrder) }
    }

    var isEmpty: Bool { byItem.isEmpty && byName.isEmpty }

    /// posky's own `who` list resolved against the catalog, then the inverted loot lists appended —
    /// stated first, deduped by page (`mergeDroppers` over `statedDroppers` + `droppersFor`).
    func droppers(for itemName: String, who: [String]) -> [SkyMob] {
        var out: [SkyMob] = []
        var seen = Set<String>()
        for w in who {
            guard let hit = byName[w.trimmingCharacters(in: .whitespaces).lowercased()] else { continue }
            if seen.insert(hit.page).inserted { out.append(hit) }
        }
        for m in byItem[SkyName.countKey(itemName)] ?? [] where seen.insert(m.page).inserted {
            out.append(m)
        }
        return out
    }
}

/// The index over the app's committed mob catalog, built once.
@MainActor
enum SkyDroppers {
    private static var cached: SkyDropperIndex?

    static var shared: SkyDropperIndex {
        if let c = cached { return c }
        let rows = GameData.shared.mobs
            .filter { m in m.zones.contains { $0.lowercased() == "plane of sky" } }
            .map { (mob: SkyMob(name: $0.name, page: $0.page, level: $0.level, zones: $0.zones), drops: $0.drops) }
        let index = SkyDropperIndex(catalog: rows)
        cached = index
        return index
    }
}

/// `random drop — any Plane of Sky mob` is posky saying it does not know a dropper. It is a fact
/// about the item, not a mob to hunt, so it never becomes a target row.
func skyIsRandomDrop(_ who: [String]) -> Bool {
    who.contains { $0.lowercased().hasPrefix("random drop") }
}

// MARK: - Islands

private let skyIslandRegex = try! NSRegularExpression(pattern: "\\bisland\\s+(\\d+)\\b", options: [.caseInsensitive])

/// The island a stated location names, or nil. Never inferred: "Plane of Sky" names no island,
/// and dressing it up as one would be a fabricated progression order.
func skyIslandOf(_ place: String?) -> String? {
    guard let place else { return nil }
    let ns = place as NSString
    guard let m = skyIslandRegex.firstMatch(in: place, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1 else { return nil }
    return "Island \(ns.substring(with: m.range(at: 1)))"
}

func skyIslandNumber(_ island: String) -> Int {
    let ns = island as NSString
    guard let m = skyIslandRegex.firstMatch(in: island, range: NSRange(location: 0, length: ns.length)),
          m.numberOfRanges > 1 else { return 0 }
    return Int(ns.substring(with: m.range(at: 1))) ?? 0
}

func skyIslandLabel(_ islands: [String]) -> String {
    let sorted = Array(Set(islands)).sorted { skyIslandNumber($0) < skyIslandNumber($1) }
    if sorted.isEmpty { return "" }
    if sorted.count == 1 { return sorted[0] }
    return "Islands " + sorted.map { String(skyIslandNumber($0)) }.joined(separator: ", ")
}

/// The one mob whose island the drop data gets wrong, with its evidence (skyMobIslands.ts).
/// `Gem of Invigoration` is called an island-7 trash drop on its item page, which is true about
/// the item and not about the Protector, who stands on island 2.
private let skyMobIslandOverrides: [String: String] = ["Protector of Sky": "Island 2"]

func skyMobIslands(page: String, derived: [String]) -> [String] {
    if let fixed = skyMobIslandOverrides[page] { return [fixed] }
    return derived
}

// MARK: - Kill targets for one quest (the "Kill: …" caption)

struct SkyKillTarget: Identifiable {
    var mob: SkyMob
    var covers: Int
    var islands: [String]
    var id: String { mob.page }

    var facts: String {
        let i = skyIslandLabel(islands)
        return i.isEmpty ? mob.facts : "\(mob.facts) · \(i)"
    }
}

/// Which mobs still stand between this quest and its turn-in, most-covering first. Reads only the
/// items you are SHORT of — a caption about what is left.
func skyQuestKillTargets(_ items: [SkyItemProgress]) -> [SkyKillTarget] {
    struct Acc { var mob: SkyMob; var covers: Int; var islands: Set<String> }
    var byPage: [String: Acc] = [:]
    var order: [String] = []
    for it in items where it.have < it.need {
        let island = skyIslandOf(it.place)
        var seen = Set<String>()
        for m in it.droppers {
            guard seen.insert(m.page).inserted else { continue }
            if byPage[m.page] == nil {
                byPage[m.page] = Acc(mob: m, covers: 0, islands: [])
                order.append(m.page)
            }
            byPage[m.page]?.covers += 1
            if let island { byPage[m.page]?.islands.insert(island) }
        }
    }
    return order.compactMap { byPage[$0] }
        .sorted { a, b in
            a.covers == b.covers ? skyDropperOrder(a.mob, b.mob) : a.covers > b.covers
        }
        .map { e in
            SkyKillTarget(mob: e.mob, covers: e.covers,
                          islands: skyMobIslands(page: e.mob.page, derived: Array(e.islands))
                              .sorted { skyIslandNumber($0) < skyIslandNumber($1) })
        }
}

func skyKillTargetLabel(_ targets: [SkyKillTarget]) -> String {
    guard let lead = targets.first else { return "" }
    let more = targets.count - 1
    let islands = skyIslandLabel(lead.islands)
    return "Kill: \(lead.mob.name)\(more > 0 ? " +\(more)" : "")\(islands.isEmpty ? "" : " · \(islands)")"
}

// MARK: - Freshness wording (lib/formatDate.ts `formatAge`)

enum SkyAge {
    static func label(_ ts: Int64, now: Int64) -> String {
        guard ts > 0 else { return "" }
        let secs = max(0, Double(now - ts) / 1000)
        if secs < 90 { return "just now" }
        let mins = secs / 60
        if mins < 90 { return "\(Int(mins.rounded()))m ago" }
        let hrs = mins / 60
        if hrs < 36 { return "\(Int(hrs.rounded()))h ago" }
        return "\(Int((hrs / 24).rounded()))d ago"
    }

    static func updated(_ ts: Int64?) -> String {
        guard let ts, ts > 0 else { return "not yet run" }
        return "updated " + label(ts, now: nowMs())
    }

    static func loaded(_ ts: Int64?) -> String {
        guard let ts, ts > 0 else { return "not loaded yet" }
        return "loaded " + label(ts, now: nowMs())
    }
}
