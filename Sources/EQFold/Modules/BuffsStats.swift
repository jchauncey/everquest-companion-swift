// The one observed-duration learner, and the per-line game knowledge beside it: the mined duration
// samples, the recency map, and the spell catalog.
//
// This is GAME knowledge, not character state, so the module's rebirth and session-gap clears leave
// it intact.
//
// Keyed on (LINE, CASTER): the LINE is rank-stripped, so `Mesmerization III` and `Mesmerization VII`
// pool; the CASTER is 'self' or an allowlisted external, because a duration is a fact about a
// caster's AAs, focus items and rank.
//
// The estimator is `max(DB baseline, max over the recent window of observed samples)`. The DB base
// is a FLOOR and the observed max is an EXTENSION over it. The floor can lose exactly one way: a
// below-floor observation may overrule it when the log CORROBORATES it, and the source then reads
// `cluster`.
//
// A third kind of evidence covers the case where no cycle can ever be witnessed: a debuffed mob's
// DEATH with no wear-off since the landing is a LOWER BOUND. It folds into the max like any other
// sample and reports `deathBound` when it wins, and it is refused the cluster rule and the n/median
// columns, because it is not a CYCLE.
//
// The window is applied ONCE PER EVIDENCE CLASS: the most recent five uncensored samples are one
// window and the most recent five lower bounds are a second, with the observed candidate the max
// over both.
// (fold/src/modules/buffs_stats.rs)
import Foundation
import EQLog
import EQCompanionCore

/// The winning candidate of the estimator's window: the longest span, and whether it is a bound.
public struct WindowMax {
    public var ms: Int64
    public var bound: Bool
}

/// Fold one sample into the running window max. A tie goes to the MEASURED cycle: the bound adds
/// nothing to an observation that agrees with it, and must not weaken the label the log earned.
private func foldWindowMax(_ best: WindowMax?, _ s: DurationSample) -> WindowMax {
    let bound = s.deathBound
    guard let b = best else { return WindowMax(ms: s.ms, bound: bound) }
    if s.ms > b.ms { return WindowMax(ms: s.ms, bound: bound) }
    if s.ms == b.ms && !bound { return WindowMax(ms: b.ms, bound: false) }
    return b
}

/// Which spelling of a line the Buffs tab shows — the rank question, answered once.
///
/// Highest rank wins. Last-write-wins is refused because this store POOLS ACROSS CHARACTERS. A tie
/// keeps the existing spelling. A DIFFERENT BASE is not a rank comparison at all, so the newest name
/// simply wins.
public func preferredDisplayName(_ prev: String, _ next: String) -> String {
    let candidate = JS.trim(next)
    if candidate.isEmpty || candidate == JS.trim(prev) { return prev }
    let before = JSFn.parseSpellRank(prev)
    let after = JSFn.parseSpellRank(candidate)
    if before.base.lowercased() != after.base.lowercased() { return candidate }
    return after.rank > before.rank ? candidate : prev
}

/// Per-(line, caster) accumulated duration samples + display name.
final class SpellSamples {
    var spell: String
    var samples: [DurationSample] = []
    init(spell: String) { self.spell = spell }
}

/// The snapshot's per-line stats record.
public struct BuffStat {
    public var spell: String
    public var cls: BuffClass
    public var n: Int64
    public var medianMs: Double?
    public var p25: Double?
    public var p75: Double?
    public var minMs: Int64?
    public var maxMs: Int64?
    public var dbDurationMs: Int64?
    public var estimateMs: Int64?
    public var estimatorSource: EstimatorSource?
    public var lastSeenMs: Int64?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "spell": .string(spell),
            "cls": .string(cls.rawValue),
            "n": .int(n),
            "medianMs": medianMs.map { .double($0) } ?? .null,
            "p25": p25.map { .double($0) } ?? .null,
            "p75": p75.map { .double($0) } ?? .null,
            "minMs": minMs.map { .int($0) } ?? .null,
            "maxMs": maxMs.map { .int($0) } ?? .null,
            "dbDurationMs": dbDurationMs.map { .int($0) } ?? .null,
            "estimateMs": estimateMs.map { .int($0) } ?? .null,
            "lastSeenMs": lastSeenMs.map { .int($0) } ?? .null,
        ]
        if let s = estimatorSource { o["estimatorSource"] = .string(s.rawValue) }
        return .object(o)
    }
}

