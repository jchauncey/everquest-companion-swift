// Port of fold/src/modules/combo/score.rs — scoring. Observations in, slots out. Pure.
//
// What does NOT work, measured, so nobody re-tries it: ranking classes by how often they are named.
// A frequency model against every `/who` anchor in a real log returns the same one class for every
// window, because a player casts some classes' spells constantly and every shared heal props three
// more up. Volume is not truth.
//
// What does work: presence · exclusivity · sustain, over DISTINCT LABELS.
//   exclusive(c)  distinct labels whose candidate set is exactly {c}
//   support(c)    Σ over distinct labels naming c of weight / |candidates|
//   sustain(c)    distinct 1-hour buckets holding any evidence for c
// A hundred Backstab skill-ups count once for "ROG is present"; a second point is earned by a
// DIFFERENT rogue label.
//
// The model says "I don't know" out loud. A resolved slot holds one candidate; a slot the evidence
// can only narrow to {CLR,PAL} holds both — CLR is measured never to be exclusively evidenced —
// and a slot with nothing behind it holds all 16 at confidence 0.
//
// Order is a claim in two places here, so both use insertion-ordered maps: a class's `labels` become
// the published `because` list, and the residual clusters are ranked by a comparator that is NOT
// total, so the map's own order breaks the tie as JS's stable sort over a `Map` does.
import Foundation
import EQLog
import EQCompanionCore

let comboHourMs: Int64 = 3_600_000

/// How many distinct hourly buckets an EXCLUSIVE label must span before it counts as exclusivity.
///
/// `sustain` cannot be the guard against a one-off: it counts buckets holding ANY evidence for the
/// class, and invocations shared across a dozen classes let every class clear it. A class whose only
/// exclusive names each appeared once has not been evidenced, it has been glimpsed.
private let exclusiveBuckets: Int = 2

/// One slot's knowledge. `candidates` is the SET of classes still consistent with the evidence; the
/// slot is RESOLVED only when it holds exactly one. A 3-slot combo where two resolve and one holds
/// {CLR,PAL} is the normal, honest state.
public struct ComboSlot {
    /// 1 = resolved; >1 = ambiguous; 16 = unknown. Sorted and deduped.
    public var candidates: [ClassAbbr]
    public var confidence: Double
    public var provenance: String
    /// Evidence keys that produced this slot, strongest first, capped at 8 (`skill:Frenzy`).
    public var because: [String]

    var json: JSONValue {
        ["candidates": .array(candidates.map { .string($0) }),
         "confidence": .double(confidence),
         "provenance": .string(provenance),
         "because": .array(because.map { .string($0) })]
    }
}

/// A class's standing in one window.
public final class ClassScore {
    public let cls: ClassAbbr
    public var exclusive: Int64 = 0
    /// Distinct hourly buckets holding EXCLUSIVE evidence for this class — how far across the window
    /// the class's unambiguous evidence reaches, rather than how many names it went by.
    public var spread: Int = 0
    public var support: Double = 0
    public var sustain: Int = 0
    /// The distinct labels naming it — the slot's `because`.
    public var labels: [String] = []

    init(cls: ClassAbbr) { self.cls = cls }
}

/// A distinct label, folded across every occurrence of it in the window.
final class LabelFold {
    var display: String
    var candidates: [ClassAbbr]
    var weight: Double
    var buckets: Set<Int64>

    init(display: String, candidates: [ClassAbbr], weight: Double, buckets: Set<Int64>) {
        self.display = display
        self.candidates = candidates
        self.weight = weight
        self.buckets = buckets
    }
}

