// The Leveling tab's pure folds over the `leveling` and `character` modules: the AA accounting
// identity, the AA ladder ledger, the ding series, and the stated-level read.
//
// Ported from src/shared/aa.ts, src/shared/aaLedger.ts, src/shared/currentLevel.ts and
// src/renderer/src/features/leveling/{levelSeries,useLevelingSeries}.ts — same arithmetic, same
// wording. Nothing here touches SwiftUI or the engine, so every number can be reasoned about
// against the module JSON on its own.
import Foundation
import EQCompanionCore

// MARK: - Formatting

/// The feature's duration/rate formatters. Two duration shapes, exactly as the Electron feature
/// has (levelChartGeometry.ts): `delta` answers "how long ago" in one magnitude, `duration`
/// answers "how much time is in this span" and owes the minutes.
enum LevelingFormat {
    static let none = "-"

    /// `38m` / `2.7h` / `3.1d` — one magnitude, one decimal.
    static func delta(_ ms: Double) -> String {
        if ms <= 0 { return none }
        let mins = ms / 60_000
        if mins < 60 { return "\(Int(mins.rounded()))m" }
        let hrs = mins / 60
        if hrs < 48 { return String(format: "%.1fh", hrs) }
        return String(format: "%.1fd", hrs / 24)
    }

    /// `2h 41m` / `38m` / `45s` / `3d 4h`. Days roll over at 48h, like `delta`.
    static func duration(_ ms: Double) -> String {
        let total = max(0, Int((ms / 1000).rounded()))
        let hrs = total / 3600
        if hrs >= 48 { return "\(hrs / 24)d \(hrs % 24)h" }
        let mins = (total % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return mins > 0 ? "\(mins)m" : "\(total % 60)s"
    }

    /// `formatSmall`: two decimals under 10, one under 100, none above.
    static func small(_ n: Double) -> String {
        guard n.isFinite else { return none }
        let v = abs(n)
        if v >= 100 { return String(format: "%.0f", n) }
        if v >= 10 { return String(format: "%.1f", n) }
        return String(format: "%.2f", n)
    }

    static func aaRate(_ n: Double) -> String { "\(small(n)) AA/hr" }
    static func pointRate(_ n: Double) -> String { "\(small(n)) pts/hr" }

    private static let edgeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    /// `Aug 28, 05:12` — the slice caption's ends (SliceBar.edge, 24-hour).
    static func edge(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return edgeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `1,204` — the headline tiles' thousands separator.
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }
}

// MARK: - The `leveling` snapshot

/// Everything, forever: the uncapped level-up, AA-gain, AA-spend and potion series.
struct LevelingSnap: Sendable {
    struct LevelPoint: Sendable, Identifiable {
        var ts: Int64
        var level: Int
        var id: Int64 { ts &* 100 &+ Int64(level) }
    }

    struct AAGain: Sendable {
        var ts: Int64
        var amount: Int
        var nowHave: Int
    }

    struct AASpend: Sendable {
        var ts: Int64
        var ability: String
        var cost: Int
        var rank: Int?
    }

    var levels: [LevelPoint] = []
    var aaGains: [AAGain] = []
    var aaSpends: [AASpend] = []
    var aaPotions: [Int64] = []

    static let empty = LevelingSnap()

    init() {}

    init(_ v: JSONValue) {
        levels = (v["levels"].array ?? [])
            .map { LevelPoint(ts: $0["ts"].int64 ?? 0, level: $0["level"].int ?? 0) }
            .sorted { $0.ts < $1.ts }
        aaGains = (v["aaGains"].array ?? [])
            .map { AAGain(ts: $0["ts"].int64 ?? 0, amount: $0["amount"].int ?? 0, nowHave: $0["nowHave"].int ?? 0) }
            .sorted { $0.ts < $1.ts }
        // NOT sorted: `computeAAAccounting` folds the spends in log order and the ledger's rank
        // merge keeps the newest cost by timestamp, so log order is the order of record.
        aaSpends = (v["aaSpends"].array ?? []).map {
            AASpend(ts: $0["ts"].int64 ?? 0,
                    ability: $0["ability"].string ?? "",
                    cost: $0["cost"].int ?? 0,
                    rank: $0["rank"].int)
        }
        aaPotions = (v["aaPotions"].array ?? []).compactMap { $0["ts"].int64 }
    }