/// What the estimator answered.
public struct Estimate {
    public var ms: Int64?
    public var source: EstimatorSource?
}

public final class SpellStats {
    /// The projected spell catalog — the authoritative prior. An EMPTY one means no catalog at all.
    public let db: SpellFacts
    /// Mined samples per (LINE, CASTER). Ranks pool within a caster; casters never pool.
    private var samples = JSMap<SpellSamples>()
    /// Spell keys ever seen fading or applied — the set `buildStats` walks.
    public private(set) var everFaded: [String] = []
    private var everFadedAt = Set<String>()
    /// Spell lines this log has ever printed a TARGET-NAMED wear-off for, learned at runtime and
    /// from nothing else. The death lower bound reads an ABSENCE, and an absence is only evidence
    /// about a spell that prints the line in the first place.
    private var wearOffWitnessed = Set<String>()
    /// Per-spell LAST-SEEN event ts: the newest castBegin / apply / fade involving the spell.
    private var lastSeen = JSMap<Int64>()

    public init(db: SpellFacts) { self.db = db }

    public func reset() {
        samples.clear()
        everFaded.removeAll()
        everFadedAt.removeAll()
        wearOffWitnessed.removeAll()
        lastSeen.clear()
    }

    /// Insertion order is what `buildStats` walks. The object it builds is keyed, so that order is
    /// not published; keeping it stable anyway is what makes a diff between two runs readable.
    public func noteEverFaded(_ key: String) {
        if everFadedAt.insert(key).inserted { everFaded.append(key) }
    }

    public func witnessWearOffChannel(_ key: String) { wearOffWitnessed.insert(key) }

    public func hasWearOffChannel(_ key: String) -> Bool { wearOffWitnessed.contains(key) }

    /// Record the newest ts a spell was seen (cast / apply / fade) — the recency signal.
    public func touchLastSeen(_ key: String, _ ts: Int64) {
        if lastSeen[key].map({ ts > $0 }) ?? true { lastSeen.insert(key, ts) }
    }

    private func rowOf(_ key: String) -> SpellRow? { db.get(key) }

    /// Authoritative DB duration (ms) for a spell key, or nil when unknown.
    public func dbDurationFor(_ key: String) -> Int64? { rowOf(key)?.durationMs }

    /// True when a spell KEY is illusion-flagged in the DB.
    public func isIllusion(_ key: String) -> Bool { rowOf(key)?.illusion ?? false }

    /// Does the spell database say this spell never expires? The discriminator is the duration TEXT
    /// reading `Permanent`, and a null duration alone is not it.
    public func isPermanent(_ key: String) -> Bool { rowOf(key)?.durationText == "Permanent" }

    /// Append a mined duration sample for one caster. The display name is re-read on every sample.
    public func pushSample(_ key: String, _ caster: String, _ spell: String, _ sample: DurationSample) {
        row(key, caster, spell).samples.append(sample)
    }

    /// A landing said what this line is called — the same display-name write as `pushSample`,
    /// without a sample behind it. A row with no samples is a legal row.
    public func noteDisplayName(_ key: String, _ caster: String, _ spell: String) {
        _ = row(key, caster, spell)
    }

    /// The (line, caster) row, minted if new, with its display name brought up to date.
    @discardableResult
    private func row(_ key: String, _ caster: String, _ spell: String) -> SpellSamples {
        let lk = BuffsShapes.learnKey(key, caster)
        if let s = samples[lk] {
            s.spell = preferredDisplayName(s.spell, spell)
            return s
        }
        let s = SpellSamples(spell: spell)
        samples.insert(lk, s)
        return s
    }