/// Fold observations into DISTINCT labels. `source:label` is the key — a stance and a spell may share
/// a word, and they are not the same evidence.
func foldLabels(_ observations: [ClassObservation]) -> [LabelFold] {
    var byKey: JSMap<LabelFold> = JSMap()
    for o in observations {
        if o.source == "who" { continue } // /who OVERRIDES, it never scores (§ 4.4)
        let key = "\(o.source):\(o.label)"
        if let seen = byKey[key] {
            seen.buckets.insert(Rust.divEuclid(o.ts, comboHourMs))
            continue
        }
        let display = "\(o.source == "skillUp" ? "skill" : o.source):\(o.label)"
        byKey.insert(key, LabelFold(display: display, candidates: o.candidates, weight: o.weight,
                                    buckets: [Rust.divEuclid(o.ts, comboHourMs)]))
    }
    return byKey.values
}

/// Per-class exclusivity / spread / support / sustain over a window's observations.
public func scoreClasses(_ observations: [ClassObservation]) -> JSMap<ClassScore> {
    var scores: JSMap<ClassScore> = JSMap()
    var buckets: [ClassAbbr: Set<Int64>] = [:]
    var exclusiveBucketsBy: [ClassAbbr: Set<Int64>] = [:]
    for fold in foldLabels(observations) {
        let exclusive = fold.candidates.count == 1
        for cls in fold.candidates {
            if !scores.containsKey(cls) { scores.insert(cls, ClassScore(cls: cls)) }
            let s = scores[cls]!
            if exclusive && fold.buckets.count >= exclusiveBuckets { s.exclusive += 1 }
            s.support += fold.weight / Double(fold.candidates.count)
            s.labels.append(fold.display)
            buckets[cls, default: []].formUnion(fold.buckets)
            // Spread counts every hour an unambiguous label put this class in the window, whether or
            // not that label cleared the two-bucket bar on its own.
            if exclusive { exclusiveBucketsBy[cls, default: []].formUnion(fold.buckets) }
        }
    }
    for s in scores.values {
        s.sustain = buckets[s.cls]?.count ?? 0
        s.spread = exclusiveBucketsBy[s.cls]?.count ?? 0
    }
    return scores
}

/// Admission ranking: SPREAD first, exclusive-label count as the tie-break, then support.
/// Deterministic (code last).
///
/// Spread rather than label count, because `exclusive` counts distinct NAMES — a property of the
/// class's spellbook, not of how long it was in the loadout.
func byStrength(_ a: ClassScore, _ b: ClassScore) -> Bool {
    if a.spread != b.spread { return a.spread > b.spread }
    if a.exclusive != b.exclusive { return a.exclusive > b.exclusive }
    if a.support != b.support { return a.support > b.support }
    // The codes are three ASCII uppercase letters, and this last key is what makes the comparator
    // TOTAL.
    return a.cls < b.cls
}

/// The classes ADMITTED to the combo: at least one exclusive label AND evidence in at least two
/// hourly buckets, strongest first, capped at `expectedSlots`.
public func admitted(_ scores: JSMap<ClassScore>, _ expectedSlots: Int) -> [ClassScore] {
    var out = scores.values.filter { $0.exclusive >= 1 && $0.sustain >= 2 }
    out = Rust.stableSorted(out, byStrength)
    if out.count > expectedSlots { out.removeSubrange(expectedSlots...) }
    return out
}

/// § 4.3's ladder, for a slot resolved by inference.
private func resolvedConfidence(_ s: ClassScore) -> Double {
    if s.exclusive >= 2 { return 0.9 }
    return s.sustain >= 3 ? 0.75 : 0.5
}

/// An AMBIGUOUS cluster: labels that name none of the admitted classes, intersected.
final class Cluster {
    var candidates: [ClassAbbr]
    var support: Double
    var labels: [String]

    init(candidates: [ClassAbbr], support: Double, labels: [String]) {
        self.candidates = candidates
        self.support = support
        self.labels = labels
    }
}

/// `g.candidates.every((c) => group.candidates.includes(c))` — the earlier (stronger) group's set is
/// contained in this one's.
private func keepOrNot(_ stronger: Cluster, _ group: Cluster) -> Bool {
    stronger.candidates.allSatisfy { group.candidates.contains($0) }
}

