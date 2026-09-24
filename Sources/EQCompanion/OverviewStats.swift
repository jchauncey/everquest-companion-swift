// The Overview's play statistics: what you looted, what you sold and for how much, what you killed,
// and how hard you hit across every fight. Pure summaries of module snapshots the engine already
// publishes (`loot`, `sales`, `kills`, `combat.snapshot`'s segment list) - sums and top-N, never a
// second reading of the log, so each card agrees with the tab it links to.
import Foundation
import EQCompanionCore

// MARK: - Coin

enum Coin {
    /// Copper as the game says it, biggest two denominations: `13,753pp 5gp`, `4gp 3sp`, `7cp`.
    static func text(_ copper: Int64) -> String {
        if copper == 0 { return "0cp" }
        let parts: [(Int64, String)] = [(copper / 1000, "pp"), (copper % 1000 / 100, "gp"),
                                         (copper % 100 / 10, "sp"), (copper % 10, "cp")]
        let shown = parts.drop { $0.0 == 0 }.prefix(2).filter { $0.0 > 0 }
        return shown.map { "\(Format.count(Int($0.0)))\($0.1)" }.joined(separator: " ")
    }
}

// MARK: - Loot

struct LootSummary: Equatable {
    struct Top: Equatable, Identifiable { var item: String; var count: Int; var id: String { item } }

    /// Items that came off a corpse or chest, stacks counted: everything but a destroy.
    var items = 0
    var lines = 0
    var distinct = 0
    /// Of `items`: kept in bags, auto-sold, stored (hoard, depot, currency), used in a combine.
    var kept = 0, sold = 0, stored = 0, combined = 0
    var top: [Top] = []

    static func build(_ events: [LootEvent], top n: Int = 5) -> LootSummary {
        var s = LootSummary()
        var byItem: [String: (String, Int)] = [:]
        for e in events where e.isAcquisition {
            let c = max(1, e.count)
            s.items += c
            s.lines += 1
            switch e.disposition {
            case "sold": s.sold += c
            case "hoard", "depot", "currency": s.stored += c
            case "combined": s.combined += c
            default: s.kept += c
            }
            let prev = byItem[e.countKey] ?? (e.item, 0)
            byItem[e.countKey] = (prev.0, prev.1 + c)
        }
        s.distinct = byItem.count
        s.top = byItem.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(n).map { Top(item: $0.0, count: $0.1) }
        return s
    }
}

// MARK: - Sales

struct SalesSummary: Equatable {
    struct Channel: Equatable { var sales = 0, items = 0, free = 0; var copper: Int64 = 0 }
    struct Top: Equatable, Identifiable { var item: String; var count: Int; var copper: Int64; var id: String { item } }

    var auto = Channel()
    var vendor = Channel()
    var copper: Int64 = 0
    var distinct = 0
    var top: [Top] = []

    var sales: Int { auto.sales + vendor.sales }
    var items: Int { auto.items + vendor.items }

    /// The `sales` module snapshot's `state`.
    static func parse(_ state: JSONValue, top n: Int = 5) -> SalesSummary {
        func channel(_ v: JSONValue) -> Channel {
            Channel(sales: v["sales"].int ?? 0, items: v["items"].int ?? 0, free: v["free"].int ?? 0,
                    copper: v["copper"].int64 ?? 0)
        }
        var s = SalesSummary()
        s.auto = channel(state["auto"])
        s.vendor = channel(state["vendor"])
        s.copper = state["copper"].int64 ?? (s.auto.copper + s.vendor.copper)
        s.distinct = state["distinctItems"].int ?? 0
        s.top = (state["items"].array ?? []).prefix(n).compactMap { v in
            guard let item = v["item"].string else { return nil }
            return Top(item: item, count: v["count"].int ?? 0, copper: v["copper"].int64 ?? 0)
        }
        return s
    }
}

// MARK: - Kills

struct KillSummary: Equatable {
    struct TierLine: Equatable, Identifiable { var tier: Int; var kills: Int; var id: Int { tier } }
    struct Top: Equatable, Identifiable { var mob: String; var kills: Int; var id: String { mob } }