    /// Mark the sample closed at `closedTs` CENSORED — the log named something that ended that
    /// cycle early, so its span is a lower bound and not the duration. Retroactive because the log
    /// is: the wake line is printed AFTER the wear-off sentence it explains.
    ///
    /// Returns whether it found one, so the caller knows whether to re-stat.
    @discardableResult
    public func censorSampleAt(_ key: String, _ caster: String, _ closedTs: Int64) -> Bool {
        guard let s = samples[BuffsShapes.learnKey(key, caster)] else { return false }
        // Newest first: a re-used ts can only mean the same second.
        for i in s.samples.indices.reversed() {
            if s.samples[i].ts != closedTs { continue }
            if s.samples[i].censored { return false }
            s.samples[i].censored = true
            return true
        }
        return false
    }

    /// The display name last minted for a (line, caster), for a row that has lost its own.
    public func sampleSpellName(_ key: String, _ caster: String) -> String? {
        samples[BuffsShapes.learnKey(key, caster)]?.spell
    }

    public func statFor(_ key: String, _ caster: String) -> BuffStat? {
        guard let s = samples[BuffsShapes.learnKey(key, caster)] else { return nil }
        if s.samples.isEmpty { return nil }
        // The DISTRIBUTION columns describe every cycle the model measured, censored or not. Only
        // the estimate reads the censoring. A death bound is not counted at all, because `n` is the
        // number of land→fade pairs and a bound has no fade in it.
        var sorted = s.samples.filter { !$0.deathBound }.map(\.ms)
        sorted.sort()
        let n = sorted.count
        let est = estimateFor(key, caster)
        return BuffStat(
            spell: s.spell,
            cls: classOf(key),
            n: Int64(n),
            medianMs: n > 0 ? BuffsShapes.percentile(sorted, 0.5) : nil,
            p25: n > 0 ? BuffsShapes.percentile(sorted, 0.25) : nil,
            p75: n > 0 ? BuffsShapes.percentile(sorted, 0.75) : nil,
            minMs: sorted.first,
            maxMs: sorted.last,
            dbDurationMs: dbDurationFor(key),
            estimateMs: est.ms,
            estimatorSource: est.source,
            lastSeenMs: lastSeen[key])
    }

    /// The observed candidate that competes with the DB floor: the MAX over the most recent window
    /// of samples for this (line, caster), or nil when there are none.
    ///
    /// MAX, not median or p75: samples are dominated by early terminations that read short, and
    /// those never lift the max. A censored sample still counts toward the max: it is a real
    /// observation, just a truncated one, so the span is a LOWER BOUND.
    public func observedWindowMaxFor(_ key: String, _ caster: String) -> WindowMax? {
        guard let s = samples[BuffsShapes.learnKey(key, caster)] else { return nil }
        var best: WindowMax?
        var clean = 0
        var broken = 0
        for sample in s.samples.reversed() {
            if sample.isLowerBound {
                if broken >= BuffsShapes.recentSampleWindow { continue }
                broken += 1
            } else {
                if clean >= BuffsShapes.recentSampleWindow { continue }
                clean += 1
            }
            best = foldWindowMax(best, sample)
            if clean >= BuffsShapes.recentSampleWindow && broken >= BuffsShapes.recentSampleWindow { break }
        }
        return best
    }

    /// The most recent CLEAN samples for this (line, caster), newest first — the same window the max
    /// walks on the uncensored side, handed out as a list because the below-floor overrule asks a
    /// question a max cannot answer: do the observations AGREE?
    public func cleanWindowFor(_ key: String, _ caster: String) -> [Int64] {
        guard let s = samples[BuffsShapes.learnKey(key, caster)] else { return [] }
        var out: [Int64] = []
        for sample in s.samples.reversed() {
            if out.count >= BuffsShapes.recentSampleWindow { break }
            if !sample.isLowerBound { out.append(sample.ms) }
        }
        return out
    }

    /// The one estimator — see this file's header for the rules that compose it.
    ///
    /// The number returned on the below-floor overrule is the WHOLE window's max, not the clean
    /// cluster's, and the comparison is STRICT.
    public func estimateFor(_ key: String, _ caster: String) -> Estimate {
        let dbMs = dbDurationFor(key)
        let observed = observedWindowMaxFor(key, caster)
        let learned: EstimatorSource = (observed?.bound ?? false) ? .deathBound : .observed
        if let db = dbMs {
            if let o = observed {
                if o.ms > db { return Estimate(ms: o.ms, source: learned) }
                if o.ms < db, BuffsShapes.corroboratedMax(cleanWindowFor(key, caster)) != nil {
                    return Estimate(ms: o.ms, source: .cluster)
                }
            }
            return Estimate(ms: db, source: .db)
        }
        if let o = observed { return Estimate(ms: o.ms, source: learned) }
        return Estimate(ms: nil, source: nil)
    }

