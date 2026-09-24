// The mote tracker's fold: motes looted, per corpse, against kills, per difficulty.
//
// Motes of Potential are the Legends currency every mob can drop, and the question a farmer asks
// is not "what dropped" but "WHERE IS IT WORTH STANDING": which mob, at which level, in which zone
// and at which instance difficulty gives the most motes per kill, and whether nameds or trash pay
// better. Three snapshots the engine already publishes answer it between them:
//
//   loot   - every mote you looted, with the corpse it came off and the zone line you were under
//   kills  - every counted kill, per mob, PER TIER (the instance difficulty of the zone you stood in)
//   consider - the level a /con stated for each mob, when you conned it
//
// The denominator is the kills module's count for that mob at that tier, and the numerator is the
// loot module's mote rows for that mob under a zone line of that tier - the two are joined on the
// same `MobKey` fold and the same tier decoding the engine uses. So a rate here is "corpses that
// gave you a mote, per counted kill": a group-mate who loots the corpse takes the mote out of your
// log but not the kill out of your count, which is why the rate is honest about being YOURS.
//
// Difficulty is read off the zone line exactly as the kills module reads it (`JSFn.zoneTier`,
// restated here because the app does not link the fold): `(Awakened)` 1 through `(Refined)` 4, a
// `- Solo/Group` instance with no adjective is the base tier 0, a bare zone is open world.
import Foundation
import EQCompanionCore

// MARK: - The motes

/// The mote ladder, lowest first. Position is the rank a column sorts by; a name off the ladder is
/// still counted, after the known ones.
enum MoteLadder {
    static let ranks: [String] = ["Infinitesimal", "Minor", "Lesser", "", "Major", "Greater",
                                  "Superior", "Grand", "Ascendant", "Infinite"]

    /// `Mote of Lesser Potential` -> `Lesser`; `Mote of Potential` -> `` (the plain one). Nil for
    /// anything that is not a mote.
    static func grade(_ item: String) -> String? {
        let base = LootName.normalize(item).trimmingCharacters(in: .whitespaces)
        guard base.lowercased().hasPrefix("mote of "), base.lowercased().hasSuffix(" potential") else { return nil }
        let inner = base.dropFirst("mote of ".count).dropLast(" potential".count)
        return String(inner).trimmingCharacters(in: .whitespaces)
    }

    static func rank(_ grade: String) -> Int {
        ranks.firstIndex { $0.caseInsensitiveCompare(grade) == .orderedSame } ?? ranks.count
    }

    static func label(_ grade: String) -> String { grade.isEmpty ? "Potential" : grade }
}

// MARK: - The difficulty

/// `(base zone, tier)` from a zone line, the kills module's decoding restated.
enum ZoneTier {
    static let openWorld = KillRecord.openWorld
    static let unknown = KillRecord.unknownTier

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }
    private static let soloGroup = rx("\\s*-\\s*(?:Solo|Group)\\b.*$", [.caseInsensitive])
    private static let numberedParen = rx("\\s+\\d+\\s*\\([^)]*\\)\\s*$")
    private static let paren = rx("\\s+\\([^)]*\\)\\s*$")
    private static let adjective = rx("\\(([A-Za-z]+)\\)\\s*$")
    private static let instance = rx("\\s-\\s*(?:Solo|Group)\\b", [.caseInsensitive])

    private static func strip(_ s: String, _ r: NSRegularExpression) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func adjectiveTier(_ word: String) -> Int? {
        switch word.lowercased() {
        case "awakened": return 1
        case "adaptive": return 2
        case "fused": return 3
        case "refined": return 4
        default: return nil
        }
    }

    static func decode(_ zone: String?) -> (base: String, tier: Int) {
        guard let zone else { return ("", unknown) }
        let base = strip(strip(strip(zone, soloGroup), numberedParen), paren).trimmingCharacters(in: .whitespaces)
        if let m = adjective.firstMatch(in: zone, range: NSRange(zone.startIndex..., in: zone)),
           let r = Range(m.range(at: 1), in: zone) {
            return (base, adjectiveTier(String(zone[r])) ?? unknown)
        }
        if instance.firstMatch(in: zone, range: NSRange(zone.startIndex..., in: zone)) != nil { return (base, 0) }
        return (base, base.isEmpty ? unknown : openWorld)
    }

    /// The difficulty as the Raid Targets tab spells it (`D3`, `OW`, `?`).
    static func label(_ tier: Int) -> String { RaidTier.style(tier).label }
    static func longLabel(_ tier: Int) -> String { RaidTier.style(tier).long }
}

