// Port of fold/src/modules/combo/intervals.rs — INTERVAL CONSTRUCTION. Observations + `/who` rows +
// level dings + user corrections in, `ComboInterval[]` out. Pure.
//
// A loadout swap prints nothing, so every boundary here is INFERENCE, always a RANGE
// `[startLo, startHi]` rather than an instant. The detectors are ranked by how much the log said:
//
//   who            two consecutive `/who` rows disagree. The game NAMED both loadouts, so the swap
//                  is somewhere between the rows. Hard, and nothing overrides it.
//   levelDrop      a `Welcome to level N!` with N <= the previous ding. Displayed level is the
//                  MINIMUM of the loadout's class levels, so a non-increasing ding is a swap. Note
//                  `<=`, not `<`: real logs contain a genuine same-level repeat hours apart.
//   evidenceShift  a class with sustained exclusive evidence goes silent and a different one
//                  starts. This is what NARROWS a boundary.
//
// Where two detectors fire for one swap the narrower window wins and the other is recorded in
// `startAlso` — except that a `/who` row never loses to a narrower inferred window, which is the
// explicit precedence in `resolveGroup`.
import Foundation
import EQLog
import EQCompanionCore

/// The tertiary slot unlocks at level 10 — a PRIOR, overridden by a `/who` row's own arity.
private let tertiaryUnlockLevel: Int64 = 10
/// § 4.5 R8: never bisect below this, or an ambiguous span thrashes into confetti.
private let windowFloorMs: Int64 = 15 * 60_000
/// Bound on shift bisection. The real log needs ONE cut; this is the runaway guard.
private let maxShiftCuts: Int = 16

/// A user correction — the only durable combo state (§ 7). Keyed by TIME, never by interval id: a
/// correction recomputes every interval and ids are recompute-unstable by design.
public struct ComboCorrection {
    public var startTs: Int64
    /// `nil` = "from `startTs` onward", i.e. it applies to the open interval too.
    public var endTs: Int64?
    public var classes: [ClassAbbr]
    /// When the user set it — later corrections win over earlier overlapping ones.
    public var setAt: Int64

    public init(startTs: Int64, endTs: Int64?, classes: [ClassAbbr], setAt: Int64) {
        self.startTs = startTs
        self.endTs = endTs
        self.classes = classes
        self.setAt = setAt
    }
}

/// A contiguous span during which we believe the loadout did not change.
public struct ComboInterval {
    /// `ci<n>` in time order. Not stable across a recompute.
    public var id: String
    /// Best estimate of the start; always inside `[startLo, startHi]`.
    public var startTs: Int64
    /// `null` = the open / current interval.
    public var endTs: Int64?
    public var startLo: Int64
    public var startHi: Int64
    public var endLo: Int64?
    public var endHi: Int64?
    /// The detector that produced the narrowest window for this boundary.
    public var startReason: String
    /// Other detectors that fired for the same swap. Absent unless there were any.
    public var startAlso: [String]?
    /// 2 before the tertiary unlock, 3 after — a PRIOR, overridden by a `/who` row's own arity.
    public var expectedSlots: Int
    /// `count == expectedSlots`; unfilled positions are explicit UNKNOWN slots, never dropped.
    public var slots: [ComboSlot]
    /// Level range observed inside the interval (min-of-loadout semantics). `null`, not absent.
    public var levelLo: Int64?
    public var levelHi: Int64?
    /// How much evidence stands behind this interval, for the UI's "do we actually know" cue.
    public var evidenceCount: Int
    /// Set only by a user correction; suppresses re-inference of these slots.
    public var userLocked: Bool
    /// A manual override applies here and the GAME contradicted it. Absent unless it happened.
    public var userOverruled: Bool?
    /// Same serialization rule for the same reason: absent unless the span really did see the level
    /// go backwards.
    public var levelRegressed: Bool?

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id),
            "startTs": .int(startTs),
            "endTs": endTs.map { .int($0) } ?? .null,
            "startLo": .int(startLo),
            "startHi": .int(startHi),
            "endLo": endLo.map { .int($0) } ?? .null,
            "endHi": endHi.map { .int($0) } ?? .null,
            "startReason": .string(startReason),
            "expectedSlots": .int(Int64(expectedSlots)),
            "slots": .array(slots.map(\.json)),
            "levelLo": levelLo.map { .int($0) } ?? .null,
            "levelHi": levelHi.map { .int($0) } ?? .null,
            "evidenceCount": .int(Int64(evidenceCount)),
            "userLocked": .bool(userLocked),
        ]
        if let startAlso { o["startAlso"] = .array(startAlso.map { .string($0) }) }
        if let userOverruled { o["userOverruled"] = .bool(userOverruled) }
        if let levelRegressed { o["levelRegressed"] = .bool(levelRegressed) }
        return .object(o)
    }
}

