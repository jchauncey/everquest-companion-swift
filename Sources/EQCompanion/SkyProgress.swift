// A quest's progress, the turn-in ledger behind it, and the filter/sort/search the Quests tab
// narrows by. Ports of `features/posky/useProgress.ts`, `shared/questTurnIns.ts`,
// `features/posky/turnInCelebration.ts`, `questCompletion.ts`, `questSort.ts`, `questFacets.ts`,
// `questSearch.ts`, `sharedItems.ts` and `rewardInference.ts`.
import Foundation

// MARK: - Progress

struct SkyItemProgress: Identifiable, Hashable {
    var name: String
    var who: [String]
    var place: String
    var droppers: [SkyMob]
    var need: Int
    var have: Int
    var held: Int
    var stats: String?
    var lastLootedAt: Int64?
    var override: SkyItemOverride?
    var id: String { name }

    var done: Bool { have >= need }
    /// Wind Runes sit in the currency tab, which the dump never contains.
    var dumpBlind: Bool { SkyName.isCurrency(name) }
}

/// Which derived witness speaks for a row that has no ledger event of its own.
enum SkyEvidence: String {
    case reward
    var badge: String { "Turned in · reward held" }
    var hover: String {
        "Turned in at least once: the reward for this quest is in your inventory export, and it cannot be obtained any other way."
    }
}

struct SkyQuestProgress: Identifiable, Hashable {
    var key: String
    var className: String
    var name: String
    var giver: String?
    var rune: String?
    var reward: String?
    var rewardStats: String?
    var items: [SkyItemProgress]
    var haveCount: Int
    var needCount: Int
    var ratio: Double
    var missing: [String]
    var turnIns: Int
    var logTurnIns: Int
    var completed: Bool
    var evidence: SkyEvidence?
    var lastDropAt: Int64?
    var id: String { key }

    /// Are you holding everything this quest asks for, right now? A quest that requires NOTHING is
    /// never "has every item": zero required items is missing data, not a finished quest.
    var hasEveryItem: Bool { needCount > 0 && missing.isEmpty }
    /// Have you EVER handed it in? The count, not the holdings — it stays true while you refarm.
    var everTurnedIn: Bool { turnIns >= 1 }

    static func == (a: SkyQuestProgress, b: SkyQuestProgress) -> Bool { a.key == b.key && a.haveCount == b.haveCount && a.turnIns == b.turnIns && a.needCount == b.needCount }
    func hash(into h: inout Hasher) { h.combine(key) }
}

func skyComputeQuestProgress(_ quest: SkyQuestDef,
                             held: [String: Int],
                             turnInsAll: [String: Int],
                             turnInsLog: [String: Int],
                             lastLootedAt: [String: Int64],
                             overrides: [String: SkyItemOverride],
                             droppers: (String, [String]) -> [SkyMob]) -> SkyQuestProgress {
    var items: [SkyItemProgress] = []
    items.reserveCapacity(quest.items.count)
    for it in quest.items {
        let need = it.count > 0 ? it.count : 1
        let k = SkyName.countKey(it.name)
        let holding = held[k] ?? 0
        items.append(SkyItemProgress(name: it.name, who: it.who, place: it.place,
                                     droppers: droppers(it.name, it.who),
                                     need: need, have: min(need, holding), held: holding,
                                     stats: it.stats, lastLootedAt: lastLootedAt[k],
                                     override: overrides[k]))
    }
    let needCount = items.reduce(0) { $0 + $1.need }
    let haveCount = items.reduce(0) { $0 + $1.have }
    let count = turnInsAll[quest.key] ?? 0
    // A quest's "most recent drop" is the newest time any item it requires last dropped; nil when
    // none of them ever has — an absence the sort honours rather than rounding down to 1970.
    let recency = items.compactMap(\.lastLootedAt).max()
    return SkyQuestProgress(key: quest.key, className: quest.className, name: quest.name,
                            giver: quest.giver, rune: quest.rune, reward: quest.reward,
                            rewardStats: quest.rewardStats, items: items,
                            haveCount: haveCount, needCount: needCount,
                            ratio: needCount == 0 ? 0 : Double(haveCount) / Double(needCount),
                            missing: items.filter { $0.have < $0.need }.map(\.name),
                            turnIns: count, logTurnIns: turnInsLog[quest.key] ?? 0,
                            completed: count > 0, evidence: nil, lastDropAt: recency)
}

/// A quest with no ledger evidence whose UNTRADEABLE reward is sitting in the dump reads
/// `turnIns: 1`, labelled with what vouched for it: the reward cannot be obtained any other way.
/// The ledger wins outright — a real count is never overwritten by a floor.
func skyWithRewardEvidence(_ q: SkyQuestProgress, vouched: Set<String>) -> SkyQuestProgress {
    guard q.turnIns == 0, vouched.contains(q.key) else { return q }
    var out = q
    out.turnIns = 1
    out.completed = true
    out.evidence = .reward
    return out
}

