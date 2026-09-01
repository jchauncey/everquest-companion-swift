// Attack-round structure: the pure grouper behind the Rounds panel (fold/src/combat/rounds.rs).
//
// COUNTS ONLY. Nothing here stores or returns a damage amount as a stat, so every damage total in
// the engine stays byte-identical. Amounts are read for the fan-out signature and discarded.
//
// EQ annotates riposte, flurry and rampage swings and says nothing at all about double or triple
// attack, so a round is a proxy, and the honest one is: the swings ONE attacker made with ONE verb,
// at ONE target, in ONE second.
//
// The per-target part is load-bearing, not a refinement. Reuse-timer skills make some same-second
// swing counts mechanically impossible, and the log's such seconds are always two defenders carrying
// the SAME ordered damage sequence — one round FANNED across two targets and printed twice.
// Collapsing equal sequences reports the one round. The signature is over AMOUNTS and never over
// modifiers, because a `(Critical)` can appear on only one of the two printed copies.
//
// A round answers "how many swings did one attack get me", so families that are EXTRA swings by
// definition are tallied separately and never entered into one: riposte, flurry, rampage, and frenzy.
//
// What this cannot say (law 6): dual wield puts two weapons on ONE verb, so a same-second 2x on
// `slash` may be two hands rather than a double attack and no line distinguishes them. Reuse-timer
// skills have no such confound — one timer, one hand — and that split is `roundConfidence`.
import Foundation
import EQCompanionCore

/// Rust's `i64::div_euclid`, which Swift's `/` (truncating toward zero) is not for negatives.
func roundsDivEuclid(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    if a % b < 0 { return b > 0 ? q - 1 : q + 1 }
    return q
}

/// How many swing buckets a lane reports: 1, 2, 3, and a 4+ tail.
public let ROUND_BUCKETS = 4

/// Why a swing was kept out of round counting — reported so the denominator is never silent. The
/// slot IS the serialized field order, which is the order `excluded` is written in.
public enum RoundExclusion: Int, Sendable {
    case frenzy = 0
    case riposte = 1
    case flurry = 2
    case rampage = 3

    var slot: Int { rawValue }
}

/// Verbs driven by a REUSE TIMER rather than by a weapon in a hand — one timer, one hand, so no
/// dual-wield confound. Hand-authored and evidence-verified: a matcher would happily promote a
/// weapon verb into the confident tier. Everything not listed is a weapon verb.
private let REUSE_TIMER_VERBS = ["backstab", "bash", "kick", "strike"]

/// The confidence tier for a verb's multi-swing reading.
public func roundConfidence(_ verb: String) -> String {
    REUSE_TIMER_VERBS.contains(verb.lowercased()) ? "perEvent" : "aggregate"
}

/// Verbs that never enter round counting: multi-hit by design. `flurry` is here as a VERB as well as
/// a modifier — `You flurry …` is its own melee verb and marks the same extra swing.
private func excludedVerb(_ verbLower: String) -> RoundExclusion? {
    switch verbLower {
    case "frenzy": return .frenzy
    case "flurry": return .flurry
    default: return nil
    }
}

/// Base modifiers that mark a swing as an EXTRA swing rather than part of an attack round. Keyed
/// lowercase; the parser has already decomposed every compound form before anything here sees it.
private func extraSwingMod(_ mLower: String) -> RoundExclusion? {
    switch mLower {
    case "riposte": return .riposte
    case "flurry": return .flurry
    case "rampage": return .rampage
    default: return nil
    }
}

/// Why a swing is not part of an attack round, or `nil` when it is one.
///
/// `verbLower` is the caller's already-lowercased verb: `RoundAccum.add` needs the same string a
/// statement later, and lowercasing twice per swing is a measurable cost on a full-log fold.
public func roundExclusion(_ verbLower: String, _ modifiers: [String]) -> RoundExclusion? {
    if let why = excludedVerb(verbLower) { return why }
    for m in modifiers {
        if let why = extraSwingMod(m.lowercased()) { return why }
    }
    return nil
}

/// One logged swing ATTEMPT, reduced to what round structure needs. Landed and avoided swings both
/// arrive here: a round is swings attempted, and a double attack whose second swing missed is still
/// a double attack.
public struct SwingRecord {
    public var ts: Int64
    /// Un-conjugated melee verb (`slash`, `backstab`) — the round identity.
    public var verb: String
    /// Display lane name (special-attack renamed); labels the row only.
    public var skill: String
    /// The defender, as the line named it. Case-folded by the accumulator (law 2).
    public var target: String
    /// Landed amount, or 0 for an avoided swing. Used only for the fan-out signature.
    public var amount: Int64
    public var avoided: Bool
    public var modifiers: [String]