/// One detected swap: it happened somewhere in `[lo, hi]`; `at` is where we cut.
public struct Boundary {
    public var lo: Int64
    public var hi: Int64
    /// Best estimate — always `hi` from a detector: the new loadout is only PROVEN at the arriving
    /// evidence.
    public var at: Int64
    public var reason: String
    /// Other detectors that fired for the same swap.
    public var also: [String]?

    public init(lo: Int64, hi: Int64, at: Int64, reason: String, also: [String]? = nil) {
        self.lo = lo
        self.hi = hi
        self.at = at
        self.reason = reason
        self.also = also
    }
}

public struct IntervalInput {
    public var observations: [ClassObservation]
    public var whoRows: [WhoRow]
    public var levels: [LevelPoint]
    public var corrections: [ComboCorrection]

    public init(observations: [ClassObservation], whoRows: [WhoRow], levels: [LevelPoint],
                corrections: [ComboCorrection]) {
        self.observations = observations
        self.whoRows = whoRows
        self.levels = levels
        self.corrections = corrections
    }
}

/// Consecutive `/who` rows that disagree, minus the swaps something sharper already dated.
///
/// A `/who` pair only bounds the swap by "somewhere between these two rows", which runs to hours.
/// The disagreement is PROOF that a swap happened, but if an already-detected boundary falls inside
/// `(prev, row]` then that boundary IS this swap, dated better.
///
/// The first row never opens one: with no earlier statement there is nothing to disagree with.
public func whoBoundaries(_ rows: [WhoRow], _ dated: [Boundary]) -> [Boundary] {
    var out: [Boundary] = []
    guard rows.count > 1 else { return out }
    for i in 1..<rows.count {
        let prev = rows[i - 1]
        let row = rows[i]
        if prev.classes == row.classes { continue }
        if dated.contains(where: { $0.at > prev.ts && $0.at <= row.ts }) { continue }
        out.append(Boundary(lo: prev.ts, hi: row.ts, at: row.ts, reason: "who", also: nil))
    }
    return out
}

/// A `/who` row that contradicts the evidence behind it — the swap cut nothing else can see.
///
/// The rule: a `/who` row states the loadout AT ITS OWN TIMESTAMP and nowhere else. When the
/// evidence in front of it inside its own segment sustains a class the row does not name, the game
/// and the log disagree about one span, which can only mean a swap happened between them.
///
/// Departure alone is enough here, where `reinstatedDrops` demands departure AND arrival: that rule
/// compares evidence to evidence across a ding. This one compares evidence to a STATEMENT.
public func whoShiftBoundaries(_ observations: [ClassObservation], _ rows: [WhoRow],
                               _ dated: [Boundary], _ firstTs: Int64) -> [Boundary] {
    var out: [Boundary] = []
    // A row is a statement, never a score (§ 4.4): a single-class row would otherwise draw an
    // exclusive span for itself.
    let evidence = observations.filter { $0.source != "who" }
    for row in rows {
        let placedAts = dated.map(\.at) + out.map(\.at)
        if placedAts.contains(row.ts) { continue }
        let before = placedAts.filter { $0 <= row.ts }
        let from = before.max() ?? firstTs
        if row.ts <= from { continue }
        let window = evidence.filter { $0.ts >= from && $0.ts < row.ts }
        let departed = exclusiveSpans(window).filter { !row.classes.contains($0.cls) }
        if departed.isEmpty { continue }
        // The window opens no earlier than the last word of a class that is gone, and closes at the
        // row, which is where the game spoke.
        let lo = departed.reduce(from) { max($0, $1.last) }
        out.append(Boundary(lo: lo, hi: row.ts, at: row.ts, reason: "who", also: nil))
    }
    return out
}

