// The resist ledger: per-source buckets of pooled observations, and the key they pool by
// (fold/src/modules/resist/ledger.rs).
//
// A re-fold replaces a source's bucket, it never adds to it. `beginSource(key)` discards the bucket
// before its log is folded again; a bucket for a character you are not folding survives untouched.
//
// A bucket holds counts, never verdicts. The pooling key is every term of `rc` except R itself, plus
// the week. The class count is keyed on only when overchannel was up, since that is the only time it
// moves `rc`. Weekly because a 21-day half-life cannot use a finer resolution.
//
// The week key is UTC arithmetic on the epoch instant, so a timezone cannot move it. ISO's year rule
// is ported rather than approximated (the week belongs to the year containing its Thursday), because
// the string is a key compared across builds.
import Foundation
import EQCompanionCore

/// Rust's `str` ordering is a byte compare; Swift's `<` is not. Every sort the Rust does over keys
/// that reach a pooling key or a serialized order goes through this.
@inline(__always)
func rustLess(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

public enum ResistCasterKind: String, Equatable, Sendable {
    case selfCast = "self"
    case pc = "pc"
    case npc = "npc"
}

public enum ResistFamily: String, Equatable, Sendable {
    case cast = "cast"
    case song = "song"
}

/// Everything a row is keyed by, plus the two things that ride along for the UI and are deliberately
/// not in the key: `zone`, and the catalog range beside the midpoint.
public struct ResistRowSpec: Equatable, Sendable {
    public var mobKey: String
    public var zone: String?
    public var spellKey: String
    public var family: ResistFamily
    public var casterKind: ResistCasterKind
    public var casterLevel: Int64?
    public var mobLevel: Int64?
    public var mobLevelLo: Int64?
    public var mobLevelHi: Int64?
    public var debuffs: String
    public var rank: Int64
    public var overchannel: Bool?
    public var casterClasses: Int64?
    public var week: String?

    public init(mobKey: String, zone: String? = nil, spellKey: String, family: ResistFamily,
                casterKind: ResistCasterKind, casterLevel: Int64? = nil, mobLevel: Int64? = nil,
                mobLevelLo: Int64? = nil, mobLevelHi: Int64? = nil, debuffs: String = "",
                rank: Int64 = 0, overchannel: Bool? = nil, casterClasses: Int64? = nil,
                week: String? = nil) {
        self.mobKey = mobKey; self.zone = zone; self.spellKey = spellKey; self.family = family
        self.casterKind = casterKind; self.casterLevel = casterLevel; self.mobLevel = mobLevel
        self.mobLevelLo = mobLevelLo; self.mobLevelHi = mobLevelHi; self.debuffs = debuffs
        self.rank = rank; self.overchannel = overchannel; self.casterClasses = casterClasses
        self.week = week
    }
}

/// The spec plus what accretes onto it. A class, so `ResistBucket.row` hands back the row itself the
/// way the Rust hands back `&mut ResistRow`.
public final class ResistRow {
    public var spec: ResistRowSpec
    public var resist: Int64
    public var land: Int64
    /// The damage histogram, keyed by the decimal number the line printed.
    public var dmg: [String: Int64]
    /// The row gave up on the histogram — see `addDamage`.
    public var variable: Bool
    public var firstTs: Int64
    public var lastTs: Int64

    public init(spec: ResistRowSpec, resist: Int64 = 0, land: Int64 = 0, dmg: [String: Int64] = [:],
                variable: Bool = false, firstTs: Int64, lastTs: Int64) {
        self.spec = spec; self.resist = resist; self.land = land; self.dmg = dmg
        self.variable = variable; self.firstTs = firstTs; self.lastTs = lastTs
    }
}

public enum ResistLedger {
    public static let maxDistinctDamageValues = 32

    static let dayMs: Int64 = 86_400_000
    static let weekMs: Int64 = 7 * 86_400_000
    /// 1970-01-01 was a Thursday, so the Monday opening epoch week zero is three days earlier.
    static let epochMonday: Int64 = -3 * 86_400_000

    /// Rust's `i64::div_euclid`, which is what the app's `Math.floor` does; truncation parts company
    /// with it before 1970.
    @inline(__always)
    static func divEuclid(_ a: Int64, _ b: Int64) -> Int64 {
        var q = a / b
        if a % b < 0 { q -= b > 0 ? 1 : -1 }
        return q
    }

    /// Monday 00:00 UTC of the week containing `ts`.
    public static func weekStart(_ ts: Int64) -> Int64 {
        divEuclid(ts - epochMonday, weekMs) * weekMs + epochMonday
    }

    /// The ISO-8601 week the instant falls in, as `2026-W33`.
    public static func isoWeekKey(_ ts: Int64) -> String {
        let monday = weekStart(ts)
        // The year of the week's Thursday, which is ISO's own rule.
        let year = civilYearOf(monday + 3 * dayMs)
        let week = roundHalfUp(Double(monday - weekStart(jan4UTC(year))) / Double(weekMs)) + 1
        return "\(year)-W" + String(format: "%02lld", week)
    }

    /// JS `Math.round`: half goes up, unlike Swift's `rounded()`, which goes away from zero.
    static func roundHalfUp(_ v: Double) -> Int64 { Int64((v + 0.5).rounded(.down)) }

    /// January 4th, the day ISO guarantees is in week 1.
    static func jan4UTC(_ year: Int64) -> Int64 { daysFromCivil(year, 1, 4) * dayMs }

    /// The proleptic Gregorian year an epoch instant falls in.
    static func civilYearOf(_ ms: Int64) -> Int64 {
        let days = divEuclid(ms, dayMs)
        // Howard Hinnant's `civil_from_days`, reduced to the year it answers.
        let z = days + 719_468
        let era = divEuclid(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        return mp >= 10 ? y + 1 : y
    }

    /// Howard Hinnant's `days_from_civil`, the inverse of the above.
    static func daysFromCivil(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = divEuclid(y, 400)
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// A string compare, and it is exact: `YYYY-Www` is zero-padded and fixed-width, so lexicographic
    /// order is chronological order, ISO's year-boundary rule included.
    public static func laterWeek(_ a: String?, _ b: String?) -> String? {
        switch (a, b) {
        case (nil, let b): return b
        case (let a, nil): return a
        case (.some(let a), .some(let b)): return rustLess(a, b) ? b : a
        }
    }

    /// The pooling key, term for term and separator for separator with the app's `rowKey`.
    public static func rowKey(_ row: ResistRowSpec) -> String {
        func num(_ v: Int64?) -> String { v.map(String.init) ?? "" }
        let oc: String
        switch row.overchannel {
        case nil: oc = "?"
        case .some(true): oc = "oc"
        case .some(false): oc = "-"
        }
        let classes = row.overchannel == true ? String(row.casterClasses ?? 0) : ""
        return [
            row.mobKey,
            row.spellKey,
            row.family.rawValue,
            row.casterKind.rawValue,
            num(row.casterLevel),
            num(row.mobLevel),
            row.debuffs,
            String(row.rank),
            oc,
            classes,
            row.week ?? ""
        ].joined(separator: "|")
    }

    /// Record one damage number.
    ///
    /// Past the cap the row gives up on the histogram: a spell whose damage genuinely varies carries
    /// no partial information anyway, and an unbounded map is a disk-size bug with a long tail.
    /// `variable` says the give-up happened, so a reader can tell it from a rarely-cast spell.
    public static func addDamage(_ row: ResistRow, _ amount: Int64) {
        let key = String(amount)
        if row.variable {
            row.land += 1
            return
        }
        if row.dmg[key] == nil && row.dmg.count >= maxDistinctDamageValues {
            row.variable = true
            for count in row.dmg.values { row.land += count }
            row.dmg.removeAll()
            row.land += 1
            return
        }
        row.dmg[key, default: 0] += 1
    }
}

/// One bucket, accreting. A `JSMap` so insertion order is kept: only the count is published today,
/// but the app publishes the rows in that order and this must be able to.
public final class ResistBucket {
    var byKey = JSMap<ResistRow>()
    var newest: String?

    public init() {}

    public var count: Int { byKey.count }
    public var isEmpty: Bool { byKey.isEmpty }

    /// The newest week this bucket holds — the instant every row's age is measured against.
    /// Maintained as rows arrive rather than scanned for.
    public var newestWeek: String? { newest }

    public var rows: [ResistRow] { byKey.values }

    /// The serialization order: sorted by pooling key so a re-run on unchanged input diffs to
    /// nothing. Insertion order is what the fold walks; key order is only what the writer needs.
    public func rowsInKeyOrder() -> [ResistRow] {
        byKey.pairs.sorted { rustLess($0.0, $1.0) }.map(\.1)
    }

    /// Seed one persisted row, filed under its own pooling key — which is what makes a seed
    /// idempotent with a fold. The newest week moves with it.
    public func seedRow(_ row: ResistRow) {
        newest = ResistLedger.laterWeek(newest, row.spec.week)
        byKey.insert(ResistLedger.rowKey(row.spec), row)
    }

    /// Get or mint the row this spec pools into, widening its span.
    ///
    /// A minted row is a row even if nothing is then counted on it: damage mints the row before the
    /// tick handler decides the tick is a repeat, so the ledger carries all-zero rows and the
    /// golden's `rows` integer counts them.
    public func row(_ spec: ResistRowSpec, _ ts: Int64) -> ResistRow {
        newest = ResistLedger.laterWeek(newest, spec.week)
        let key = ResistLedger.rowKey(spec)
        if !byKey.containsKey(key) {
            byKey.insert(key, ResistRow(spec: spec, firstTs: ts, lastTs: ts))
        }
        let row = byKey[key]!
        if ts < row.firstTs { row.firstTs = ts }
        if ts > row.lastTs { row.lastTs = ts }
        return row
    }
}

/// Every bucket, keyed by source.
public final class ResistLedgerStore {
    var buckets = JSMap<ResistBucket>()

    public init() {}

    /// Discard a source's bucket before its log is folded again. The idempotence seam.
    public func beginSource(_ key: String) { buckets.insert(key, ResistBucket()) }

    /// Every source key, ascending: the order the file's `sources` array is written in.
    public func sourceKeys() -> [String] { buckets.keys.sorted(by: rustLess) }

    /// One bucket, read-only. `nil` rather than an empty bucket for a source never held.
    public func bucket(_ key: String) -> ResistBucket? { buckets[key] }

    public func bucketMut(_ key: String) -> ResistBucket {
        if !buckets.containsKey(key) { buckets.insert(key, ResistBucket()) }
        return buckets[key]!
    }

    /// The newest week any bucket holds.
    public func newestWeek() -> String? {
        var best: String?
        for bucket in buckets.values { best = ResistLedger.laterWeek(best, bucket.newestWeek) }
        return best
    }

    /// The module's whole published surface: how many pooled rows the ledger holds, and how many
    /// distinct creatures they are about.
    public func counts() -> (rows: Int, mobs: Int) {
        var rows = 0
        var mobs = Set<String>()
        for bucket in buckets.values {
            rows += bucket.count
            for row in bucket.rows { mobs.insert(row.spec.mobKey) }
        }
        return (rows, mobs.count)
    }
}