// MARK: - The rows

/// One mob at one difficulty: what you killed, what it gave.
struct MoteRow: Identifiable, Equatable {
    var key: String
    var mob: String
    var zone: String
    var tier: Int
    /// The level a /con stated, else the catalog's lowest stated level; nil when neither knows.
    var level: Int?
    var named: Bool
    var kills: Int
    /// Corpses that gave at least one mote row - a loot line is one corpse.
    var corpses: Int
    /// Motes in total, stacks summed.
    var motes: Int
    var byGrade: [String: Int]
    var lastTs: Int64

    var id: String { key }
    /// Corpses with a mote per counted kill. Capped at 1: a corpse can be looted once, so anything
    /// above it is a kill the module did not count, not a 110% drop rate.
    var rate: Double? { kills > 0 ? min(1, Double(corpses) / Double(kills)) : nil }
    var perKill: Double? { kills > 0 ? Double(motes) / Double(kills) : nil }
}

enum MoteGroupBy: String, CaseIterable, Identifiable {
    case mob, zone, difficulty, named, level
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mob: return "Mob"
        case .zone: return "Zone"
        case .difficulty: return "Difficulty"
        case .named: return "Named vs trash"
        case .level: return "Level"
        }
    }
}

enum MoteStats {
    /// What the fold needs to know about a mob beyond the log.
    struct MobFacts {
        var catalogLevel: String?
        var catalogZone: String?
        var dropsRareLoot: Bool
    }