/// A non-increasing level ding. The window is honestly wide — tens of hours — and the UI is expected
/// to draw it as a range.
public func levelDropBoundaries(_ levels: [LevelPoint]) -> [Boundary] {
    var out: [Boundary] = []
    guard levels.count > 1 else { return out }
    for i in 1..<levels.count {
        let prev = levels[i - 1]
        let ding = levels[i]
        if ding.level > prev.level { continue }
        out.append(Boundary(lo: prev.ts, hi: ding.ts, at: ding.ts, reason: "levelDrop", also: nil))
    }
    return out
}

/// A class's exclusive-evidence span, for classes the window actually stands behind.
struct Span {
    var cls: ClassAbbr
    var first: Int64
    var last: Int64
}

/// Classes carrying SUSTAINED EXCLUSIVE evidence — ≥2 distinct hourly buckets of observations that
/// name that class and nothing else.
///
/// A stricter bar than admission on purpose. Admission's `sustain` counts every bucket holding ANY
/// evidence for the class, which is the right question for "is this class in the loadout" and the
/// wrong one for "when was this class present", where a shared invocation would smear a class across
/// the whole log and manufacture boundaries.
///
/// Insertion-ordered, because `cutOnce`'s two reductions keep the FIRST element on a tie.
func exclusiveSpans(_ observations: [ClassObservation]) -> [Span] {
    final class Acc {
        var span: Span
        var buckets: Set<Int64>
        init(span: Span, buckets: Set<Int64>) { self.span = span; self.buckets = buckets }
    }
    var spans: JSMap<Acc> = JSMap()
    for o in observations {
        if o.candidates.count != 1 { continue }
        let cls = o.candidates[0]
        let bucket = Rust.divEuclid(o.ts, comboHourMs)
        if let acc = spans[cls] {
            acc.span.first = min(acc.span.first, o.ts)
            acc.span.last = max(acc.span.last, o.ts)
            acc.buckets.insert(bucket)
            continue
        }
        spans.insert(cls, Acc(span: Span(cls: cls, first: o.ts, last: o.ts), buckets: [bucket]))
    }
    return spans.values.filter { $0.buckets.count >= 2 }.map(\.span)
}

/// One cut inside a window, or `nil`.
///
/// The window is over-determined when more classes carry sustained exclusive evidence than a loadout
/// can hold. The swap is then bounded below by the EARLIEST departure and above by the EARLIEST
/// arrival after it.
func cutOnce(_ observations: [ClassObservation], _ expectedSlots: Int) -> Boundary? {
    let spans = exclusiveSpans(observations)
    if spans.count <= expectedSlots { return nil }
    // `reduce((a, b) => b.last < a.last ? b : a)` — a STRICT `<`, so the first minimum wins.
    guard var departing = spans.first else { return nil }
    for b in spans.dropFirst() where b.last < departing.last { departing = b }
    let arrivals = spans.filter { $0.first > departing.last }
    guard var arriving = arrivals.first else { return nil }
    for b in arrivals.dropFirst() where b.first < arriving.first { arriving = b }
    if arriving.first - departing.last < 0 { return nil }
    return Boundary(lo: departing.last, hi: arriving.first, at: arriving.first,
                    reason: "evidenceShift", also: nil)
}