    public init(ts: Int64, verb: String, skill: String, target: String, amount: Int64,
                avoided: Bool, modifiers: [String]) {
        self.ts = ts; self.verb = verb; self.skill = skill; self.target = target
        self.amount = amount; self.avoided = avoided; self.modifiers = modifiers
    }
}

/// The bucket index (0-based) for a round of `swings` swings; the last bucket is 4+.
private func roundBucket(_ swings: Int) -> Int {
    min(max(swings, 1), ROUND_BUCKETS) - 1
}

/// The finalized per-verb round counters for one source.
public struct RoundLaneTally {
    public var verb: String
    /// Display label — the special-attack lane name when the log named one, else the verb.
    public var skill: String
    /// `buckets[i]` = rounds with exactly `i + 1` swings; the last bucket is 4-or-more.
    public var buckets: [Int64]
    public var rounds: Int64
    public var multiRounds: Int64
    /// Rounds printed against more than one defender (a collapsed fan-out).
    public var fannedRounds: Int64
}

private func newLane(_ verb: String, _ skill: String) -> RoundLaneTally {
    RoundLaneTally(verb: verb, skill: skill,
                   buckets: [Int64](repeating: 0, count: ROUND_BUCKETS),
                   rounds: 0, multiRounds: 0, fannedRounds: 0)
}

/// A per-target swing sequence being assembled for one (verb, second).
///
/// `seq` holds numbers: a landed swing contributes its amount, an avoided one contributes -1.
/// Amounts reaching a round are always > 0, so -1 can never collide with one.
private struct PendingLane {
    var verb: String
    var skill: String
    var seq: [Int64]
}

/// One (verb, second) round after the per-target lanes were collapsed.
private struct CollapsedRound {
    var verb: String
    var skill: String
    var swings: Int
    var targets: Int64
}

/// One swing's contribution to a fan-out signature: its amount, or -1 when it was avoided.
private func signatureToken(_ amount: Int64, _ avoided: Bool) -> Int64 { avoided ? -1 : amount }

/// Collapse per-target lanes whose ordered signature is identical into ONE round, carrying the
/// number of defenders it was printed against. Order-stable: the first lane with a signature keeps
/// its position, later duplicates only bump `targets`.
///
/// The signature is keyed by VERB, and has to be: one second's worth of every verb is open at once,
/// so a signature-only key would fuse an equal-damage backstab and slash into one "fanned" round.
private func collapseFanOut(_ lanes: [PendingLane]) -> [CollapsedRound] {
    var bySig = JSMap<Int>()
    var out: [CollapsedRound] = []
    for lane in lanes {
        let sig = "\(lane.verb)|\(lane.seq.map(String.init).joined(separator: ","))"
        if let idx = bySig[sig] {
            out[idx].targets += 1
            continue
        }
        bySig.insert(sig, out.count)
        out.append(CollapsedRound(verb: lane.verb, skill: lane.skill,
                                  swings: lane.seq.count, targets: 1))
    }
    return out
}

/// Fold ONE collapsed round into a lane tally (shared by `flush` and the pure snapshot).
private func countInto(_ into: inout JSMap<RoundLaneTally>, _ g: CollapsedRound) {
    var lane = into[g.verb] ?? newLane(g.verb, g.skill)
    lane.skill = g.skill
    lane.buckets[roundBucket(g.swings)] += 1
    lane.rounds += 1
    if g.swings >= 2 { lane.multiRounds += 1 }
    if g.targets > 1 { lane.fannedRounds += 1 }
    into.insert(g.verb, lane)
}

/// Round counters for one source, folded on ingest and bounded: only the second currently being
/// assembled is held open, so memory is (verbs × targets in one second), not (seconds × targets). A
/// swing whose second differs from the open one flushes the open second into the counters first.
///
/// `snapshot()` is PURE — a view build may not write to an aggregate — so the still-open second is
/// folded into a copy and the accumulator is left exactly as it was.
public struct RoundAccum {
    private var lanes = JSMap<RoundLaneTally>()
    /// The second currently open, or -1 when nothing is pending.
    private var openSecond: Int64 = -1
    /// `verb|target` → the sequence being assembled inside `openSecond`.
    private var pending = JSMap<PendingLane>()
    /// Swings kept out of round counting, by reason — the denominator's honesty.
    public var excluded: [Int64] = [0, 0, 0, 0]

    public init() {}

    /// Fold one logged swing attempt. Excluded swings are tallied, never dropped silently.
    public mutating func add(_ rec: SwingRecord) {
        let verb = rec.verb.lowercased()
        if let why = roundExclusion(verb, rec.modifiers) {
            excluded[why.slot] += 1
            return
        }
        let sec = roundsDivEuclid(rec.ts, 1_000)
        if sec != openSecond {
            flush()
            openSecond = sec
        }
        let key = "\(verb)|\(rec.target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        let token = signatureToken(rec.amount, rec.avoided)
        if var lane = pending[key] {
            lane.skill = rec.skill
            lane.seq.append(token)
            pending.insert(key, lane)
        } else {
            pending.insert(key, PendingLane(verb: verb, skill: rec.skill, seq: [token]))
        }
    }