    /// The lowest level a catalog span states: `49-55` -> 49, `56` -> 56, `??` -> nil.
    static func lowestLevel(_ text: String?) -> Int? {
        guard let text else { return nil }
        var digits = ""
        for c in text {
            if c.isNumber { digits.append(c) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }

    /// The fold. `kills` is a `KillRecord.index` result; `conLevels` is keyed by `MobKey`.
    static func fold(events: [LootEvent], kills: [String: KillInfo], conLevels: [String: Int],
                     facts: (String) -> MobFacts) -> [MoteRow] {
        struct Acc { var mob: String; var zone: String; var tier: Int; var corpses = 0; var motes = 0
                     var byGrade: [String: Int] = [:]; var lastTs: Int64 = 0 }
        var acc: [String: Acc] = [:]
        func slot(_ mob: String, _ zone: String, _ tier: Int) -> String { MobKey.of(mob) + "|" + String(tier) }

        // The motes, per (mob, tier), under the zone line each was looted beneath.
        for e in events where e.isAcquisition {
            guard let grade = MoteLadder.grade(e.item), let source = e.source, !source.isEmpty else { continue }
            let (base, tier) = ZoneTier.decode(e.zone)
            let k = slot(source, base, tier)
            var a = acc[k] ?? Acc(mob: source, zone: base, tier: tier)
            a.corpses += 1
            a.motes += max(1, e.count)
            a.byGrade[grade, default: 0] += max(1, e.count)
            a.lastTs = max(a.lastTs, e.ts)
            if a.zone.isEmpty { a.zone = base }
            acc[k] = a
        }
        // The kills, per (mob, tier) - including mobs that never gave a mote, so a zero is a fact.
        for (mobKey, info) in kills {
            for (tier, run) in info.tiers where run.count > 0 {
                let k = mobKey + "|" + String(tier)
                if acc[k] == nil { acc[k] = Acc(mob: info.display, zone: "", tier: tier, lastTs: run.lastTs) }
            }
        }

        return acc.map { k, a in
            let mobKey = MobKey.of(a.mob)
            let f = facts(a.mob)
            let killed = kills[mobKey]?.tiers[a.tier]?.count ?? 0
            let zone = a.zone.isEmpty ? (f.catalogZone ?? "") : a.zone
            return MoteRow(key: k, mob: a.mob, zone: zone, tier: a.tier,
                           level: conLevels[mobKey] ?? lowestLevel(f.catalogLevel),
                           named: MobNameConvention.isNamed(a.mob, level: f.catalogLevel, dropsRareLoot: f.dropsRareLoot),
                           kills: killed, corpses: a.corpses, motes: a.motes, byGrade: a.byGrade,
                           lastTs: max(a.lastTs, kills[mobKey]?.tiers[a.tier]?.lastTs ?? 0))
        }
    }

    /// The whole fold from the three module snapshots, with the catalog as the facts source — what the
    /// Motes tab and the Overview card both draw.
    @MainActor
    static func rows(loot: JSONValue, kills: JSONValue, consider: JSONValue) -> [MoteRow] {
        let data = GameData.shared
        return fold(events: LootEvent.parse(loot), kills: KillRecord.index(KillRecord.parse(kills)),
                    conLevels: conLevels(consider)) { name in
            let m = data.mob(named: name)
            return MobFacts(catalogLevel: m?.level, catalogZone: m?.zones.first,
                            dropsRareLoot: data.dropsRareLoot(name))
        }
    }

    /// The consider ring folded to one level per mob: the most recent con wins.
    static func conLevels(_ state: JSONValue) -> [String: Int] {
        var out: [String: (Int64, Int)] = [:]
        for r in state["ring"].array ?? [] {
            guard let mob = r["mob"].string, let level = r["level"].int else { continue }
            let ts = r["ts"].int64 ?? 0
            let k = MobKey.of(mob)
            if (out[k]?.0 ?? -1) <= ts { out[k] = (ts, level) }
        }
        return out.mapValues(\.1)
    }

    /// Rows summed under a coarser identity. Sums, never averages of averages: the rate of a group
    /// is its corpses over its kills.
    static func group(_ rows: [MoteRow], by: MoteGroupBy) -> [MoteRow] {
        if by == .mob { return rows }
        func label(_ r: MoteRow) -> (key: String, mob: String, zone: String, tier: Int, level: Int?, named: Bool) {
            switch by {
            case .mob: return (r.key, r.mob, r.zone, r.tier, r.level, r.named)
            case .zone: return ("zone|" + r.zone.lowercased() + "|" + String(r.tier), r.zone.isEmpty ? "(zone not stated)" : r.zone, r.zone, r.tier, nil, false)
            case .difficulty: return ("tier|" + String(r.tier), ZoneTier.longLabel(r.tier), "", r.tier, nil, false)
            case .named: return ("named|" + (r.named ? "1" : "0"), r.named ? "Named & rare" : "Common spawns", "", ZoneTier.unknown, nil, r.named)
            case .level:
                let band = r.level.map { ($0 / 5) * 5 }
                return ("level|" + (band.map(String.init) ?? "?"), band.map { "Level \($0)-\($0 + 4)" } ?? "Level not stated", "", ZoneTier.unknown, band, false)
            }
        }
        var out: [String: MoteRow] = [:]
        for r in rows {
            let l = label(r)
            var g = out[l.key] ?? MoteRow(key: l.key, mob: l.mob, zone: l.zone, tier: l.tier, level: l.level, named: l.named,
                                          kills: 0, corpses: 0, motes: 0, byGrade: [:], lastTs: 0)
            g.kills += r.kills; g.corpses += r.corpses; g.motes += r.motes; g.lastTs = max(g.lastTs, r.lastTs)
            for (grade, n) in r.byGrade { g.byGrade[grade, default: 0] += n }
            out[l.key] = g
        }
        return Array(out.values)
    }

    /// Every grade any row carries, ladder order.
    static func grades(_ rows: [MoteRow]) -> [String] {
        Set(rows.flatMap { $0.byGrade.keys }).sorted { MoteLadder.rank($0) != MoteLadder.rank($1) ? MoteLadder.rank($0) < MoteLadder.rank($1) : $0 < $1 }
    }

    /// Column sort. Numeric columns sort both ways with a name tiebreak; text columns by name.
    static func compare(_ a: MoteRow, _ b: MoteRow, key: String, descending: Bool) -> Bool {
        func num(_ r: MoteRow) -> Double? {
            switch key {
            case "kills": return Double(r.kills)
            case "corpses": return Double(r.corpses)
            case "motes": return Double(r.motes)
            case "rate": return r.rate
            case "perKill": return r.perKill
            case "level": return r.level.map(Double.init)
            case "tier": return Double(r.tier)
            case "last": return Double(r.lastTs)
            default:
                if key.hasPrefix("grade:") { return Double(r.byGrade[String(key.dropFirst(6))] ?? 0) }
                return nil
            }
        }
        let byName = a.mob.localizedCaseInsensitiveCompare(b.mob) == .orderedAscending
        switch key {
        case "mob": return descending ? !byName && a.mob != b.mob : byName
        case "zone":
            if a.zone != b.zone { return descending ? a.zone > b.zone : a.zone < b.zone }
            return byName
        case "named":
            if a.named != b.named { return descending ? a.named : b.named }
            return byName
        default:
            let x = num(a), y = num(b)
            if x != y {
                guard let x else { return false }       // nil sorts last both ways
                guard let y else { return true }
                return descending ? x > y : x < y
            }
            return byName
        }
    }
}

// MARK: - The Overview's breakdown

/// The Overview card's reading of the same rows the Motes tab draws: totals, one line per
/// difficulty, the grade mix and the best sources. Sums of `MoteRow`s, never a second fold, so the
/// card and the tab cannot disagree.
struct MoteBreakdown: Equatable {
    struct TierLine: Identifiable, Equatable {
        var tier: Int
        var motes: Int
        var kills: Int
        var corpses: Int
        var id: Int { tier }
        var perKill: Double? { kills > 0 ? Double(motes) / Double(kills) : nil }
    }

    var motes = 0
    var kills = 0
    /// Open world, then D0…D4, then "not stated" — the ladder, not the counts, decides the order.
    var tiers: [TierLine] = []
    /// Grade → motes, ladder order.
    var grades: [(grade: String, motes: Int)] = []
    /// The mobs (at a difficulty) that gave the most motes, best first.
    var top: [MoteRow] = []

    var isEmpty: Bool { motes == 0 }
    var perKill: Double? { kills > 0 ? Double(motes) / Double(kills) : nil }
    /// The difficulty paying the most motes per kill, among those with enough kills to say so.
    var bestTier: TierLine? {
        tiers.filter { $0.kills >= MoteBreakdown.minKillsForBest && $0.motes > 0 }
            .max { ($0.perKill ?? 0) < ($1.perKill ?? 0) }
    }

    /// Below this many kills a per-kill rate is a coin flip, not a recommendation.
    static let minKillsForBest = 10

    static func build(_ rows: [MoteRow], top n: Int = 3) -> MoteBreakdown {
        var b = MoteBreakdown()
        var byTier: [Int: TierLine] = [:]
        var byGrade: [String: Int] = [:]
        for r in rows {
            b.motes += r.motes
            b.kills += r.kills
            var t = byTier[r.tier] ?? TierLine(tier: r.tier, motes: 0, kills: 0, corpses: 0)
            t.motes += r.motes; t.kills += r.kills; t.corpses += r.corpses
            byTier[r.tier] = t
            for (g, c) in r.byGrade { byGrade[g, default: 0] += c }
        }
        func ladder(_ tier: Int) -> Int { tier == ZoneTier.unknown ? Int.max : tier }
        b.tiers = byTier.values.filter { $0.motes > 0 || $0.kills > 0 }.sorted { ladder($0.tier) < ladder($1.tier) }
        b.grades = MoteStats.grades(rows).map { ($0, byGrade[$0] ?? 0) }
        b.top = Array(rows.filter { $0.motes > 0 }
            .sorted { $0.motes != $1.motes ? $0.motes > $1.motes : $0.mob < $1.mob }
            .prefix(n))
        return b
    }

    static func == (a: MoteBreakdown, b: MoteBreakdown) -> Bool {
        a.motes == b.motes && a.kills == b.kills && a.tiers == b.tiers && a.top == b.top
            && a.grades.map(\.grade) == b.grades.map(\.grade) && a.grades.map(\.motes) == b.grades.map(\.motes)
    }
}