/// Evidence-shift boundaries inside one hard segment, found by bisecting until every sub-window
/// holds at most `expectedSlots` sustained classes. On hitting the window floor while still
/// over-determined it does NOT split — an honest "we can't tell" beats a fabricated boundary.
public func evidenceShiftBoundaries(_ observations: [ClassObservation], _ expectedSlots: Int) -> [Boundary] {
    var out: [Boundary] = []
    var queue: [[ClassObservation]] = [observations]
    var head = 0
    while head < queue.count && out.count < maxShiftCuts {
        let window = queue[head]
        head += 1
        if window.isEmpty { continue }
        let span = window[window.count - 1].ts - window[0].ts
        if span < windowFloorMs { continue }
        guard let cut = cutOnce(window, expectedSlots) else { continue }
        let (lo, hi) = (cut.lo, cut.hi)
        out.append(cut)
        queue.append(window.filter { $0.ts <= lo })
        queue.append(window.filter { $0.ts >= hi })
    }
    return Rust.stableSorted(out) { $0.at < $1.at }
}

/// Windows that OVERLAP describe the same swap, and the narrowest of them is the answer — so an
/// evidence shift beats the level ding whose window swallowed it, and the ding is recorded in `also`
/// rather than thrown away.
///
/// The cut itself is the EARLIEST `at` any detector in the group offers, clamped into the winning
/// window.
func pickBoundary(_ group: [Boundary]) -> Boundary {
    // `reduce((a, b) => b.hi - b.lo < a.hi - a.lo ? b : a)` — first narrowest wins.
    var best = 0
    guard !group.isEmpty else { return Boundary(lo: 0, hi: 0, at: 0, reason: "logStart", also: nil) }
    for i in 1..<group.count where group[i].hi - group[i].lo < group[best].hi - group[best].lo {
        best = i
    }
    let earliest = group.map(\.at).min() ?? group[best].at
    let at = min(max(earliest, group[best].lo), group[best].hi)
    // `best.also` carries through; the overwrite below happens only if the group held anything else.
    var merged = group[best]
    merged.at = at
    var also: [String] = []
    for (i, b) in group.enumerated() where i != best && !also.contains(b.reason) { also.append(b.reason) }
    if !also.isEmpty { merged.also = also }
    return merged
}

/// The window an absorbed drop is judged against: from the boundary that swallowed it to the next
/// cut after it (or the end of the evidence).
func absorbedWindow(_ drop: Boundary, _ dated: [Boundary], _ end: Int64) -> (Int64, Int64)? {
    guard let from = dated.filter({ $0.at <= drop.at }).map(\.at).max() else { return nil }
    let to = dated.filter { $0.at > drop.at }.map(\.at).min() ?? end
    return (from, to)
}

/// Level dings the merge swallowed, put back when the evidence says they were a second swap.
///
/// The discriminator is the evidence, never the clock, and it is the test an evidence shift already
/// has to pass: a class with sustained exclusive evidence goes SILENT and a different one STARTS.
/// Requiring both directions keeps it conservative.
///
/// The second arm needs no clock constant either: the honest disqualifier is that the stretch
/// between them is an era in its own right.
public func reinstatedDrops(_ observations: [ClassObservation], _ drops: [Boundary],
                            _ dated: [Boundary], _ expectedSlots: Int) -> [Boundary] {
    if observations.isEmpty { return [] }
    let end = observations[observations.count - 1].ts + 1
    var out: [Boundary] = []
    func pick(_ from: Int64, _ to: Int64) -> [ClassObservation] {
        observations.filter { $0.ts >= from && $0.ts < to }
    }
    for drop in drops {
        if dated.contains(where: { $0.at == drop.at }) { continue }
        guard let (from, to) = absorbedWindow(drop, dated, end) else { continue }
        let was = exclusiveSpans(pick(from, drop.at))
        let now = exclusiveSpans(pick(drop.at, to))
        let departed = was.filter { s in !now.contains { $0.cls == s.cls } }
        let arrived = now.contains { n in !was.contains { $0.cls == n.cls } }
        let swapped = !departed.isEmpty && arrived
        // The absorbed stretch is a loadout era of its own, inside a span the model cannot explain.
        let ownEra = was.count >= expectedSlots
        let overDetermined = exclusiveSpans(pick(from, to)).count > expectedSlots
        if !swapped && !(ownEra && overDetermined) { continue }
        // The ding is the cut (the log spoke there); the window opens no earlier than the last
        // evidence of a class that is gone.
        let lo = departed.reduce(from) { max($0, $1.last) }
        out.append(Boundary(lo: lo, hi: drop.at, at: drop.at, reason: "levelDrop",
                            also: ["evidenceShift"]))
    }
    return out
}

