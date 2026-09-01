// Port of fold/src/modules/observed_spell_ranks.rs — which rank of each spell line this character
// has actually been observed to hold.
//
// Two witnesses, and the asymmetry between them is the design. A MERGE line proves the moment of
// levelling — the same sentence `itemTiers` reads, whose rank-suffixed half is this module's. A
// CAST at a rank proves possession, and is the only witness for a rank levelled before the log
// began.
//
// Union, highest wins. `rank` is the max over both; `mergedRank`/`castRank` keep the halves apart,
// each appearing only once its own witness has spoken. A lower later observation never lowers
// anything — ranks do not downgrade.
//
// The merge lane needs the catalog, the cast lane does not: a merge names an ITEM, and an item
// ending in a roman numeral need not be a spell, while a cast names a spell by construction.
//
// Unsuffixed names are not evidence — rank 1 is the default state.
import Foundation
import EQLog
import EQCompanionCore

public final class ObservedSpellRanksModule: EqModule {
    public let id = "observedSpellRanks"

    private struct ObservedSpellRankRow {
        var key: String
        var name: String
        var rank: Int64
        var merges: Int64
        var firstAt: Int64
        var lastAt: Int64
        var mergedRank: Int64?
        var castRank: Int64?
        var json: JSONValue {
            var o: [String: JSONValue] = ["key": .string(key), "name": .string(name), "rank": .int(rank),
                                          "merges": .int(merges), "firstAt": .int(firstAt), "lastAt": .int(lastAt)]
            if let mergedRank { o["mergedRank"] = .int(mergedRank) }
            if let castRank { o["castRank"] = .int(castRank) }
            return .object(o)
        }
    }

    /// Which witness an observation came from.
    private enum Witness { case merge, cast }

    private var rows = JSMap<ObservedSpellRankRow>()
    private var seq: Int64 = 0
    /// `ObservedSpellRanksDeps.knownSpell`. An empty set is the absent-dependency default: no merge
    /// is admitted, withholding a claim rather than inventing spells out of item names.
    private let knownSpell: Set<String>
    /// The announce cursor. Bumped inside `observe`, past its refusals.
    private var announce = Announce()

    public init(knownSpell: Set<String>) { self.knownSpell = knownSpell }

    /// Fold one observation of `raw` (a display name that may carry a roman numeral) at `ts`. An
    /// unsuffixed name is not evidence and returns immediately.
    private func observe(_ raw: String, _ ts: Int64, _ how: Witness) {
        let parsed = JSFn.parseSpellRank(raw)
        if !parsed.suffixed || parsed.base.isEmpty { return }
        let key = Names.spellCanonKey(raw)
        if key.isEmpty { return }
        if how == .merge && !knownSpell.contains(key) { return }
        let prev = rows[key]
        // `base` keeps the raw casing and punctuation the log used; the key is the lowercased fold.
        // The first spelling seen wins and is never rewritten — the log outranks the wiki on names.
        var next: ObservedSpellRankRow
        if var p = prev {
            p.lastAt = ts
            next = p
        } else {
            next = ObservedSpellRankRow(key: key, name: parsed.base, rank: 0, merges: 0,
                                        firstAt: ts, lastAt: ts, mergedRank: nil, castRank: nil)
        }
        if how == .merge {
            next.merges += 1
            next.mergedRank = max(prev.flatMap(\.mergedRank) ?? 0, parsed.rank)
        } else {
            next.castRank = max(prev.flatMap(\.castRank) ?? 0, parsed.rank)
        }
        next.rank = max(next.rank, parsed.rank)
        rows.insert(key, next)
        // `lastAt` is this sighting's instant, so a row that reaches here is always rewritten.
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
        // Character rebirth: every rank before the boundary belongs to the dead beta character.
        case "epoch":
            rows.clear()
            announce.changed(seq)
        // A ` +N` result is an item level (itemTiers owns it) and carries no numeral, so it falls
        // out of `observe` on the rank test with no second check here.
        case "itemMerge":
            observe(ev.str(.item) ?? "", ev.ts, .merge)
        case "castBegin":
            observe(ev.str(.spell) ?? "", ev.ts, .cast)
        // `<target> resisted your <Spell> <rank>!` — your cast, named with its numeral. The other
        // two resist shapes are somebody else's spell and say nothing about what you own.
        case "resist":
            if !ev.bool(.incoming) && ev.str(.caster) == "you" {
                observe(ev.str(.spell) ?? "", ev.ts, .cast)
            }
        default: break
        }
    }

    /// Moves on a rank sighting that reached the map. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": rows.json(\.json)] }
}

// MARK: - Checkpoint

extension ObservedSpellRanksModule: FoldCheckpointable {
    /// Rows in map order (the snapshot serializes them from it), the fold cursor, and the announce
    /// cursor views resume against. `knownSpell` is the constructor's dependency — installed
    /// knowledge, not folded state — and is deliberately absent.
    public func checkpointState() -> JSONValue {
        .object([
            "rows": rows.checkpoint { row in
                var o: [String: JSONValue] = ["key": .string(row.key), "name": .string(row.name),
                                              "rank": .int(row.rank), "merges": .int(row.merges),
                                              "firstAt": .int(row.firstAt), "lastAt": .int(row.lastAt)]
                if let m = row.mergedRank { o["mergedRank"] = .int(m) }
                if let c = row.castRank { o["castRank"] = .int(c) }
                return .object(o)
            },
            "seq": .int(seq),
            "announce": .int(announce.cursor),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let savedSeq = state["seq"].int64,
              let cursor = state["announce"].int64,
              let m = JSMap<ObservedSpellRankRow>.fromCheckpoint(state["rows"], { v in
                  guard let key = v["key"].string, let name = v["name"].string,
                        let rank = v["rank"].int64, let merges = v["merges"].int64,
                        let firstAt = v["firstAt"].int64, let lastAt = v["lastAt"].int64
                  else { return nil }
                  return ObservedSpellRankRow(key: key, name: name, rank: rank, merges: merges,
                                              firstAt: firstAt, lastAt: lastAt,
                                              mergedRank: v["mergedRank"].int64,
                                              castRank: v["castRank"].int64)
              })
        else { return false }
        rows = m
        seq = savedSeq
        announce.restore(cursor: cursor)
        return true
    }
}