    /// The buff/debuff class of a spell, from the spell's NATURE and from nothing else. A spell
    /// whose nature nobody states reads `buff`, and it is never resolved by looking at who it
    /// landed on.
    public func classOf(_ key: String) -> BuffClass {
        rowOf(key)?.nature == .detrimental ? .debuff : .buff
    }

    /// Does this spell CALM its target — a second, orthogonal question asked at the same seam.
    public func calmsTarget(_ key: String) -> Bool { rowOf(key)?.calmsTarget ?? false }

    /// The snapshot's per-line stats record: every spell ever faded, with or without samples.
    /// It reports the SELF caster's numbers only.
    public func buildStats() -> JSONValue {
        var stats: [String: JSONValue] = [:]
        for key in everFaded {
            let st: BuffStat
            if let s = statFor(key, BuffsShapes.selfCaster) {
                st = s
            } else {
                let dbMs = dbDurationFor(key)
                st = BuffStat(
                    spell: sampleSpellName(key, BuffsShapes.selfCaster) ?? rowOf(key)?.name ?? key,
                    cls: classOf(key),
                    n: 0,
                    medianMs: nil,
                    p25: nil,
                    p75: nil,
                    minMs: nil,
                    maxMs: nil,
                    dbDurationMs: dbMs,
                    estimateMs: dbMs,
                    estimatorSource: dbMs.map { _ in EstimatorSource.db },
                    lastSeenMs: lastSeen[key])
            }
            stats[key] = st.json
        }
        return .object(stats)
    }

    // MARK: - Checkpoint

    /// The learner in full: every sample with its censoring flags (the estimator reads them), the
    /// `everFaded` list IN ORDER (its order is what keeps two runs' `buildStats` diffable), the
    /// witnessed wear-off channels, and the recency map. `everFadedAt` is not written — it is the
    /// list's own dedupe index and is rebuilt from it. `db` is a constructor dependency.
    func checkpointState() -> JSONValue {
        .object([
            "samples": samples.checkpoint { s in
                .object(["spell": .string(s.spell),
                         "samples": .array(s.samples.map {
                             .object(["ms": .int($0.ms), "ts": .int($0.ts),
                                      "censored": .bool($0.censored), "deathBound": .bool($0.deathBound)])
                         })])
            },
            "everFaded": .array(everFaded.map { .string($0) }),
            "wearOffWitnessed": .array(wearOffWitnessed.sorted().map { .string($0) }),
            "lastSeen": lastSeen.checkpoint { .int($0) },
        ])
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let m = JSMap<SpellSamples>.fromCheckpoint(v["samples"], { row in
            guard let spell = row["spell"].string, let list = row["samples"].array else { return nil }
            let s = SpellSamples(spell: spell)
            s.samples.reserveCapacity(list.count)
            for x in list {
                guard let ms = x["ms"].int64, let ts = x["ts"].int64,
                      let censored = x["censored"].bool, let deathBound = x["deathBound"].bool else { return nil }
                s.samples.append(DurationSample(ms: ms, ts: ts, censored: censored, deathBound: deathBound))
            }
            return s
        }),
        let fadedRows = v["everFaded"].array, let witnessedRows = v["wearOffWitnessed"].array,
        let seen = JSMap<Int64>.fromCheckpoint(v["lastSeen"], { $0.int64 }) else { return false }
        let faded = fadedRows.compactMap(\.string)
        let witnessed = witnessedRows.compactMap(\.string)
        guard faded.count == fadedRows.count, witnessed.count == witnessedRows.count else { return false }
        samples = m
        // Through `noteEverFaded` so the list and its dedupe index cannot disagree; the encoder
        // never writes a duplicate, so the order comes back verbatim.
        for key in faded { noteEverFaded(key) }
        wearOffWitnessed = Set(witnessed)
        lastSeen = seen
        return true
    }
}