/// One group of overlapping windows, resolved — and a `/who` cut is never what gets resolved away.
///
/// A `/who` row is ground truth AT ITS TIMESTAMP. Two rows are two statements, never one event, and
/// no window drawn by inference may move, merge or delete the cut a row makes.
func resolveGroup(_ group: [Boundary]) -> [Boundary] {
    if !group.contains(where: { $0.reason == "who" }) { return [pickBoundary(group)] }
    // Rows landing on the same instant are one statement and keep the narrowest window between them.
    var byInstant: JSMap<[Boundary]> = JSMap()
    for b in group where b.reason == "who" {
        let key = String(b.at)
        if var list = byInstant[key] {
            list.append(b)
            byInstant.insert(key, list)
        } else {
            byInstant.insert(key, [b])
        }
    }
    var kept: [Boundary] = byInstant.values.map { pickBoundary($0) }
    var undated: [Boundary] = []
    for b in group {
        if b.reason == "who" { continue }
        // Corroboration goes on the row cut nearest the detector's own date — the one it was
        // describing.
        var host: Int? = nil
        for (i, k) in kept.enumerated() {
            if !(k.at > b.lo && k.at <= b.hi) { continue }
            let better: Bool
            if let h = host { better = abs(k.at - b.at) < abs(kept[h].at - b.at) } else { better = true }
            if better { host = i }
        }
        guard let h = host else {
            undated.append(b)
            continue
        }
        var also = kept[h].also ?? []
        for reason in [b.reason] + (b.also ?? []) where !also.contains(reason) { also.append(reason) }
        kept[h].also = also
    }
    kept.append(contentsOf: mergeBoundaries(undated))
    return Rust.stableSorted(kept) { $0.at < $1.at }
}

/// Collapse overlapping candidates into one boundary each, in time order. Windows that merely touch
/// (one ends exactly where the next begins) are separate swaps, not one. A `/who` cut is never
/// collapsed away — see `resolveGroup`.
public func mergeBoundaries(_ candidates: [Boundary]) -> [Boundary] {
    let sorted = Rust.stableSorted(candidates) { a, b in a.lo != b.lo ? a.lo < b.lo : a.hi < b.hi }
    var out: [Boundary] = []
    var group: [Boundary] = []
    var groupHi = Int64.min
    for b in sorted {
        if !group.isEmpty && b.lo >= groupHi {
            out.append(contentsOf: resolveGroup(group))
            group.removeAll()
        }
        groupHi = max(groupHi, b.hi)
        group.append(b)
    }
    if !group.isEmpty { out.append(contentsOf: resolveGroup(group)) }
    return Rust.stableSorted(out) { $0.at < $1.at }
}

/// Split observations at hard cut points so shift detection never reasons across a swap the log
/// already announced.
func hardSegments(_ observations: [ClassObservation], _ hard: [Boundary]) -> [[ClassObservation]] {
    if hard.isEmpty { return [observations] }
    let cuts = hard.map(\.at).sorted()
    var segments = [[ClassObservation]](repeating: [], count: cuts.count + 1)
    for o in observations {
        var i = 0
        while i < cuts.count && o.ts >= cuts[i] { i += 1 }
        segments[i].append(o)
    }
    return segments
}