    var kills = 0
    var distinct = 0
    /// Open world, D0…D4, not stated - ladder order.
    var tiers: [TierLine] = []
    var top: [Top] = []
    var firstTs: Int64 = 0
    var lastTs: Int64 = 0

    /// `index` is `KillRecord.index` over the kills snapshot.
    static func build(_ index: [String: KillInfo], top n: Int = 5) -> KillSummary {
        var s = KillSummary()
        var byTier: [Int: Int] = [:]
        for info in index.values where info.count > 0 {
            s.kills += info.count
            s.distinct += 1
            for (tier, run) in info.tiers where run.count > 0 { byTier[tier, default: 0] += run.count }
            if s.firstTs == 0 || (info.firstTs > 0 && info.firstTs < s.firstTs) { s.firstTs = info.firstTs }
            s.lastTs = max(s.lastTs, info.lastTs)
        }
        func ladder(_ t: Int) -> Int { t == ZoneTier.unknown ? Int.max : t }
        s.tiers = byTier.map { TierLine(tier: $0.key, kills: $0.value) }.sorted { ladder($0.tier) < ladder($1.tier) }
        s.top = index.values.filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.display < $1.display }
            .prefix(n).map { Top(mob: $0.display, kills: $0.count) }
        return s
    }
}

// MARK: - DPS across every fight

struct FightSeries: Equatable {
    struct Point: Equatable, Identifiable {
        var t: Date
        var dps: Double
        var fights: Int
        var id: Date { t }
    }

    var points: [Point] = []
    var fights = 0
    /// Damage over active seconds, across every fight: the honest average, not a mean of means.
    var average: Double = 0
    var best: (name: String, dps: Double)?
    var span: (Date, Date)?

    /// A fight shorter than this is a stray swing, not a fight worth a rate.
    static let minActiveSec = 5.0

    /// `segments` is `combat.snapshot`'s `segments` array. Fights are bucketed across their own
    /// span into at most `buckets` points, each the bucket's damage over its active seconds.
    static func build(_ segments: [JSONValue], buckets: Int = 120) -> FightSeries {
        struct F { var ts: Int64; var total: Double; var active: Double; var name: String }
        let fights: [F] = segments.compactMap { v in
            guard v["kind"].string == "fight", let ts = v["startTs"].int64 else { return nil }
            let active = v["activeSec"].double ?? 0
            let total = v["total"].double ?? 0
            guard active >= minActiveSec, total > 0 else { return nil }
            return F(ts: ts, total: total, active: active, name: v["name"].string ?? "")
        }.sorted { $0.ts < $1.ts }
        var s = FightSeries()
        guard let first = fights.first, let last = fights.last else { return s }
        s.fights = fights.count
        let total = fights.reduce(0) { $0 + $1.total }, active = fights.reduce(0) { $0 + $1.active }
        s.average = active > 0 ? total / active : 0
        if let b = fights.max(by: { $0.total / $0.active < $1.total / $1.active }) { s.best = (b.name, b.total / b.active) }
        s.span = (Date(timeIntervalSince1970: Double(first.ts) / 1000), Date(timeIntervalSince1970: Double(last.ts) / 1000))

        let n = max(1, min(buckets, fights.count))
        let width = max(1, (last.ts - first.ts) / Int64(n) + 1)
        var acc: [Int: (total: Double, active: Double, fights: Int, ts: Int64)] = [:]
        for f in fights {
            let i = Int((f.ts - first.ts) / width)
            var a = acc[i] ?? (0, 0, 0, first.ts + Int64(i) * width)
            a.total += f.total; a.active += f.active; a.fights += 1
            acc[i] = a
        }
        s.points = acc.keys.sorted().compactMap { i in
            guard let a = acc[i], a.active > 0 else { return nil }
            return Point(t: Date(timeIntervalSince1970: Double(a.ts) / 1000), dps: a.total / a.active, fights: a.fights)
        }
        return s
    }

    static func == (a: FightSeries, b: FightSeries) -> Bool {
        a.points == b.points && a.fights == b.fights && a.average == b.average
            && a.best?.name == b.best?.name && a.best?.dps == b.best?.dps
    }
}
