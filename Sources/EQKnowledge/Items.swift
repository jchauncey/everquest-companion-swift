// "What's this lore/quest item for", minus the network (knowledge/src/items.rs).
//
// Three sources, in order:
//
// 0. THE COMMITTED ITEM DATABASE is primary. A DB hit short-circuits everything after it — no
//    overlay read, no miss, no announcement.
// 1. LOCAL CROSS-REFS, merged into whatever answers: the scraped Plane of Sky dataset, which carries
//    per-item island/giver detail no item page states, and the scraped wiki quest catalog, which is
//    built from the QUEST pages and is therefore the answer for every turn-in item whose own page
//    never listed a quest.
// 2. THE RUNTIME OVERLAY, where a `knowledge.define` lands after the app has fetched a miss.
//
// A record is LITERALLY the scraper's own fields: no projection, no renaming, no translation layer.
// Mirroring twenty-odd fields into Swift structs would only lose one the day the scraper grows it,
// so the entry stays a `JSONValue` and the sole thing done to it is restoring the compact form's
// omitted defaults.
import Foundation
import EQCompanionCore
import EQData

/// How many reward names a `required` use carries.
private let maxAttachedRewards = 4

/// The committed corpus, keyed by `ItemNames.itemKey`, plus the key order the search surface walks.
///
/// The order is the Rust's `serde_json::Map` order — a `BTreeMap`, so byte-sorted by key — and it is
/// load-bearing exactly once: as the last tiebreak of `KnowledgeCorpus.search`'s otherwise total ranking.
public struct ItemDb {
    public var map: [String: JSONValue]
    public var keysSorted: [String]

    public init(map: [String: JSONValue], keysSorted: [String]) {
        self.map = map; self.keysSorted = keysSorted
    }

    public func get(_ key: String) -> JSONValue? { map[key] }
}

public enum Items {
    /// Parse `items.json` and hand back its `items` map.
    public static func loadItemDb() -> ItemDb {
        guard let text = EQData.text("items.json"), let file = try? JSONValue.parse(text) else {
            fatalError("items.json is not readable")
        }
        guard case .object(let items) = file["items"] else { return ItemDb(map: [:], keysSorted: []) }
        return ItemDb(map: items, keysSorted: items.keys.sorted(by: bytesLess))
    }

    /// The scraped quest catalog's `quests` array. Read once and handed to both index builders, the
    /// mob side and the item side, because it is one parse.
    public static func loadQuests() -> [JSONValue] {
        guard let text = EQData.text("quests.json"), let file = try? JSONValue.parse(text) else {
            fatalError("quests.json is not readable")
        }
        return file["quests"].array ?? []
    }

    /// Index the Plane of Sky dataset by item key → the quests that require it.
    static func poskyByItem() -> [String: [JSONValue]] {
        guard let text = EQData.text("posky.json"), let file = try? JSONValue.parse(text) else {
            fatalError("posky.json is not readable")
        }
        var built: [String: [JSONValue]] = [:]
        for q in file["quests"].array ?? [] {
            let className = q["className"].string ?? ""
            let name = q["name"].string ?? ""
            // De-dupe by quest identity (className + name): the same item appears under many quests.
            let quest = "\(className) · \(name)"
            for it in q["items"].array ?? [] {
                guard let item = it["name"].string else { continue }
                let key = ItemNames.itemKey(item)
                var uses = built[key] ?? []
                if uses.contains(where: { $0["quest"] == .string(quest) }) { continue }
                var row: JSONValue = ["quest": .string(quest), "page": q["source"], "source": "posky"]
                if let giver = q["giver"].string { row.set("giver", .string(giver)) }
                uses.append(row)
                built[key] = uses
            }
        }
        return built
    }

    /// The quest catalog, indexed item-first, from both sides of a quest: its turn-in/collectible
    /// items (`required`) and the items it hands out (`reward`).
    ///
    /// A `required` use also carries the quest's REWARD names, so the card can say what a turn-in
    /// pays without a second lookup. Only a turn-in has an outcome to name: a reward-role use IS the
    /// outcome, and listing the quest's rewards there would repeat the item back to itself.
    static func questsByItem(_ quests: [JSONValue]) -> [String: [JSONValue]] {
        var byItem: [String: [JSONValue]] = [:]
        for q in quests {
            let rewards = q["rewards"].array ?? []
            // Computed once per quest, not per item: every required item of a quest shares its
            // outcome. Blank names are dropped rather than rendered as empty chips.
            let rewardNames: [String] = rewards.compactMap { $0["name"].string }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(maxAttachedRewards)
                .map { $0 }
            func add(_ item: String, _ role: String) {
                let key = ItemNames.questItemKey(item)
                var uses = byItem[key] ?? []
                if uses.contains(where: { $0["page"] == q["page"] && $0["role"] == .string(role) }) { return }
                var row: JSONValue = ["quest": q["name"], "page": q["page"], "source": "quests", "role": .string(role)]
                if let giver = q["giver"].string { row.set("giver", .string(giver)) }
                if let zone = q["startZone"].string { row.set("zone", .string(zone)) }
                if role == "required", !rewardNames.isEmpty {
                    row.set("rewards", .array(rewardNames.map { .string($0) }))
                }
                uses.append(row)
                byItem[key] = uses
            }
            for it in q["requiredItems"].array ?? [] {
                if let name = it.string { add(name, "required") }
            }
            for r in rewards {
                if let name = r["name"].string { add(name, "reward") }
            }
        }
        return byItem
    }

