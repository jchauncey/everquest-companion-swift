// The three derived screens: who to pull next, what is safe to destroy, and how far each class is
// from its unlock. Ports of `features/posky/skyTargets.ts`, `cleanup.ts` and `classUnlocks.ts`.
import Foundation

// MARK: - Targets

struct SkyNeededItem: Identifiable, Hashable {
    var name: String
    var shortfall: Int
    var quests: [SkyNeedingQuest]
    var islands: [String]
    var id: String { name }
}

struct SkyNeedingQuest: Hashable {
    var className: String
    var questName: String
    var need: Int
}

struct SkyTargetMob: Identifiable {
    var mob: SkyMob
    var covers: Int
    var islands: [String]
    var island: String?
    var items: [SkyNeededItem]
    var id: String { mob.page }
}

struct SkyTargetsModel {
    var mobs: [SkyTargetMob] = []
    var randomDrop: [SkyNeededItem] = []
    var unsourced: [SkyNeededItem] = []

    var isEmpty: Bool { mobs.isEmpty && randomDrop.isEmpty && unsourced.isEmpty }
}

struct SkyTargetIslandGroup: Identifiable {
    var island: String?
    var mobs: [SkyTargetMob]
    var id: String { island ?? "none" }
}

/// Consecutive runs of one island, in the order the mobs already sit in — the list is sorted island
/// first, so a run IS a group and no second pass is needed.
func skyGroupTargetsByIsland(_ mobs: [SkyTargetMob]) -> [SkyTargetIslandGroup] {
    var groups: [SkyTargetIslandGroup] = []
    for t in mobs {
        if let last = groups.last, last.island == t.island { groups[groups.count - 1].mobs.append(t) }
        else { groups.append(SkyTargetIslandGroup(island: t.island, mobs: [t])) }
    }
    return groups
}

/// Every mob still worth killing, island by island, and inside an island the ones that close the
/// most of what is left first. An item is aggregated ACROSS quests: six quests each wanting one
/// Wind Rune Ozah is one row saying `6x`.
func skyTargets(_ quests: [SkyQuestProgress], firstTimeOnly: Bool) -> SkyTargetsModel {
    struct Agg {
        var name: String
        var totalNeed = 0
        var held = 0
        var droppers: [SkyMob] = []
        var isRandom = false
        var islands = Set<String>()
        var quests: [SkyNeedingQuest] = []
    }
    var byKey: [String: Agg] = [:]
    var order: [String] = []
    for q in quests {
        if firstTimeOnly && q.everTurnedIn { continue }
        for it in q.items {
            let key = SkyName.countKey(it.name)
            if byKey[key] == nil {
                byKey[key] = Agg(name: it.name, held: it.held, droppers: it.droppers)
                order.append(key)
            }
            byKey[key]?.totalNeed += it.need
            if skyIsRandomDrop(it.who) { byKey[key]?.isRandom = true }
            // Prefer the base spelling when a variant got in first.
            if let agg = byKey[key], agg.name != SkyName.normalize(agg.name), it.name == SkyName.normalize(it.name) {
                byKey[key]?.name = it.name
            }
            if byKey[key]?.droppers.isEmpty == true { byKey[key]?.droppers = it.droppers }
            else {
                var seen = Set(byKey[key]?.droppers.map(\.page) ?? [])
                for m in it.droppers where seen.insert(m.page).inserted { byKey[key]?.droppers.append(m) }
            }
            if let island = skyIslandOf(it.place) { byKey[key]?.islands.insert(island) }
            byKey[key]?.quests.append(SkyNeedingQuest(className: q.className, questName: q.name, need: it.need))
        }
    }

    struct MobAcc { var mob: SkyMob; var islands: Set<String>; var items: [SkyNeededItem] }
    var mobsByPage: [String: MobAcc] = [:]
    var mobOrder: [String] = []
    var model = SkyTargetsModel()

    for key in order {
        guard let agg = byKey[key] else { continue }
        let shortfall = max(0, agg.totalNeed - agg.held)
        if shortfall == 0 { continue }
        let needed = SkyNeededItem(name: agg.name, shortfall: shortfall, quests: agg.quests,
                                   islands: agg.islands.sorted { skyIslandNumber($0) < skyIslandNumber($1) })
        if !agg.droppers.isEmpty {
            var seen = Set<String>()
            for m in agg.droppers {
                guard seen.insert(m.page).inserted else { continue }
                if mobsByPage[m.page] == nil {
                    mobsByPage[m.page] = MobAcc(mob: m, islands: [], items: [])
                    mobOrder.append(m.page)
                }
                mobsByPage[m.page]?.items.append(needed)
                for i in needed.islands { mobsByPage[m.page]?.islands.insert(i) }
            }
        } else if agg.isRandom {
            model.randomDrop.append(needed)
        } else {
            model.unsourced.append(needed)
        }
    }

    let byItemName: (SkyNeededItem, SkyNeededItem) -> Bool = { $0.name.lowercased() < $1.name.lowercased() }
    model.mobs = mobOrder.compactMap { mobsByPage[$0] }.map { e in
        let islands = Array(Set(skyMobIslands(page: e.mob.page, derived: Array(e.islands))))
            .sorted { skyIslandNumber($0) < skyIslandNumber($1) }
        return SkyTargetMob(mob: e.mob, covers: e.items.count, islands: islands,
                            island: islands.first, items: e.items.sorted(by: byItemName))
    }
    .sorted { a, b in
        // Island order first (unstated islands last), then how much each mob closes, then name.
        let ai = a.island.map(skyIslandNumber) ?? Int.max
        let bi = b.island.map(skyIslandNumber) ?? Int.max
        if ai != bi { return ai < bi }
        if a.covers != b.covers { return a.covers > b.covers }
        return skyDropperOrder(a.mob, b.mob)
    }
    model.randomDrop.sort(by: byItemName)
    model.unsourced.sort(by: byItemName)
    return model
}