    /// Close the open second into the counters. Idempotent on an empty pending map.
    ///
    /// The one-lane fast path is the common case, not an edge: one attacker, one verb, one defender
    /// in one second is what a log is overwhelmingly made of, and one lane cannot be a fan-out.
    private mutating func flush() {
        let n = pending.count
        if n == 0 { return }
        let groups: [CollapsedRound] = n == 1
            ? pending.values.map { CollapsedRound(verb: $0.verb, skill: $0.skill, swings: $0.seq.count, targets: 1) }
            : collapseFanOut(pending.values)
        for g in groups { countInto(&lanes, g) }
        pending.clear()
    }

    /// The lanes as they stand, including the still-open second, without touching the accumulator.
    /// A snapshot can be taken any number of times, mid-fight, with byte-identical results.
    public func snapshot() -> [RoundLaneTally] {
        if pending.isEmpty { return lanes.values }
        var copy = JSMap<RoundLaneTally>()
        for (k, v) in lanes.pairs { copy.insert(k, v) }
        for g in collapseFanOut(pending.values) { countInto(&copy, g) }
        return copy.values
    }

    /// True when nothing has ever been folded (no lanes, no pending). `excluded` is deliberately not
    /// consulted: an excluded swing is not a round.
    public var isEmpty: Bool { lanes.isEmpty && pending.isEmpty }
}

/// Rust's `slice::sort_by` is STABLE and Swift's `sort` is not; several ranked lists in the view
/// builders rely on equal keys keeping the order the aggregate recorded them in.
func stableSorted<T>(_ a: [T], _ less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { x, y in
        if less(x.element, y.element) { return true }
        if less(y.element, x.element) { return false }
        return x.offset < y.offset
    }.map(\.element)
}

// MARK: - Checkpoint

extension RoundLaneTally {
    func checkpointState() -> JSONValue {
        ["verb": .string(verb), "skill": .string(skill),
         "buckets": .array(buckets.map { .int($0) }),
         "rounds": .int(rounds), "multiRounds": .int(multiRounds), "fannedRounds": .int(fannedRounds)]
    }

    static func fromCheckpoint(_ v: JSONValue) -> RoundLaneTally? {
        guard let verb = v["verb"].string, let skill = v["skill"].string,
              let bucketRows = v["buckets"].array, bucketRows.count == ROUND_BUCKETS,
              let rounds = v["rounds"].int64, let multiRounds = v["multiRounds"].int64,
              let fannedRounds = v["fannedRounds"].int64 else { return nil }
        var buckets: [Int64] = []
        for b in bucketRows {
            guard let n = b.int64 else { return nil }
            buckets.append(n)
        }
        return RoundLaneTally(verb: verb, skill: skill, buckets: buckets, rounds: rounds,
                              multiRounds: multiRounds, fannedRounds: fannedRounds)
    }
}

extension RoundAccum {
    /// The still-open second travels too — a checkpoint can land between two swings of one round,
    /// and flushing it instead would count a half-round early and split its other half off.
    func checkpointState() -> JSONValue {
        .object([
            "lanes": lanes.checkpoint { $0.checkpointState() },
            "openSecond": .int(openSecond),
            "pending": pending.checkpoint { p in
                .object(["verb": .string(p.verb), "skill": .string(p.skill),
                         "seq": .array(p.seq.map { .int($0) })])
            },
            "excluded": .array(excluded.map { .int($0) }),
        ])
    }

    static func fromCheckpoint(_ v: JSONValue) -> RoundAccum? {
        guard let lanes = JSMap<RoundLaneTally>.fromCheckpoint(v["lanes"], RoundLaneTally.fromCheckpoint),
              let openSecond = v["openSecond"].int64,
              let pending = JSMap<PendingLane>.fromCheckpoint(v["pending"], { p -> PendingLane? in
                  guard let verb = p["verb"].string, let skill = p["skill"].string,
                        let seqRows = p["seq"].array else { return nil }
                  var seq: [Int64] = []
                  for s in seqRows {
                      guard let n = s.int64 else { return nil }
                      seq.append(n)
                  }
                  return PendingLane(verb: verb, skill: skill, seq: seq)
              }),
              let excludedRows = v["excluded"].array, excludedRows.count == 4 else { return nil }
        var excluded: [Int64] = []
        for e in excludedRows {
            guard let n = e.int64 else { return nil }
            excluded.append(n)
        }
        var r = RoundAccum()
        r.lanes = lanes
        r.openSecond = openSecond
        r.pending = pending
        r.excluded = excluded
        return r
    }
}