    var isEmpty: Bool { levels.isEmpty && aaGains.isEmpty }
}

// MARK: - The AA identity (shared/aa.ts)

/// `earned == allocated + unspent`. Refund-proof: allocation is the LATEST purchase of each
/// ability (a respec re-buys the same rung and must not be counted twice), and the unspent
/// balance is the last stated `You now have N` minus every point spent after that line.
struct LvAAAccounting: Sendable {
    var allocated = 0
    var unspent = 0
    var earned = 0
    var boughtCount = 0
    var lifetimeCost = 0

    init() {}

    init(gains: [LevelingSnap.AAGain], spends: [LevelingSnap.AASpend]) {
        lifetimeCost = spends.reduce(0) { $0 + $1.cost }
        var latest: [String: LevelingSnap.AASpend] = [:]
        for s in spends {
            if let prev = latest[s.ability], s.ts < prev.ts { continue }
            latest[s.ability] = s
        }
        for s in latest.values where s.cost > 0 {
            allocated += s.cost
            boughtCount += 1
        }
        if let lastGain = gains.max(by: { $0.ts < $1.ts }) {
            var pool = lastGain.nowHave
            for s in spends where s.ts > lastGain.ts { pool = max(0, pool - s.cost) }
            unspent = pool
        }
        earned = allocated + unspent
    }
}

// MARK: - The AA ladder ledger (shared/aaLedger.ts)

struct LvAaRankRow: Sendable {
    var rank: Int
    var cost: Int
    var ts: Int64
    var buys: Int
}

struct LvAaAbilityRow: Sendable, Identifiable {
    var name: String
    var ranks: [LvAaRankRow]
    var topRank: Int
    var invested = 0
    var paidRanks = 0
    var autoRanks = 0
    var rebuys = 0
    var lastTs: Int64 = 0
    /// ranks below the top one this log never recorded — the ladder is partial, and says so.
    var unlogged: [Int] = []
    var id: String { name }
}

struct LvAaLedgerSummary: Sendable {
    var abilities = 0
    var invested = 0
    var paidRanks = 0
    var autoRanks = 0
    var rebought = 0
    var partial = 0
}

enum LvAaLedger {
    /// `Steadfast Will 4` with `rank: 4` is rung four of the `Steadfast Will` ladder. A name whose
    /// tail does not spell its own rank keeps the name it has.
    static func baseName(_ s: LevelingSnap.AASpend) -> String {
        guard let rank = s.rank else { return s.ability }
        let suffix = " \(rank)"
        return s.ability.hasSuffix(suffix) ? String(s.ability.dropLast(suffix.count)) : s.ability
    }

    static func rows(_ spends: [LevelingSnap.AASpend]) -> [LvAaAbilityRow] {
        var fams: [String: [Int: LvAaRankRow]] = [:]
        var order: [String] = []
        for s in spends {
            let name = baseName(s)
            if fams[name] == nil { fams[name] = [:]; order.append(name) }
            let rank = s.rank ?? 1
            if var prev = fams[name]?[rank] {
                prev.buys += 1
                if s.ts >= prev.ts { prev.ts = s.ts; prev.cost = s.cost }
                fams[name]?[rank] = prev
            } else {
                fams[name]?[rank] = LvAaRankRow(rank: rank, cost: s.cost, ts: s.ts, buys: 1)
            }
        }
        var out: [LvAaAbilityRow] = []
        for name in order {
            guard let byRank = fams[name] else { continue }
            let ranks = byRank.values.sorted { $0.rank < $1.rank }
            guard let top = ranks.last?.rank else { continue }
            var row = LvAaAbilityRow(name: name, ranks: ranks, topRank: top)
            for r in ranks {
                if r.cost > 0 { row.invested += r.cost; row.paidRanks += 1 } else { row.autoRanks += 1 }
                row.rebuys += r.buys - 1
                if r.ts > row.lastTs { row.lastTs = r.ts }
            }
            if top > 1 { row.unlogged = (1..<top).filter { byRank[$0] == nil } }
            out.append(row)
        }
        out.sort { a, b in
            if a.invested != b.invested { return a.invested > b.invested }
            if a.topRank != b.topRank { return a.topRank > b.topRank }
            if a.lastTs != b.lastTs { return a.lastTs > b.lastTs }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return out
    }

    static func summary(_ rows: [LvAaAbilityRow]) -> LvAaLedgerSummary {
        var s = LvAaLedgerSummary(abilities: rows.count)
        for r in rows {
            s.invested += r.invested
            s.paidRanks += r.paidRanks
            s.autoRanks += r.autoRanks
            if r.rebuys > 0 { s.rebought += 1 }
            if !r.unlogged.isEmpty { s.partial += 1 }
        }
        return s
    }

    /// `2-5` when the missing rungs are contiguous, `2, 5` otherwise.
    static func rangeLabel(_ ranks: [Int]) -> String {
        guard let first = ranks.first, let last = ranks.last else { return "" }
        if ranks.count > 1, last - first + 1 == ranks.count { return "\(first)-\(last)" }
        return ranks.map(String.init).joined(separator: ", ")
    }
}

// MARK: - The ding series (levelSeries.ts)

/// A run of level-ups with no class swap in it. A swap re-reports the level of the new (lowest)
/// class, so the level legitimately goes DOWN and the two runs are never joined.
struct LvLevelSegment: Sendable {
    var points: [LevelingSnap.LevelPoint]
    var afterSwap: Bool
}

enum LvLevelSeries {
    static func segments(_ sorted: [LevelingSnap.LevelPoint]) -> [LvLevelSegment] {
        var segs: [LvLevelSegment] = []
        for p in sorted {
            if let last = segs.last?.points.last, p.level >= last.level {
                segs[segs.count - 1].points.append(p)
            } else {
                segs.append(LvLevelSegment(points: [p], afterSwap: !segs.isEmpty))
            }
        }
        return segs
    }