/// Every raw slice of the timeline, before scoring: `[start, end)` plus the boundary that made it.
struct Slice {
    var start: Boundary
    var end: Int64?
    var observations: [ClassObservation]
}

func sliceTimeline(_ observations: [ClassObservation], _ boundaries: [Boundary], _ firstTs: Int64) -> [Slice] {
    var opens: [Boundary] = [Boundary(lo: firstTs, hi: firstTs, at: firstTs, reason: "logStart", also: nil)]
    opens.append(contentsOf: boundaries)
    var out: [Slice] = []
    for i in 0..<opens.count {
        let end: Int64? = i + 1 < opens.count ? opens[i + 1].at : nil
        let start = opens[i]
        let at = start.at
        var inside: [ClassObservation] = []
        for o in observations {
            if o.ts < at { continue }
            if let e = end, o.ts >= e { continue }
            inside.append(o)
        }
        out.append(Slice(start: start, end: end, observations: inside))
    }
    return out
}

/// `i64::saturating_sub`.
private func satSub(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, o) = a.subtractingReportingOverflow(b)
    if !o { return r }
    return b < 0 ? Int64.max : Int64.min
}

/// How much of `[start, end)` a correction covers. Both edges open ⇒ `Int64.max` — the TS's
/// `Infinity`, which only ever ends up compared against another overlap.
func overlapMs(_ c: ComboCorrection, _ start: Int64, _ end: Int64?) -> Int64 {
    let hi: Int64
    switch (c.endTs, end) {
    case (let a?, let b?): hi = min(a, b)
    case (let a?, nil): hi = a
    case (nil, let b?): hi = b
    case (nil, nil): hi = Int64.max
    }
    return satSub(hi, max(c.startTs, start))
}

/// The correction that governs a slice, or `nil`. Two rules, in order:
///
///   1. A correction COVERING the slice's start wins.
///   2. Otherwise the correction OVERLAPPING the slice most wins; ties go to the latest `setAt`.
///
/// Rule 2 exists because boundaries MOVE under a standing override: a correction is written against
/// the interval the user was looking at, and intervals are rebuilt from scratch on every fold.
public func correctionForSlice(_ corrections: [ComboCorrection], _ start: Int64, _ end: Int64?) -> ComboCorrection? {
    // `laterOf`: `b.setAt >= a.setAt ? b : a` — the LAST of equal `setAt` wins.
    func laterOf(_ a: ComboCorrection, _ b: ComboCorrection) -> ComboCorrection { b.setAt >= a.setAt ? b : a }
    let covering = corrections.filter { start >= $0.startTs && ($0.endTs.map { start <= $0 } ?? true) }
    if !covering.isEmpty { return covering.dropFirst().reduce(covering[0], laterOf) }
    let overlapping = corrections.filter { overlapMs($0, start, end) > 0 }
    guard let first = overlapping.first else { return nil }
    return overlapping.dropFirst().reduce(first) { a, b in
        let da = overlapMs(a, start, end)
        let db = overlapMs(b, start, end)
        if db > da { return b }
        if db < da { return a }
        return laterOf(a, b)
    }
}

/// What `slotsFor` decided, and how much of it the user is responsible for.
struct SlotDecision {
    var slots: [ComboSlot]
    var expectedSlots: Int
    /// The user's override is what is on screen — inference must not touch these slots.
    var provenanceLock: Bool
    /// The user's override applies here and a `/who` row inside the span said otherwise.
    var overruled: Bool
}