func skyRewardInferredQuests(_ quests: [SkyQuestDef], inventory: [String: Int]) -> Set<String> {
    var vouched = Set<String>()
    guard !inventory.isEmpty else { return vouched }
    var held = Set<String>()
    for (name, count) in inventory where count > 0 { held.insert(SkyName.countKey(name)) }
    for q in quests {
        guard let reward = q.reward else { continue }
        let stats = (q.rewardStats ?? "").lowercased()
        guard stats.contains("nodrop") || stats.contains("no drop") || stats.contains("no-drop")
                || stats.contains("notrade") || stats.contains("no trade") || stats.contains("no-trade") else { continue }
        if held.contains(SkyName.countKey(reward)) { vouched.insert(q.key) }
    }
    return vouched
}

// MARK: - The turn-in ledger

enum SkyTurnIns {
    /// Which quests the LOG says you handed in: an offer to a quest's giver that carried every
    /// item it requires. Never a partial match — a trade missing an item is not that quest.
    static func detected(_ events: [SkyTurnInEvent], quests: [SkyQuestDef]) -> [String: [Int64]] {
        var out: [String: [Int64]] = [:]
        for t in events {
            let npc = t.npc.lowercased()
            let offered = Set(t.items.map(SkyName.countKey))
            for q in quests {
                guard q.giver?.lowercased() == npc else { continue }
                guard !q.items.isEmpty, q.items.allSatisfy({ offered.contains(SkyName.countKey($0.name)) }) else { continue }
                out[q.key, default: []].append(t.ts)
            }
        }
        return out
    }

    /// The stored (hand-recorded) instants merged with the log's, deduped and sorted.
    static func resolve(stored: [String: [Int64]], detected: [String: [Int64]]) -> (instants: [String: [Int64]], all: [String: Int]) {
        var instants: [String: [Int64]] = [:]
        for key in Set(stored.keys).union(detected.keys) {
            let merged = Set((stored[key] ?? []) + (detected[key] ?? []))
            instants[key] = merged.sorted().prefix(200).map { $0 }
        }
        var all: [String: Int] = [:]
        for (key, list) in instants { all[key] = list.count }
        return (instants, all)
    }

    static func badgeLabel(_ count: Int) -> String { count > 1 ? "Turned in x\(count)" : "Turned in" }
}

// MARK: - Sort

enum SkySort: String, CaseIterable, Identifiable {
    case recent, closest, leastMissing, name, className, island
    var id: String { rawValue }

    static let `default`: SkySort = .recent

    var label: String {
        switch self {
        // Not "most recent DROP": a drop nobody picked up leaves no line in the log.
        case .recent: return "Most recently looted"
        case .closest: return "Closest to done"
        case .leastMissing: return "Fewest missing"
        case .name: return "Quest name (A-Z)"
        case .className: return "By class"
        case .island: return "By island"
        }
    }

    /// Five of the six orders let a starred quest jump the queue. 'recent' does NOT: its subject is
    /// an EVENT, and a pin does not reorder that answer, it destroys it — the drop you just made
    /// stops being the top row.
    var pinsFavorites: Bool { self != .recent }
}

/// The lowest island any of a quest's items names, or nil. 88 of the 95 quests name exactly one
/// island; 6 name two (this picks the earlier, where progression starts you); 1 names none.
func skyQuestIsland(_ q: SkyQuestProgress) -> Int? {
    q.items.compactMap { skyIslandOf($0.place).map(skyIslandNumber) }.min()
}

/// The universal last resort: name, then class (names repeat across classes).
private func skyByName(_ a: SkyQuestProgress, _ b: SkyQuestProgress) -> Bool {
    a.name == b.name ? a.className < b.className : a.name < b.name
}

private func skyNameEqual(_ a: SkyQuestProgress, _ b: SkyQuestProgress) -> Bool {
    a.name == b.name && a.className == b.className
}

func skySortQuests(_ quests: [SkyQuestProgress], _ sort: SkySort) -> [SkyQuestProgress] {
    // Keyed quests first, ordered by key; unkeyed ALL below, by name. An absence is a missing
    // answer, not a low value, and must not interleave with real ones.
    func byOptional<K: Comparable>(_ key: (SkyQuestProgress) -> K?, ascending: Bool) -> [SkyQuestProgress] {
        quests.sorted { a, b in
            let ka = key(a), kb = key(b)
            switch (ka, kb) {
            case (nil, nil): return skyByName(a, b)
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?):
                if x == y { return skyByName(a, b) }
                return ascending ? x < y : x > y
            }
        }
    }
    switch sort {
    case .recent: return byOptional({ $0.lastDropAt }, ascending: false)
    case .island: return byOptional({ skyQuestIsland($0) }, ascending: true)
    case .name: return quests.sorted(by: skyByName)
    case .className:
        return quests.sorted { a, b in a.className == b.className ? skyByName(a, b) : a.className < b.className }
    case .closest:
        return quests.sorted { a, b in
            if a.ratio != b.ratio { return a.ratio > b.ratio }
            if a.missing.count != b.missing.count { return a.missing.count < b.missing.count }
            return skyByName(a, b)
        }
    case .leastMissing:
        return quests.sorted { a, b in
            if a.missing.count != b.missing.count { return a.missing.count < b.missing.count }
            if a.ratio != b.ratio { return a.ratio > b.ratio }
            return skyByName(a, b)
        }
    }
}

