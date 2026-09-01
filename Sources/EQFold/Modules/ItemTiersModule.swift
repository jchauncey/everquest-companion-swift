// Port of fold/src/modules/item_tiers.rs — the per-item observed item level for items the current
// character has actually upgraded.
//
// Only MERGE evidence counts (law 1: messages over inference), in three shapes: an `itemMerge`; a
// loot with disposition `combined` (its `created` name is the result); and an `itemMergeFailed` of
// reason `mismatch`, whose line quotes your item's name verbatim with its tier suffix. Ordinary
// loot of a ` +N` drop is not evidence — an unmerged drop is routinely auto-sold on pickup.
//
// `tier` is the highest tier ever observed for a base name: a fact about a merge that happened,
// never a claim about what is in your bags. A destroy retires nothing.
//
// Absent means unknown, never tier 0 — a `held` first sighting with no tier creates no row, and a
// row with no tier omits both `tier` and `lastTier` rather than writing zero.
import Foundation
import EQLog
import EQCompanionCore

public final class ItemTiersModule: EqModule {
    public let id = "itemTiers"

    private struct ItemTierRow {
        var key: String
        var name: String
        var tier: Int64?
        var lastTier: Int64?
        var merges: Int64
        var firstAt: Int64
        var lastAt: Int64
        var json: JSONValue {
            var o: [String: JSONValue] = ["key": .string(key), "name": .string(name),
                                          "merges": .int(merges), "firstAt": .int(firstAt), "lastAt": .int(lastAt)]
            if let tier { o["tier"] = .int(tier) }
            if let lastTier { o["lastTier"] = .int(lastTier) }
            return .object(o)
        }
    }

    /// Whether an upgrade happened (`merge`) or a line merely quoted an item we are holding (`held`).
    private enum How { case merge, held }

    private var rows = JSMap<ItemTierRow>()
    private var seq: Int64 = 0
    /// The announce cursor. Bumped inside `observe`, past its refusals.
    private var announce = Announce()

    public init() {}

    /// Fold one observation of `raw` (a display name that may carry ` +N`) at `ts`. A tier-less
    /// name advances nothing but the merge count.
    private func observe(_ raw: String, _ ts: Int64, _ how: How) {
        let name = JSFn.itemBaseName(raw)
        if name.isEmpty { return }
        let key = JSFn.itemTierKey(raw)
        let tier = JSFn.itemTierFromName(raw)
        guard let prev = rows[key] else {
            // A 'held' first sighting with no tier says nothing — no empty row (absent = unknown).
            if how == .held && tier == nil { return }
            rows.insert(key, ItemTierRow(key: key, name: name, tier: tier, lastTier: tier,
                                         merges: how == .merge ? 1 : 0, firstAt: ts, lastAt: ts))
            announce.changed(seq)
            return
        }
        var next = prev
        next.name = name
        next.lastAt = ts
        next.merges = how == .merge ? prev.merges + 1 : prev.merges
        if let t = tier {
            // Highest ever observed, not latest: players level several copies of one item in
            // parallel, so "latest" would report +3 for a bag holding a +4.
            next.tier = prev.tier.map { max($0, t) } ?? t
            next.lastTier = t
        }
        rows.insert(key, next)
        // `lastAt` is this observation's instant, so reaching here is always a published change.
        announce.changed(seq)
    }

    public func reset() {
        rows.clear()
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kind {
        // Character rebirth: merges before the boundary belong to a dead same-name character.
        case "epoch":
            rows.clear()
            announce.changed(seq)
        // A tier-less result is a spell-scroll merge (Roman rank), which observedSpellRanks owns.
        // Still a merge we observed, so it is recorded as one with no tier.
        case "itemMerge":
            observe(ev.str(.item) ?? "", ev.ts, .merge)
        // Only the 'mismatch' shape names items; it is an inventory statement, not an upgrade, so
        // it never counts as a merge — it can only reveal a tier we hadn't seen.
        case "itemMergeFailed":
            if ev.str(.reason) == "mismatch", let target = ev.str(.target), !target.isEmpty {
                // `ev.target &&` — an empty string is falsy over there.
                observe(target, ev.ts, .held)
            }
        // The auto-merge-on-pickup line, whose `created` name is the result of the merge.
        case "loot":
            if ev.str(.disposition) == "combined", let created = ev.str(.created), !created.isEmpty {
                observe(created, ev.ts, .merge)
            }
        default: break
        }
    }

    /// Moves on an observation that reached the map. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": rows.json(\.json)] }
}

// MARK: - Checkpoint

extension ItemTiersModule: FoldCheckpointable {
    public func checkpointState() -> JSONValue {
        .object([
            "rows": rows.checkpoint(\.json),
            "seq": .int(seq),
            "announce": .int(announce.cursor),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let m = JSMap<ItemTierRow>.fromCheckpoint(state["rows"], { v in
            guard let key = v["key"].string, let name = v["name"].string,
                  let merges = v["merges"].int64, let first = v["firstAt"].int64,
                  let last = v["lastAt"].int64 else { return nil }
            return ItemTierRow(key: key, name: name, tier: v["tier"].int64, lastTier: v["lastTier"].int64,
                               merges: merges, firstAt: first, lastAt: last)
        }), let savedSeq = state["seq"].int64, let cursor = state["announce"].int64 else { return false }
        rows = m
        seq = savedSeq
        announce.restore(cursor: cursor)
        return true
    }
}