/// Residual clustering (§ 4.3 step 2). Labels already explained by an admitted class are dropped.
/// What is left is grouped by EXACT candidate set and ranked by total support.
///
/// Deliberate deviation from the design, which said to intersect overlapping clusters greedily.
/// Intersection can exclude the truth, because two shared labels need not describe the SAME slot.
/// Grouping by exact set can never remove a candidate some single piece of evidence did not already
/// remove. The one safe fold is kept: a broader group whose set CONTAINS a stronger group's is
/// consistent with it and lends it support.
func clusterResidual(_ folds: [LabelFold], _ admittedSet: Set<ClassAbbr>) -> [Cluster] {
    var groups: JSMap<Cluster> = JSMap()
    // A residual exclusive label is a class that FAILED admission — one stray cast in one hour. It
    // gets no slot and no group: seeding one would resolve, through the back door, exactly the class
    // the admission rule just refused.
    for fold in folds {
        if fold.candidates.count < 2 || fold.candidates.contains(where: { admittedSet.contains($0) }) { continue }
        let key = fold.candidates.joined(separator: "|")
        let share = fold.weight / Double(fold.candidates.count)
        if let group = groups[key] {
            group.support += share
            group.labels.append(fold.display)
            continue
        }
        groups.insert(key, Cluster(candidates: fold.candidates, support: share, labels: [fold.display]))
    }
    // Not a total order, and both JS's sort and `sort_by` are stable, so ties keep insertion order.
    let ranked = Rust.stableSorted(groups.values) { $0.support > $1.support }
    // An index walk, because the TS closure reads and writes the same array it is filtering.
    var keep = [Bool](repeating: true, count: ranked.count)
    for i in 0..<ranked.count {
        guard let j = (0..<i).first(where: { keepOrNot(ranked[$0], ranked[i]) }) else { continue }
        keep[i] = false
        let support = ranked[i].support
        let labels = ranked[i].labels
        ranked[i].labels = []
        ranked[j].support += support
        ranked[j].labels.append(contentsOf: labels)
    }
    return zip(ranked, keep).filter(\.1).map(\.0)
}

/// An explicit UNKNOWN slot: all 16 candidates, zero confidence, no story. Never a guess.
public func unknownSlot() -> ComboSlot {
    ComboSlot(candidates: classAbbrs, confidence: 0.0, provenance: "inferred", because: [])
}

/// A slot the log (or the user) STATED: resolved, confidence 1.0, no inference involved.
public func statedSlots(_ classes: [ClassAbbr], _ provenance: String) -> [ComboSlot] {
    classes.map { ComboSlot(candidates: [$0], confidence: 1.0, provenance: provenance, because: [provenance]) }
}

/// Observations → slots (§ 4.2-4.3). Always returns exactly `expectedSlots` entries: admitted classes
/// first, then ambiguous clusters, then explicit unknowns. Shorter is never returned — "we found two
/// of three" is a statement the UI has to be able to make.
public func scoreSlots(_ observations: [ClassObservation], _ expectedSlots: Int) -> [ComboSlot] {
    let scores = scoreClasses(observations)
    let admit = admitted(scores, expectedSlots)
    var slots: [ComboSlot] = admit.map { s in
        ComboSlot(candidates: [s.cls], confidence: resolvedConfidence(s), provenance: "inferred",
                  because: Array(s.labels.prefix(8)))
    }
    let admittedSet = Set(admit.map(\.cls))
    for cluster in clusterResidual(foldLabels(observations), admittedSet) {
        if slots.count >= expectedSlots { break }
        if cluster.candidates.isEmpty { continue }
        let candidates = cluster.candidates.sorted()
        slots.append(ComboSlot(
            candidates: candidates,
            // "we know the SET, not the member" — a two-way ambiguity is worth 0.3, not 0.6.
            confidence: 0.6 / Double(max(cluster.labels.count, 1)),
            provenance: "inferred",
            because: Array(cluster.labels.prefix(8))))
    }
    while slots.count < expectedSlots { slots.append(unknownSlot()) }
    if slots.count > expectedSlots { slots.removeSubrange(expectedSlots...) }
    return slots
}
