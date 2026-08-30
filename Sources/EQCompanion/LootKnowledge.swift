// What the app KNOWS about a looted item, from the committed corpora rather than from a lookup.
//
// The Electron ledger probes main for an `ItemKnowledge` record per recent item and waits for the
// answer. The Mac app does not have to: `src/main/data/items.json` — which `GameData` already loads
// — IS that corpus, field for field (`lore`, `quest`, `questUses`, `recipes`), so the same
// predicates run synchronously here and the strip never flickers in.
//
// The rules themselves are ported verbatim:
//   * NOTABLE (`shared/itemKnowledge.isNotableKnowledge`) — lore, quest-flagged, or used by at least
//     one known quest. Everything else is ordinary vendor trash.
//   * TRADESKILL-ONLY (`lib/itemKnowledgeView.isTradeskillOnly`) — at least one recipe consumes it,
//     no quest anywhere uses it, not lore. An item page's stats block often carries the QUEST ITEM
//     flag on things no quest uses (Gnome Meat, spider legs), so without this the pickups strip is
//     pure noise while you grind.
//   * A ` +N` VARIANT OF A GEAR ITEM is notable too, and that is this app's own addition rather than
//     the Electron rule: EQ Legends drops upgrades routinely, and "that cape you just picked up is a
//     +3" is exactly the push this strip is for.
import Foundation
import EQCompanionCore

/// Everything the ledger asks the corpora about one item.
struct LootItemFacts: Sendable {
    var lore = false
    var quest = false
    /// Quest names this item is used by, in the corpus's own order.
    var questUses: [String] = []
    /// Recipe labels that consume it — `Gnome Kabobs (Baking 56)`, the shared spelling.
    var recipes: [String] = []
    var iconId: Int?
    /// The equipment slot the item page states, or empty. What separates a gear upgrade from a stack
    /// of meat.
    var slot = ""
    /// Required by a Plane of Sky quest.
    var sky = false
    /// `0` for a base name, `N` for a ` +N` variant.
    var variant = 0
    /// Does the corpus know this item at all?
    var known = false

    /// Lore, quest-flagged, or used by a known quest — plus this app's two additions, a Sky item and
    /// a gear upgrade.
    var notable: Bool { sky || gearUpgrade || lore || quest || !questUses.isEmpty }

    /// A recipe ingredient and nothing else.
    var tradeskillOnly: Bool {
        if lore || sky { return false }
        if !questUses.isEmpty { return false }
        return !recipes.isEmpty
    }

    /// A ` +N` of something you wear or hold.
    var gearUpgrade: Bool { variant > 0 && !slot.isEmpty }

    /// The chip row's short state words, in the order they are drawn. The PoSky chip suppresses the
    /// redundant `quest` badge, exactly as the Electron badge does.
    var chips: [(String, String)] {
        var out: [(String, String)] = []
        if sky { out.append(("PoSky", "sky")) }
        if lore { out.append(("LORE", "lore")) }
        if !sky, tradeskillOnly { out.append(("tradeskill", "tradeskill")) }
        if !sky, !tradeskillOnly, quest || !questUses.isEmpty { out.append(("quest", "quest")) }
        if gearUpgrade { out.append(("+\(variant)", "upgrade")) }
        return out
    }

    /// What the pickup chip says the item is FOR: the first quest, else the first recipe, else
    /// nothing. Never a guess.
    var purpose: String? { questUses.first ?? recipes.first }
}

/// One memoized read of the committed corpora, shared by every Loot surface.
@MainActor
final class LootKnowledge {
    static let shared = LootKnowledge()

    private var cache: [String: LootItemFacts] = [:]
    private var skyCache: Set<String>?

    /// Every counting key a Plane of Sky quest requires. Keyed by the counting key so an upgraded
    /// `Sphinx Claw +1` is still recognized — the row keeps showing its `+N`; only the RECOGNITION
    /// is normalized.
    var skyKeys: Set<String> {
        if let s = skyCache { return s }
        var out: Set<String> = []
        for q in GameData.shared.skyQuests {
            for it in q["items"].array ?? [] {
                if let n = it["name"].string { out.insert(LootName.countKey(n)) }
            }
            if let r = q["reward"].string { out.insert(LootName.countKey(r)) }
        }
        skyCache = out
        return out
    }

    /// The facts for one looted name. Cached by counting key: a `+N` variant reads its base item's
    /// page, which is the only page the wiki has.
    func facts(_ item: String) -> LootItemFacts {
        let key = LootName.countKey(item)
        let variant = LootName.variantLevel(item)
        if var hit = cache[key] {
            hit.variant = variant
            return hit
        }
        var f = LootItemFacts()
        f.sky = skyKeys.contains(key)
        if let entry = GameData.shared.item(named: item) {
            let raw = entry.raw
            f.known = true
            f.lore = raw["lore"].bool ?? false
            f.quest = raw["quest"].bool ?? false
            f.questUses = (raw["questUses"].array ?? []).compactMap { $0["quest"].string }
            f.recipes = (raw["recipes"].array ?? []).compactMap { r in
                guard let name = r["recipe"].string else { return nil }
                let inner = [r["tradeskill"].string, r["trivial"].int.map(String.init)]
                    .compactMap { $0 }.joined(separator: " ")
                return inner.isEmpty ? name : "\(name) (\(inner))"
            }
            f.iconId = entry.iconId
            f.slot = entry.slot
        }
        cache[key] = f
        f.variant = variant
        return f
    }
}

/// One entry of the "Notable pickups" strip: a recent item worth flagging, and what it is for.
struct LootPickup: Identifiable, Sendable {
    var item: String
    var countKey: String
    var ts: Int64
    var facts: LootItemFacts
    var id: String { countKey }

    /// `Froglok Meat → Pickled Frogloks`, or the bare name when the corpus says nothing about what
    /// it is for.
    var label: String {
        guard let p = facts.purpose else { return item }
        return "\(item) → \(p)"
    }
}

extension LootKnowledge {
    /// How many most-recent distinct looted items to consider. The strip is a push surface, and a
    /// window wider than this is a list nobody reads.
    static let probeLimit = 40

    /// The notable pickups of a slice, most recent first, and how many tradeskill components are
    /// hiding behind the toggle.
    ///
    /// A DESTROY IS NOT A PICKUP, and here that is a cost as well as a meaning: admitting a bag
    /// cleanup would push real pickups out of the window.
    func pickups(_ events: [LootEvent], dismissed: Set<String>, showTradeskill: Bool) -> (shown: [LootPickup], hiddenTradeskill: Int) {
        var seen = Set<String>()
        var recent: [LootPickup] = []
        for e in events.reversed() {
            if recent.count >= Self.probeLimit { break }
            if e.isDestroyed { continue }
            if !seen.insert(e.countKey).inserted { continue }
            let f = facts(e.item)
            guard f.notable else { continue }
            recent.append(LootPickup(item: e.item, countKey: e.countKey, ts: e.ts, facts: f))
        }
        let live = recent.filter { !dismissed.contains($0.countKey) }
        let hidden = live.filter(\.facts.tradeskillOnly).count
        return (showTradeskill ? live : live.filter { !$0.facts.tradeskillOnly }, showTradeskill ? 0 : hidden)
    }
}