/// The chosen order, then the favorite pin on top of it — a stable second pass, and only for the
/// orders that may carry one.
func skyOrderQuests(_ quests: [SkyQuestProgress], _ sort: SkySort, rank: (SkyQuestProgress) -> Int) -> [SkyQuestProgress] {
    let sorted = skySortQuests(quests, sort)
    guard sort.pinsFavorites else { return sorted }
    return sorted.enumerated()
        .sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra == rb ? a.offset < b.offset : ra > rb
        }
        .map(\.element)
}

// MARK: - Facets and search

/// Every island a quest's required items STATE, ascending. Facets read EVERY required item,
/// completed ones included — a quest must not leave the boss you filtered by the instant its drop
/// lands, which is the one moment you are most likely to be looking at it.
func skyQuestIslands(_ q: SkyQuestProgress) -> [String] {
    var out = Set<String>()
    for it in q.items { if let i = skyIslandOf(it.place) { out.insert(i) } }
    return out.sorted { skyIslandNumber($0) < skyIslandNumber($1) }
}

func skyQuestBosses(_ q: SkyQuestProgress) -> [String] {
    var out = Set<String>()
    for it in q.items { for d in it.droppers { out.insert(d.name) } }
    return out.sorted { $0.lowercased() < $1.lowercased() }
}

struct SkyFacetOptions {
    var islands: [String] = []
    /// Bosses by HOW MANY quests they stand in front of, then by name — plain alphabetical opens
    /// with the three one-off drakes and buries the six bosses the whole zone is about.
    var bosses: [String] = []
}

func skyFacetOptions(_ quests: [SkyQuestProgress]) -> SkyFacetOptions {
    var islands = Set<String>()
    var bosses: [String: Int] = [:]
    for q in quests {
        for i in skyQuestIslands(q) { islands.insert(i) }
        for b in skyQuestBosses(q) { bosses[b] = (bosses[b] ?? 0) + 1 }
    }
    return SkyFacetOptions(
        islands: islands.sorted { skyIslandNumber($0) < skyIslandNumber($1) },
        bosses: bosses.sorted { a, b in a.value == b.value ? a.key.lowercased() < b.key.lowercased() : a.value > b.value }.map(\.key))
}

/// Lowercased substring over five fields — quest name, reward, item names, bosses, islands — OR
/// across them. One rule, no tokenising, no per-field special cases.
func skyQuestMatches(_ q: SkyQuestProgress, needle: String) -> Bool {
    if needle.isEmpty { return true }
    if q.name.lowercased().contains(needle) { return true }
    if let r = q.reward, r.lowercased().contains(needle) { return true }
    if q.items.contains(where: { $0.name.lowercased().contains(needle) }) { return true }
    if skyQuestBosses(q).contains(where: { $0.lowercased().contains(needle) }) { return true }
    return skyQuestIslands(q).contains { $0.lowercased().contains(needle) }
}

// MARK: - Shared items

struct SkySharingQuest: Identifiable, Hashable {
    var key: String
    var className: String
    var name: String
    var reward: String?
    var id: String { key }
}

struct SkySharedItem: Identifiable, Hashable {
    var key: String
    var name: String
    var quests: [SkySharingQuest]
    var id: String { key }
}

/// Which of a quest's items other Sky quests also want. Wind Runes are excluded: every quest wants
/// one, so listing them would say nothing.
func skyComputeSharedItems(_ quests: [SkyQuestDef]) -> [String: [SkySharedItem]] {
    func refs(_ q: SkyQuestDef) -> [(key: String, name: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for it in q.items where !SkyName.isCurrency(it.name) {
            let k = SkyName.countKey(it.name)
            if seen.insert(k).inserted { out.append((k, SkyName.normalize(it.name))) }
        }
        return out
    }
    var byItem: [String: (name: String, quests: [SkySharingQuest])] = [:]
    for q in quests {
        let sq = SkySharingQuest(key: q.key, className: q.className, name: q.name, reward: q.reward)
        for r in refs(q) {
            if byItem[r.key] == nil { byItem[r.key] = (r.name, []) }
            byItem[r.key]?.quests.append(sq)
        }
    }
    var out: [String: [SkySharedItem]] = [:]
    for q in quests {
        var shared: [SkySharedItem] = []
        for r in refs(q) {
            guard let entry = byItem[r.key], entry.quests.count >= 2 else { continue }
            let others = entry.quests.filter { $0.key != q.key }
            if others.isEmpty { continue }
            shared.append(SkySharedItem(key: r.key, name: entry.name, quests: others))
        }
        if !shared.isEmpty { out[q.key] = shared }
    }
    return out
}

/// Quest names that repeat across classes — those need their class spelled out to be identifiable.
func skyAmbiguousQuestNames(_ quests: [SkyQuestDef]) -> Set<String> {
    var byName: [String: Set<String>] = [:]
    for q in quests { byName[q.name, default: []].insert(q.className) }
    return Set(byName.filter { $0.value.count > 1 }.keys)
}
