// The shared vocabulary of the buffs model: the tuning constants every part of it is calibrated
// against, the record shapes, and the pure helpers. Nothing here holds state.
// (fold/src/modules/buffs_shapes.rs)
import Foundation
import EQLog
import EQCompanionCore

/// Which of the estimator's inputs produced the number.
public enum EstimatorSource: String, Sendable, Equatable {
    /// A clean observed cycle beat the DB floor.
    case observed
    /// A corroborated below-floor cluster removed the DB floor.
    case cluster
    /// The DB floor held.
    case db
    /// A death LOWER BOUND won — the surfaces say "at least".
    case deathBound
}

/// A SPELL property, never a fact about who the spell landed on.
public enum BuffClass: String, Sendable, Equatable { case buff, debuff }

/// An entity's disposition toward the player.
public enum Disposition: String, Sendable, Equatable {
    case zelf = "self"
    case summoned
    case charmed
    case hostile
}

/// One mined duration: a land→end span, the instant the line that ended it arrived, and whether the
/// log named something that ended it early. The `ts` is what lets a line arriving AFTER the mint
/// reach back and annotate the sample it belongs to.
public struct DurationSample: Sendable {
    public var ms: Int64
    /// Event ts of the line that closed the cycle — the join key for a later annotation.
    public var ts: Int64
    /// True when the log stated a CAUSE for the ending, so the span is a lower bound. One-way.
    public var censored: Bool
    /// A death lower bound — the one sample class that is not a cycle at all.
    public var deathBound: Bool

    /// True when a sample is a LOWER BOUND on the duration rather than a measurement of it.
    public var isLowerBound: Bool { censored || deathBound }
}

public enum BuffsShapes {
    /// Land a pending cast this many ms after `castBegin` if nothing cleared it first.
    public static let landTimeoutMs: Int64 = 15_000

    /// Sanity ceiling on a mined duration sample: a land→fade gap beyond it is a missed censor.
    public static let maxSampleMs: Int64 = 3 * 60 * 60_000

    /// Log-hole boundary: an event-time gap of at least this means we may have lost the thread.
    /// It is the DROP threshold, not the HOLD threshold — the hold starts at the detector's 60 s.
    public static let sessionGapMs: Int64 = 30 * 60_000

    /// The unwitnessed-expiry timeout — one rule for every row that is not yours. The timeout comes
    /// from the ESTIMATE'S QUALITY: a learned duration gets 15 s, a DB floor 60 s. A cull is not
    /// evidence: it mints no sample and counts as no break.
    public static func unwitnessedTimeoutMs(_ source: EstimatorSource?) -> Int64 {
        switch source {
        case .observed, .cluster: return 15_000
        default: return 60_000
        }
    }

    /// How long a learning record outlives the row it belonged to — 3x the DB base. The multiple is
    /// of the DB FLOOR rather than of the estimate, because the floor is the one number a bad
    /// observation cannot drag down.
    public static let learningRecordDbMultiple: Int64 = 3

    public static func learningRecordCapMs(_ dbMs: Int64?, _ unknownCapMs: Int64) -> Int64 {
        if let ms = dbMs, ms > 0 { return learningRecordDbMultiple * ms }
        return unknownCapMs
    }

    /// Active-buff HYGIENE cap. An active past this auto-retires — "we lost the thread", never
    /// "it expired".
    public static let hygieneAbsoluteMs: Int64 = 90 * 60_000

    /// `f64` all the way through: `p75` interpolates, so `2 * p75` is routinely a half-millisecond.
    public static func hygieneCapMs(_ p75: Double?, _ n: Int64) -> Double {
        let stat: Double = { if let v = p75, n >= 2 { return 2.0 * v }; return 0.0 }()
        return Swift.max(stat, Double(hygieneAbsoluteMs))
    }

    /// Window after a `castBegin` within which a landing emote is attributed to that cast.
    public static let emoteWindowMs: Int64 = 5_000
    /// How many times an emote TEXT must appear adjacent to a cast before it is TRUSTED.
    public static let emoteMinObservations: Int64 = 2

    /// Recency-weighted MAX window: estimate = max over the most recent K samples, applied once per
    /// evidence class.
    public static let recentSampleWindow: Int = 5

    /// The below-floor overrule: when the app may believe its own stopwatch over the spell database.
    /// The two populations separate on the spread of the top three clean cycles; the threshold is
    /// the empty middle at 10%, over three samples.
    public static let belowFloorMinSamples: Int = 3
    public static let belowFloorMaxSpread: Double = 0.1