/// Slots for one slice, in authority order (§ 4.4):
///   1. the LAST `/who` row inside it — the game named the loadout for this very span, so it wins
///      even over a user correction,
///   2. a user override governing it,
///   3. inference.
///
/// A `/who` row also sets `expectedSlots` from its own arity, which is ground truth about
/// CARDINALITY as well as membership. Rule 1 is the only way an explicit override loses, so when it
/// fires against a live override the interval carries `userOverruled`.
func slotsFor(_ slice: Slice, _ input: IntervalInput, _ prior: Int) -> SlotDecision {
    let at = slice.start.at
    // The LAST row inside the slice, which is rule 1.
    let row = input.whoRows.last { r in r.ts >= at && (slice.end.map { r.ts < $0 } ?? true) }
    let correction = correctionForSlice(input.corrections, at, slice.end)
    if let row {
        return SlotDecision(slots: statedSlots(row.classes, "who"),
                            expectedSlots: row.classes.count == 2 ? 2 : 3,
                            provenanceLock: false,
                            overruled: correction.map { $0.classes != row.classes } ?? false)
    }
    if let c = correction {
        return SlotDecision(slots: statedSlots(c.classes, "user"),
                            expectedSlots: c.classes.count == 2 ? 2 : 3,
                            provenanceLock: true,
                            overruled: false)
    }
    return SlotDecision(slots: scoreSlots(slice.observations, prior), expectedSlots: prior,
                        provenanceLock: false, overruled: false)
}

func toInterval(_ slice: Slice, _ input: IntervalInput, _ index: Int) -> ComboInterval {
    let statements = LevelStatements(levels: input.levels, whoRows: input.whoRows)
    let (levelLo, levelHi) = levelRange(statements, slice.start.at, slice.end)
    let prior: Int = (levelLo.map { $0 < tertiaryUnlockLevel } ?? false) ? 2 : 3
    let decision = slotsFor(slice, input, prior)
    let lastTs = slice.observations.last?.ts
    var interval = ComboInterval(
        id: "ci\(index + 1)",
        startTs: slice.start.at,
        endTs: slice.end,
        startLo: slice.start.lo,
        startHi: slice.start.hi,
        // An open interval has not ended, so `endHi` stays null, but `endLo` is the last moment we
        // HAVE evidence for. A closed interval's end is the next cut.
        endLo: slice.end ?? lastTs,
        endHi: slice.end,
        startReason: slice.start.reason,
        startAlso: nil,
        expectedSlots: decision.expectedSlots,
        slots: decision.slots,
        levelLo: levelLo,
        levelHi: levelHi,
        evidenceCount: slice.observations.count,
        userLocked: decision.provenanceLock,
        userOverruled: decision.overruled ? true : nil,
        levelRegressed: levelRegressedInside(statements, slice.start.at, slice.end) ? true : nil)
    var also = slice.start.also ?? []
    // The window could not be split further and still names more classes than a loadout holds, so
    // say so rather than silently dropping the surplus (§ 4.5's floor rule).
    if exclusiveSpans(slice.observations).count > interval.expectedSlots { also.append("overDetermined") }
    if !also.isEmpty {
        var deduped: [String] = []
        for r in also where !deduped.contains(r) { deduped.append(r) }
        interval.startAlso = deduped
    }
    return interval
}

/// Two intervals that resolve to the same classes across a SOFT boundary were never two.
func mergeable(_ a: ComboInterval, _ b: ComboInterval) -> Bool {
    if b.startReason == "who" || b.startReason == "levelDrop" || b.startReason == "user" { return false }
    // A locked span is the user's statement and an overruled one carries a notice they must see;
    // collapsing either into a neighbour would delete the thing the row exists to say.
    if a.userLocked || b.userLocked { return false }
    if a.userOverruled == true || b.userOverruled == true { return false }
    func key(_ i: ComboInterval) -> String {
        i.slots.map { $0.candidates.joined(separator: "|") }.sorted().joined(separator: "/")
    }
    return key(a) == key(b)
}