    /// Quest identity for de-duping across sources: drop a `Class · ` prefix, fold the pipes and
    /// whitespace runs, lowercase.
    public static func questIdentity(_ s: String) -> String {
        // Everything after the FIRST `·`, when there is one.
        let after: Substring
        if let at = s.firstIndex(of: "·") { after = s[s.index(after: at)...] } else { after = s[...] }
        return after.replacingOccurrences(of: "|", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    /// A DB entry expanded into a knowledge record, with `name` overridden by what the CALLER asked
    /// for.
    ///
    /// The committed form omits `lore: false`, `quest: false` and `questUses: []` as pure weight
    /// across thousands of records. All three defaults are restored here, in one place, so no caller
    /// sees the compact form. `name` is the requested display name, because a DB hit must not be the
    /// one answer that renames the player's item.
    public static func knowledgeFromDb(_ entry: JSONValue, _ display: String) -> JSONValue {
        guard case .object = entry else {
            return ["name": .string(display), "lore": false, "quest": false, "questUses": .array([])]
        }
        var out = entry
        out.set("name", .string(display))
        out.orInsert("lore", false)
        out.orInsert("quest", false)
        out.orInsert("questUses", .array([]))
        return out
    }

    /// Merge the LOCAL associations into a knowledge record. Local wins on identity, so an item
    /// page's own related-quest links only ADD quests we did not know.
    ///
    /// The de-dupe strips the class prefix and matches when one normalized name CONTAINS the other:
    /// posky labels a quest `Class · Quest Name` where the name often already carries the class
    /// ("Paladin · Paladin Test of Love"), while a wiki link label is the bare "Paladin Test of Love".
    public static func mergeLocal(_ base: JSONValue, _ local: [JSONValue]) -> JSONValue {
        if local.isEmpty { return base }
        var uses = local
        for u in base["questUses"].array ?? [] {
            let nu = questIdentity(u["quest"].string ?? "")
            let known = uses.contains { x in
                let nx = questIdentity(x["quest"].string ?? "")
                return nx == nu || nx.contains(nu) || nu.contains(nx)
            }
            if !known { uses.append(u) }
        }
        var out = base
        out.set("quest", true)
        out.set("questUses", .array(uses))
        return out
    }

    /// The record for a name no committed source and no overlay entry carries.
    ///
    /// `offline: true` rather than `notFound: true`. `notFound` means "the wiki lookup RAN and found
    /// no page", a real negative; this engine has no network stack, so it ran no lookup and cannot
    /// claim one. `offline` means "the wiki could not be consulted, local sources may still have
    /// answered", which is the state the renderer treats as retryable — and the retry is the
    /// `knowledgeMiss` frame.
    public static func unanswered(_ display: String, _ local: [JSONValue]) -> JSONValue {
        mergeLocal([
            "name": .string(display),
            "lore": false,
            "quest": .bool(!local.isEmpty),
            "questUses": .array([]),
            "offline": true
        ], local)
    }

    /// The display name a lookup answers with, for a name a caller handed in.
    public static func displayOf(_ name: String) -> String { ItemNames.normalizeItemName(name) }
}

/// Both local item→quest indexes, built once.
public final class LocalQuests {
    private let posky: [String: [JSONValue]]
    private let quests: [String: [JSONValue]]

    public init(quests: [JSONValue]) {
        posky = Items.poskyByItem()
        self.quests = Items.questsByItem(quests)
    }

    /// The Plane of Sky dataset FIRST, then the wiki quest catalog, deduped by quest identity.
    /// Empty when neither local source knows this item — never an empty claim.
    public func forItem(_ name: String) -> [JSONValue] {
        let key = ItemNames.itemKey(name)
        let p = posky[key]
        let q = quests[key]
        if p == nil && q == nil { return [] }
        var uses = p ?? []
        for u in q ?? [] {
            let nu = Items.questIdentity(u["quest"].string ?? "")
            if !uses.contains(where: { Items.questIdentity($0["quest"].string ?? "") == nu }) { uses.append(u) }
        }
        return uses
    }
}