    /// The relative spread of a set of samples: `(max - min) / min`. A ratio, so one threshold
    /// serves a 44-second mez and a 27-minute invisibility.
    public static func relativeSpread(_ ms: [Int64]) -> Double {
        guard let first = ms.first else { return 0.0 }
        var lo = first
        var hi = first
        for v in ms {
            lo = Swift.min(lo, v)
            hi = Swift.max(hi, v)
        }
        if lo > 0 { return Double(hi - lo) / Double(lo) }
        return Double.infinity
    }

    /// The cluster test: given the CLEAN samples of one recency window, is the largest of them
    /// corroborated well enough to overrule a DB floor? The set tested is the top three by VALUE.
    public static func corroboratedMax(_ cleanWindow: [Int64]) -> Int64? {
        if cleanWindow.count < belowFloorMinSamples { return nil }
        var top = cleanWindow
        top.sort { $0 > $1 }
        top = Array(top.prefix(belowFloorMinSamples))
        return relativeSpread(top) <= belowFloorMaxSpread ? top[0] : nil
    }

    /// The activated AA whose burst of self-buff landing messages is trusted.
    public static let quickBuff = "quick buff"
    /// How long after a Quick Buff activation its burst applies are attributed to it.
    public static let quickBuffWindowMs: Int64 = 5_000

    /// Own-cast landing window: a message-driven apply is attributed to the player only when their
    /// own cast of that spell began within this window before the emote.
    public static let ownCastWindowMs: Int64 = 10_000

    /// The AA that makes self-cast illusion buffs permanent.
    public static let permanentIllusion = "permanent illusion"

    /// The sentinel entity key for a buff on the PLAYER.
    public static let selfKey = "self"
    /// The sentinel caster key for your own cast.
    public static let selfCaster = "self"

    /// Instance-key separator: a NUL, which can never appear in a spell or entity name.
    static let sep: Character = "\0"

    /// The instance key for a (spell, entity) pair — the buff-instance identity.
    public static func instanceKey(_ spellKeyOf: String, _ entityKey: String) -> String {
        spellKeyOf + String(sep) + entityKey
    }

    /// Extract the entity key from an instance key.
    public static func instanceEntityKey(_ iKey: String) -> String {
        guard let i = sepIndex(iKey) else { return selfKey }
        return String(iKey[iKey.utf8.index(after: i)...])
    }

    /// Extract the SPELL LINE key from an instance key — the identity, not the display name. A
    /// family row is named for every candidate and keyed on one of them, so anything asking "which
    /// spell is this row" must ask the KEY and never re-derive it from what the row says.
    public static func instanceSpellKey(_ iKey: String) -> String {
        guard let i = sepIndex(iKey) else { return iKey }
        return String(iKey[..<i])
    }

    /// The separator's position, found over UTF-8 bytes. NUL is a grapheme break on both sides, so
    /// the byte search and `firstIndex(of: sep)` land on the same index; the byte search is what
    /// the hygiene sweep can afford once per active row per event.
    private static func sepIndex(_ iKey: String) -> String.Index? {
        iKey.utf8.firstIndex(of: 0)
    }

    /// The canonical spell key: case-stable and RANK-STRIPPED, with a case-sensitive rank tail.
    public static func spellKey(_ s: String) -> String { Names.spellCanonKey(s) }

    /// The learner's key: one rank-stripped spell line, one caster.
    public static func learnKey(_ lineKey: String, _ caster: String) -> String { lineKey + "|" + caster }

    /// A caster name folded to its comparison key.
    public static func casterKey(_ name: String) -> String { JS.trim(name).lowercased() }

    /// Trusted against the DEFAULT allowlist, which is empty — you and nobody else.
    public static func casterTrusted(_ caster: String) -> Bool {
        let key = casterKey(caster)
        return key == selfCaster || key == "you"
    }

    /// Percentile over an ascending slice, with linear interpolation between neighbours.
    public static func percentile(_ sortedAsc: [Int64], _ p: Double) -> Double {
        if sortedAsc.isEmpty { return 0.0 }
        if sortedAsc.count == 1 { return Double(sortedAsc[0]) }
        let idx = Double(sortedAsc.count - 1) * p
        let lo = Int(idx.rounded(.down))
        let hi = Int(idx.rounded(.up))
        if lo == hi { return Double(sortedAsc[lo]) }
        let frac = idx - Double(lo)
        return Double(sortedAsc[lo]) * (1.0 - frac) + Double(sortedAsc[hi]) * frac
    }

    /// Codepoint order over two strings — Rust's natural `&str` `Ord`, which is UTF-8 bytewise and
    /// therefore exactly codepoint order. Never `localeCompare`.
    public static func codepointLess(_ a: String, _ b: String) -> Bool {
        var i = a.unicodeScalars.makeIterator()
        var j = b.unicodeScalars.makeIterator()
        while true {
            switch (i.next(), j.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?):
                if x.value != y.value { return x.value < y.value }
            }
        }
    }
}