// MARK: - Cleanup

struct SkyCleanupTurnIn: Identifiable, Hashable {
    var questKey: String
    var className: String
    var name: String
    var giver: String?
    var reward: String?
    var times: Int
    var sets: Int
    var have: Int
    var need: Int
    var id: String { questKey }

    var heading: String { "\(giver.map { "\($0) - " } ?? "")\(name) (\(className))" }
    var timesLine: String { "turned in \(times) time\(times == 1 ? "" : "s")" }
    var setsLine: String? {
        guard sets >= 1 else { return nil }
        return "you hold enough for \(sets) more turn-in\(sets == 1 ? "" : "s")"
    }
    var decisionLine: String {
        if sets < 1 { return "you hold \(have) of the \(need) needed for another turn-in" }
        guard let reward else { return "keep them: you are holding enough for another turn-in" }
        return "keep them: turning in again gives another \(reward), two \(reward) merge into +1"
    }
    var keep: Bool { sets >= 1 }
}

struct SkyCleanupRow: Identifiable, Hashable {
    var key: String
    var name: String
    var quantity: Int
    var turnIns: [SkyCleanupTurnIn]
    var id: String { key }
}

let SKY_CLEANUP_CAVEAT = "Cleanup lists items you could destroy because every Sky quest that needs them has been turned in. Destroying is permanent and happens in the game, not here. If you delete something you wanted, that is on you."