    static func peak(_ sorted: [LevelingSnap.LevelPoint]) -> Int? {
        sorted.map(\.level).max()
    }

    static func swaps(_ segments: [LvLevelSegment]) -> Int {
        segments.reduce(0) { $0 + ($1.afterSwap ? 1 : 0) }
    }

    /// The window's runs, with the run in force at `t0` anchored to its last point before it.
    static func visible(_ segments: [LvLevelSegment], from t0: Int64) -> [LvLevelSegment] {
        var anchorSeg = -1
        for (s, seg) in segments.enumerated() where seg.points[0].ts <= t0 { anchorSeg = s }
        var out: [LvLevelSegment] = []
        for (s, seg) in segments.enumerated() {
            let after = seg.points.filter { $0.ts > t0 }
            var kept = after
            if s == anchorSeg {
                let at = stepIndex(seg.points.map(\.ts), t0)
                if at >= 0 { kept = [seg.points[at]] + after }
            }
            if !kept.isEmpty { out.append(LvLevelSegment(points: kept, afterSwap: seg.afterSwap)) }
        }
        return out
    }

    /// Index of the last entry at or before `ts` (-1 when `ts` precedes the series). The series is
    /// a STEP function, so this is the only correct "value at t".
    static func stepIndex(_ ts: [Int64], _ at: Int64) -> Int {
        var lo = 0, hi = ts.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if ts[mid] <= at { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}

// MARK: - Cumulative AA (useLevelingSeries.ts)

/// Σ of the gain LINES — deliberately not the earned headline, so points re-gained after a respec
/// are counted again and the curve can run ahead of it.
struct LvAaPoint: Sendable {
    var ts: Int64
    var y: Int
    var nowHave: Int
    var gain: Int
}

// MARK: - The stated level (shared/currentLevel.ts)

/// What level am I: the later of the last ding and your own `/who` row. Never `max()` — a loadout
/// swap re-reports the level of the new (lowest) class, so the peak belongs to a class that may no
/// longer be in the loadout and rides the caption instead.
struct LvStatedLevel: Sendable {
    var level: Int?
    var cue = ""
    var title = ""

    static let stalePeriodMs: Int64 = 6 * 3_600_000

    static let empty = LvStatedLevel()

    init() {}

    /// `character.level` IS the resolved statement — the engine already took the later of the ding
    /// and the `/who` row. The ding series is only the fallback for a snapshot that carries none.
    init(character: JSONValue, lastDing: LevelingSnap.LevelPoint?, lastTs: Int64) {
        var level: Int?
        var ts: Int64 = 0
        var source = "ding"
        if let l = character["level"]["level"].int {
            level = l
            ts = character["level"]["ts"].int64 ?? 0
            source = character["level"]["source"].string ?? "ding"
        } else if let d = lastDing {
            level = d.level
            ts = d.ts
        }
        guard let level else { return }
        self.level = level
        let ageMs = max(0, lastTs - ts)
        let stale = ageMs >= Self.stalePeriodMs
        let age = "\(LevelingFormat.duration(Double(ageMs))) ago"
        let said = source == "who" ? "Your own /who row stated this level" : "Your last level-up reported this level"
        let caveat = stale ? " A loadout swap since then would have printed nothing - type /who on yourself to restate it." : ""
        title = "\(said), \(age).\(caveat)"
        if source == "who" {
            cue = stale ? "/who \(age)" : "/who"
        } else {
            cue = stale ? age : ""
        }
    }
}
