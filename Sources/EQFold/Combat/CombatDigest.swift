// A finalized fight's compact detail, kept after its event ring is dropped. NOT A PORT: upstream
// keeps the ring for the last TIMELINE_HISTORY_CAP fights and nothing per-event for the rest, so an
// older fight's DPS curve and damage-by-mob panels had nothing to draw.
//
// The digest is built from the ring at the moment the cap evicts it and holds what those two panels
// (and the damage-by-mob drill) read: a coarse DPS curve (at most `FightDigest.maxBuckets` buckets of
// you / pet / group / incoming damage) and one row per (target, category, lane) of outgoing damage
// with the counters a row shows. A few KB per fight. The ring's own truncation carries over: a fight
// whose ring had already dropped its oldest instants says so.
//
// It is answered only when a snapshot asks for it (`SnapshotOpts.digest`), so no ported answer —
// and no golden — changes shape.
import Foundation
import EQCompanionCore

public struct FightDigest: Sendable, Equatable {
    /// Width of one curve bucket, ms.
    public var bucketMs: Int64
    /// Per bucket, damage by side: [you, pet, group, incoming].
    public var curve: [[Int64]]
    public var rows: [Row]
    /// The ring had already dropped instants before the digest was taken: totals are lower bounds.
    public var truncated: Bool

    public struct Row: Sendable, Equatable {
        public var target: String
        public var category: String
        public var lane: String
        public var total: Int64 = 0
        public var hits: Int64 = 0
        public var crits: Int64 = 0
        public var misses: Int64 = 0
        public var resists: Int64 = 0
        public var maxHit: Int64 = 0
        public var minHit: Int64 = 0
    }

    public static let maxBuckets = 120

    /// The side a timeline kind is drawn on — the DPS curve's four series, as the app groups them.
    static func side(_ kind: String) -> Int {
        switch kind {
        case "you": return 0
        case "pet": return 1
        case "member", "allyPet", "other": return 2
        default: return 3
        }
    }

    public static func build(_ e: Encounter) -> FightDigest {
        let duration = max(1, e.lastTs - e.startTs)
        let bucketMs = max(1000, (duration + Int64(maxBuckets) - 1) / Int64(maxBuckets))
        let n = Int((duration + bucketMs - 1) / bucketMs) + 1
        var curve = [[Int64]](repeating: [0, 0, 0, 0], count: n)
        var rows = JSMap<Row>()
        for r in e.events {
            if r.amount > 0 && r.outcome == nil {
                let i = min(n - 1, max(0, Int((r.ts - e.startTs) / bucketMs)))
                curve[i][side(r.kind)] += r.amount
            }
            if r.kind == "enemy" { continue }
            let target = r.target ?? "unknown"
            let key = target.lowercased() + "\u{0}" + r.category + "\u{0}" + r.lane
            var row = rows[key] ?? Row(target: target, category: r.category, lane: r.lane)
            switch r.outcome {
            case "miss": row.misses += 1
            case "resist": row.resists += 1
            default:
                row.total += r.amount
                row.hits += 1
                if r.crit { row.crits += 1 }
                row.maxHit = max(row.maxHit, r.amount)
                if row.minHit == 0 || r.amount < row.minHit { row.minHit = r.amount }
            }
            rows.insert(key, row)
        }
        // Trailing empty buckets say nothing the duration does not.
        while curve.count > 1, curve.last == [0, 0, 0, 0] { curve.removeLast() }
        return FightDigest(bucketMs: bucketMs, curve: curve, rows: rows.values,
                           truncated: e.eventsTotal > Int64(e.events.count))
    }

    public var json: JSONValue {
        [
            "bucketMs": .int(bucketMs),
            "curve": .array(curve.map { .array($0.map { .int($0) }) }),
            "rows": .array(rows.map { r in
                ["target": .string(r.target), "category": .string(r.category), "lane": .string(r.lane),
                 "total": .int(r.total), "hits": .int(r.hits), "crits": .int(r.crits),
                 "misses": .int(r.misses), "resists": .int(r.resists),
                 "maxHit": .int(r.maxHit), "minHit": .int(r.minHit)]
            }),
            "truncated": .bool(truncated),
        ]
    }

    /// `json` is also the checkpoint form: every field is plain data.
    public static func fromJSON(_ v: JSONValue) -> FightDigest? {
        guard let bucketMs = v["bucketMs"].int64, let curveRows = v["curve"].array,
              let rowValues = v["rows"].array, let truncated = v["truncated"].bool else { return nil }
        var curve: [[Int64]] = []
        for c in curveRows {
            guard let a = c.array, a.count == 4 else { return nil }
            curve.append(a.map { $0.int64 ?? 0 })
        }
        var rows: [Row] = []
        for r in rowValues {
            guard let target = r["target"].string, let category = r["category"].string,
                  let lane = r["lane"].string else { return nil }
            rows.append(Row(target: target, category: category, lane: lane,
                            total: r["total"].int64 ?? 0, hits: r["hits"].int64 ?? 0,
                            crits: r["crits"].int64 ?? 0, misses: r["misses"].int64 ?? 0,
                            resists: r["resists"].int64 ?? 0, maxHit: r["maxHit"].int64 ?? 0,
                            minHit: r["minHit"].int64 ?? 0))
        }
        return FightDigest(bucketMs: bucketMs, curve: curve, rows: rows, truncated: truncated)
    }
}