/// The items every quest that wants them has already been turned in for. A single quest with zero
/// turn-ins keeps an item off this list — that is the whole safety rule.
func skyCleanupRows(_ quests: [SkyQuestProgress]) -> [SkyCleanupRow] {
    var held: [String: Int] = [:]
    for q in quests { for it in q.items { held[SkyName.countKey(it.name)] = it.held } }

    struct Claim { var name: String; var quests: [SkyQuestProgress] }
    var byItem: [String: Claim] = [:]
    var order: [String] = []
    for q in quests {
        var seen = Set<String>()
        for it in q.items {
            let key = SkyName.countKey(it.name)
            guard seen.insert(key).inserted else { continue }
            if byItem[key] == nil {
                byItem[key] = Claim(name: SkyName.normalize(it.name), quests: [])
                order.append(key)
            }
            byItem[key]?.quests.append(q)
        }
    }

    func needs(_ q: SkyQuestProgress) -> [String: Int] {
        var out: [String: Int] = [:]
        for it in q.items { out[SkyName.countKey(it.name), default: 0] += it.need }
        return out
    }

    var rows: [SkyCleanupRow] = []
    for key in order {
        guard let claim = byItem[key] else { continue }
        let quantity = held[key] ?? 0
        if quantity <= 0 { continue }
        if claim.quests.contains(where: { $0.turnIns < 1 }) { continue }
        let turnIns = claim.quests.map { q -> SkyCleanupTurnIn in
            let n = needs(q)
            var sets = Int.max
            var have = 0, need = 0
            for (k, cnt) in n {
                sets = min(sets, (held[k] ?? 0) / cnt)
                have += min(cnt, held[k] ?? 0)
                need += cnt
            }
            return SkyCleanupTurnIn(questKey: q.key, className: q.className, name: q.name,
                                    giver: q.giver, reward: q.reward, times: q.turnIns,
                                    sets: sets == Int.max ? 0 : sets, have: have, need: need)
        }
        .sorted { a, b in
            if a.sets != b.sets { return a.sets > b.sets }
            if a.className != b.className { return a.className < b.className }
            return a.name < b.name
        }
        rows.append(SkyCleanupRow(key: key, name: claim.name, quantity: quantity, turnIns: turnIns))
    }
    return rows.sorted { a, b in a.quantity == b.quantity ? a.name < b.name : a.quantity > b.quantity }
}

// MARK: - Class unlocks

struct SkyClassUnlockRow: Identifiable, Hashable {
    enum Source: String { case observed, derived }
    var className: String
    var turnedIn: Int
    var total: Int
    var remaining: Int
    var unlocked: Bool
    var source: Source?
    var unlockedAt: Int64?
    var id: String { className }

    /// A logged unlock outranks the count: a class can also unlock at level 11 or from a token,
    /// and turning in a Sky test prints nothing about unlocking, so a complete set is our reading
    /// and not the game saying so.
    var label: String {
        switch source {
        case .observed: return "Unlocked, the log said so"
        case .derived: return "Every test turned in"
        case nil: return "\(remaining) test\(remaining == 1 ? "" : "s") left"
        }
    }
}

func skyClassUnlockRows(_ quests: [SkyQuestProgress], observed: [(className: String, ts: Int64)]) -> [SkyClassUnlockRow] {
    var byClass: [String: (turnedIn: Int, total: Int)] = [:]
    var order: [String] = []
    for q in quests {
        if byClass[q.className] == nil { byClass[q.className] = (0, 0); order.append(q.className) }
        byClass[q.className]?.total += 1
        if q.everTurnedIn { byClass[q.className]?.turnedIn += 1 }
    }
    var seenAt: [String: Int64] = [:]
    for rec in observed {
        let k = rec.className.lowercased()
        if seenAt[k] == nil { seenAt[k] = rec.ts }
    }
    return order.compactMap { className in
        guard let c = byClass[className] else { return nil }
        var row = SkyClassUnlockRow(className: className, turnedIn: c.turnedIn, total: c.total,
                                    remaining: c.total - c.turnedIn, unlocked: false)
        if let at = seenAt[className.lowercased()] {
            row.unlocked = true
            row.source = .observed
            row.unlockedAt = at
        } else if c.total > 0 && c.turnedIn == c.total {
            row.unlocked = true
            row.source = .derived
        }
        return row
    }
}

/// Fewest tests left first, then name; starred classes pinned above that.
func skyOrderClassUnlockRows(_ rows: [SkyClassUnlockRow], rank: (SkyClassUnlockRow) -> Int) -> [SkyClassUnlockRow] {
    rows.sorted { a, b in a.remaining == b.remaining ? a.className < b.className : a.remaining < b.remaining }
        .enumerated()
        .sorted { a, b in
            let ra = rank(a.element), rb = rank(b.element)
            return ra == rb ? a.offset < b.offset : ra > rb
        }
        .map(\.element)
}