/// Post-pass for the merge rule (§ 4.5): a soft boundary between identical slot sets was noise.
func collapse(_ intervals: [ComboInterval]) -> [ComboInterval] {
    var out: [ComboInterval] = []
    for interval in intervals {
        if let prev = out.last, mergeable(prev, interval) {
            var p = prev
            p.endTs = interval.endTs
            p.endLo = interval.endLo
            p.endHi = interval.endHi
            p.evidenceCount += interval.evidenceCount
            // A max with the `-Infinity` result folded back to null: two intervals that both state
            // nothing still state nothing.
            switch (p.levelHi, interval.levelHi) {
            case (let a?, let b?): p.levelHi = max(a, b)
            case (let a?, nil): p.levelHi = a
            case (nil, let b?): p.levelHi = b
            case (nil, nil): p.levelHi = nil
            }
            out[out.count - 1] = p
            continue
        }
        var next = interval
        next.id = "ci\(out.count + 1)"
        out.append(next)
    }
    return out
}

/// The whole pass. Observations must arrive in seq order (the module keeps them that way).
///
/// It recomputes from scratch every time, deliberately (§ 4.5): a `/who` typed an hour from now, or
/// a user correction, retroactively re-labels the past, and patching intervals in place would leave
/// a stale id pointing at a span that no longer exists. Ids are therefore snapshot-scoped.
public func buildIntervals(_ raw: IntervalInput) -> [ComboInterval] {
    let observations = Rust.stableSorted(raw.observations) { $0.seq < $1.seq }
    if observations.isEmpty { return [] }
    let input = IntervalInput(observations: observations, whoRows: raw.whoRows,
                              levels: raw.levels, corrections: raw.corrections)
    // Level dings first (the log SAYS a swap happened), then the evidence shift inside each segment
    // they cut — a shift is only meaningful within one announced era. `/who` disagreements come
    // last, because they only fire where nothing sharper already cut.
    let drops = levelDropBoundaries(input.levels)
    var shifts: [Boundary] = []
    for segment in hardSegments(observations, mergeBoundaries(drops)) {
        // The prior is enough here: a 2-slot era simply cannot be over-determined at 3.
        shifts.append(contentsOf: evidenceShiftBoundaries(segment, 3))
    }
    var all = drops
    all.append(contentsOf: shifts)
    let merged = mergeBoundaries(all)
    // …and put back any ding the merge swallowed that the evidence says was its own swap. After the
    // merge rather than inside it, because the test needs the observations and because it may only
    // ever ADD a cut the merge deleted.
    var withReinstated = merged
    withReinstated.append(contentsOf: reinstatedDrops(observations, drops, merged, 3))
    let dated = mergeBoundaries(withReinstated)
    // …then the two `/who` rules, narrow first. `whoShiftBoundaries` cuts at a row the evidence
    // behind it contradicts. Its cuts are handed to `whoBoundaries` as already-dated, so a
    // disagreement the row-level rule has just placed does not open a second, wider boundary.
    let shifted = whoShiftBoundaries(observations, input.whoRows, dated, observations[0].ts)
    var candidates = dated
    candidates.append(contentsOf: shifted)
    var datedAndShifted = dated
    datedAndShifted.append(contentsOf: shifted)
    candidates.append(contentsOf: whoBoundaries(input.whoRows, datedAndShifted))
    let placed = mergeBoundaries(candidates)
    // Asked a second time, now of the boundaries that actually SURVIVED. This pass guarantees every
    // disagreeing adjacent pair ends up with a cut between them, so no slice can hold two
    // contradictory rows.
    var boundaries = placed
    boundaries.append(contentsOf: whoBoundaries(input.whoRows, placed))
    boundaries = Rust.stableSorted(boundaries) { $0.at < $1.at }
    boundaries = boundaries.filter { $0.at > observations[0].ts }
    let slices = sliceTimeline(observations, boundaries, observations[0].ts)
    let built = slices.enumerated().map { toInterval($0.element, input, $0.offset) }
    return collapse(built)
}
