// The PPM engine and the minute-window ledger (fold/src/combat/procwindows.rs).
//
// `procRate` carries three denominators, none hidden, each absent below its sample floor rather than
// 0 — one proc in a two-second pull is not 30 ppm. `WindowAccum` is the wall-clock-minute ledger the
// Tier-B counterfactual needs, plus the eligibility partition and the comparison itself.
//
// Active time is reused, never redefined: ingest hands this ledger the exact per-hit delta
// `routing.rs` just accrued, so the two cannot drift. One caveat is labeled rather than fixed —
// `route()` accrues active time before the incoming/outgoing split, so incoming damage extends it
// too. The number keeps the meter's shipped meaning; `per100Swings` has no such ambiguity.
//
// Medians, never means, and each arm reports its own median, IQR and n; the arms are never pooled.
// Confounds are declared, never corrected, and the ones this ledger cannot test are declared as
// untested — an omitted check reads as a passed one.
import Foundation
import EQCompanionCore

/// Below this much active time, `ppmActive` and `ppmWall` are absent.
public let MIN_ACTIVE_SEC: Double = 10.0
/// Below this many logged swings, `per100Swings` is absent.
public let MIN_SWINGS: Int64 = 20

/// The exposure gate for a link, counted in procs and not in swings: "it never fired without it" is
/// evidence only in proportion to the firings the inactive arm should have produced. So the gate is
/// the lane's own observed rate projected onto the inactive exposure,
/// `inactiveSwings × (withCount / activeSwings)`.
///
/// Three: below three expected firings a null result is ordinary luck (at λ = 3 a Poisson zero still
/// happens 5% of the time), and raising it silences genuine exclusivity.
public let MIN_EXPECTED_INACTIVE_PROCS: Double = 3.0

/// One wall-clock minute, chosen by measurement: on the real log minute windows sample both arms of
/// the biggest comparison, which a five-minute window would not do for the smaller arm.
public let WINDOW_MS: Int64 = 60_000

/// Memory bound, drop-oldest — about 2.8 days of continuous play. Exists only so an unbounded map
/// cannot.
public let WINDOW_CAP = 4_000

/// Per-window volume gates. A minute spent standing still is discarded from both arms rather than
/// counted as a zero.
public let MIN_WINDOW_SWINGS: Int64 = 10
public let MIN_WINDOW_ACTIVE_MS: Int64 = 20_000

/// Per-arm sample gate for a Tier-B estimate. Below this the verdict is `insufficient-sample`,
/// naming which arm is short.
public let MIN_ARM_WINDOWS = 20

/// A co-state is declared a confound when its active fraction differs between the arms by more than
/// this (20 percentage points).
public let CO_STATE_GAP: Double = 0.2

/// The sentence for an effect with no per-hit marker, which is all but one of the stances and
/// invocations. It rides the row whatever the verdict is.
private let NO_PER_HIT_MARKER_NOTE = "A stance that boosts base melee has no per-hit marker in the log. Nothing distinguishes a swing under Offensive from a swing under Balanced except the swing\u{2019}s number - and the mob, your level and your gear all changed too. The window comparison is the closest honest answer, and it is an estimate."

/// Neither is recorded in the minute ledger, so neither can be tested — declared rather than
/// omitted, because a confound list missing the checks it could not run reads as a clean bill.
private let UNTESTED_CONFOUNDS =
    "not tested - level drift and mob mix are not carried in the minute ledger"

/// Kept short: it rides every effect row of a 4×/sec snapshot, so a paragraph here is payload.
private let DIRECT_NOTE =
    "No lane is attributed to this state; the exact per-lane numbers are in the lane list."

/// One minute of combat, as the counterfactual sees it.
public struct ProcWindow {
    /// `floor(ts / WINDOW_MS)` — the window's identity.
    public var minute: Int64
    /// Capped-gap active time accrued in this window, using the engine's own per-hit delta.
    public var activeMs: Int64
    /// Your swing attempts: melee + slay hits, plus your misses.
    public var swings: Int64
    /// Your outgoing damage.
    public var outDamage: Int64
    /// Of that, the damage carried by detected proc lines.
    public var procDamage: Int64
    /// The exclusivity groups the commits inside this minute belonged to. The purity gate is
    /// per-state, so a bare count cannot implement it — an unrelated coat swap must not disqualify a
    /// window from the stance comparison.
    public var transitionGroups: Set<String>
    /// `<kind>:<key>` of every state observed active at a combat event in this window. Sampled at
    /// accrual points on purpose: a state that was only on during a lull nobody swung in has no
    /// bearing on a comparison of swinging minutes.
    public var stateKeys: Set<String>
}

/// One fold into the ledger. Every field optional because the three producers (damage, swing,
/// commit) each move a different subset.
public struct WindowFold {
    public var ts: Int64 = 0
    /// The exact per-hit active-time delta the engine just accrued; never recomputed here.
    public var activeDeltaMs: Int64 = 0
    public var outDamage: Int64 = 0
    public var procDamage: Int64 = 0
    public var swings: Int64 = 0

    public init(ts: Int64 = 0, activeDeltaMs: Int64 = 0, outDamage: Int64 = 0,
                procDamage: Int64 = 0, swings: Int64 = 0) {
        self.ts = ts; self.activeDeltaMs = activeDeltaMs; self.outDamage = outDamage
        self.procDamage = procDamage; self.swings = swings
    }
}

/// The minute-window ledger. Lives on `Agg` for the same reason the healing and proc ledgers do: an
/// encounter and a finalized zone session inherit it frozen, and every number is folded on ingest so
/// nothing here depends on a capped or truncated event ring.
public struct WindowAccum {
    /// Keyed by minute, insertion-ordered because the drop-oldest cap evicts the first key inserted.
    private var windows = JSMap<ProcWindow>()

    public init() {}

    /// Fold combat activity into the window covering `f.ts`.
    public mutating func fold(_ f: WindowFold, _ active: Set<String>) {
        let key = ensure(f.ts, active)
        var w = windows[key]!
        w.activeMs += f.activeDeltaMs
        w.outDamage += f.outDamage
        w.procDamage += f.procDamage
        w.swings += f.swings
        windows.insert(key, w)
    }

    /// Record a state commit. The window it lands in is impure for that state's group: the boundary
    /// carries the reuse timer, the re-buff burst and the mid-window re-target.
    public mutating func noteTransition(_ ts: Int64, _ group: String, _ active: Set<String>) {
        let key = ensure(ts, active)
        var w = windows[key]!
        w.transitionGroups.insert(group)
        w.stateKeys.formUnion(active)
        windows.insert(key, w)
    }

    /// Windows in ascending minute order.
    public func list() -> [ProcWindow] {
        stableSorted(windows.values) { $0.minute < $1.minute }
    }

    private mutating func ensure(_ ts: Int64, _ active: Set<String>) -> String {
        let minute = roundsDivEuclid(ts, WINDOW_MS)
        let key = String(minute)
        if var w = windows[key] {
            // A state can turn on mid-window; the set is a union over the window, not a snapshot.
            w.stateKeys.formUnion(active)
            windows.insert(key, w)
            return key
        }
        windows.insert(key, ProcWindow(minute: minute, activeMs: 0, swings: 0, outDamage: 0,
                                       procDamage: 0, transitionGroups: [], stateKeys: active))
        if windows.count > WINDOW_CAP, let oldest = windows.keys.first {
            windows.remove(oldest)
        }
        return key
    }
}

// MARK: - Checkpoint

extension WindowAccum {
    /// The whole minute ledger, insertion order intact — the drop-oldest cap evicts the FIRST key
    /// inserted, so the order is load-bearing state, not presentation.
    func checkpointState() -> JSONValue {
        .object(["windows": windows.checkpoint { w in
            .object([
                "minute": .int(w.minute), "activeMs": .int(w.activeMs), "swings": .int(w.swings),
                "outDamage": .int(w.outDamage), "procDamage": .int(w.procDamage),
                "transitionGroups": ckStringSet(w.transitionGroups),
                "stateKeys": ckStringSet(w.stateKeys),
            ])
        }])
    }

    static func fromCheckpoint(_ v: JSONValue) -> WindowAccum? {
        guard let m = JSMap<ProcWindow>.fromCheckpoint(v["windows"], { w -> ProcWindow? in
            guard let minute = w["minute"].int64, let activeMs = w["activeMs"].int64,
                  let swings = w["swings"].int64, let outDamage = w["outDamage"].int64,
                  let procDamage = w["procDamage"].int64,
                  let transitionGroups = ckStringSetBack(w["transitionGroups"]),
                  let stateKeys = ckStringSetBack(w["stateKeys"]) else { return nil }
            return ProcWindow(minute: minute, activeMs: activeMs, swings: swings,
                              outDamage: outDamage, procDamage: procDamage,
                              transitionGroups: transitionGroups, stateKeys: stateKeys)
        }) else { return nil }
        var acc = WindowAccum()
        acc.windows = m
        return acc
    }
}

/// The two arms of a matched-window comparison.
public struct WindowArms {
    /// Windows where the state was on for the whole minute.
    public var active: [ProcWindow] = []
    /// Windows where it was off for the whole minute.
    public var inactive: [ProcWindow] = []
}

/// The exclusivity group a projected span commits under. Coats collapse to the family prefix,
/// because the log's dry line names a family and never a venom.
public func groupOf(_ kind: StateKind, _ key: String) -> String {
    switch kind {
    case .stance, .invocation: return kind.asStr
    case .coat: return "coat:"
    case .buff: return "buff:\(key)"
    }
}

/// Split the ledger into the two arms for one state, applying both eligibility gates: purity (no
/// commit of that state's exclusivity group landed inside the window — a window containing a switch
/// is discarded, not split) and volume.
///
/// `group` is matched as a prefix. Exact match is the normal case; the prefix exists for coats,
/// whose groups are `coat:utility` and `coat:combat:<line>` and whose projected span cannot say
/// which it was, so a coat study reads `coat:` and discards more windows than a per-venom rule
/// would — the safe direction for a purity gate.
public func partitionWindows(_ windows: [ProcWindow], _ stateKey: String, _ group: String) -> WindowArms {
    var arms = WindowArms()
    for w in windows {
        if w.transitionGroups.contains(where: { $0.hasPrefix(group) }) { continue }
        if w.swings < MIN_WINDOW_SWINGS || w.activeMs < MIN_WINDOW_ACTIVE_MS { continue }
        if w.stateKeys.contains(stateKey) { arms.active.append(w) } else { arms.inactive.append(w) }
    }
    return arms
}

/// Windows that clear the volume gates alone — the report's `windowsEligible`, state-independent
/// because purity is decided per state.
public func volumeEligible(_ windows: [ProcWindow]) -> Int {
    windows.filter { $0.swings >= MIN_WINDOW_SWINGS && $0.activeMs >= MIN_WINDOW_ACTIVE_MS }.count
}

/// How long the thing that fires a lane was actually present, and what it was called.
///
/// A proc cannot fire while its source is off — a rogue Strike needs the coat on the blades — so
/// `ppmActive` over the whole segment is systematically low.
public struct ProcSourceWindow {
    public var activeSec: Double
    public var name: String

    public init(activeSec: Double, name: String) { self.activeSec = activeSec; self.name = name }
}

/// What a rate needs.
public struct RateInput {
    public var count: Int64 = 0
    /// The segment's active time (the meter's own definition).
    public var activeSec: Double = 0
    public var durationSec: Double = 0
    public var swings: Int64 = 0
    /// The lane's source window, when one is modeled.
    public var source: ProcSourceWindow?
    /// The caller is a lane whose source window it could not resolve: the segment's active time is
    /// used and `sourceAmbiguous` is set, so the assumption travels with the number. Distinct from
    /// passing neither field, which is what the overall headline does.
    public var sourceUnknown: Bool = false

    public init(count: Int64 = 0, activeSec: Double = 0, durationSec: Double = 0, swings: Int64 = 0,
                source: ProcSourceWindow? = nil, sourceUnknown: Bool = false) {
        self.count = count; self.activeSec = activeSec; self.durationSec = durationSec
        self.swings = swings; self.source = source; self.sourceUnknown = sourceUnknown
    }
}

public struct ProcRateView {
    public var count: Int64
    public var swings: Int64
    public var sourceSec: Double?
    public var sourceName: String?
    public var sourceAmbiguous: Bool?
    public var ppmActive: Double?
    public var ppmWall: Double?
    public var per100Swings: Double?

    public var json: JSONValue {
        var o: [String: JSONValue] = ["count": .int(count), "swings": .int(swings)]
        if let v = sourceSec { o["sourceSec"] = .double(v) }
        if let v = sourceName { o["sourceName"] = .string(v) }
        if let v = sourceAmbiguous { o["sourceAmbiguous"] = .bool(v) }
        if let v = ppmActive { o["ppmActive"] = .double(v) }
        if let v = ppmWall { o["ppmWall"] = .double(v) }
        if let v = per100Swings { o["per100Swings"] = .double(v) }
        return .object(o)
    }
}

/// The three denominators, each absent below its floor. `count` and `swings` are always present and
/// exact — they count lines the game printed; only the rates can be missing.
///
/// `ppmActive` divides by the source window when one is known and by the segment otherwise, and says
/// which it did. The floor applies to whichever denominator is used, and the source window is
/// declared even when it fails the floor so the absence message can quote it.
///
/// `ppmWall` and `per100Swings` are unchanged by the source window.
public func procRate(_ i: RateInput) -> ProcRateView {
    var view = ProcRateView(count: i.count, swings: i.swings, sourceSec: nil, sourceName: nil,
                            sourceAmbiguous: nil, ppmActive: nil, ppmWall: nil, per100Swings: nil)
    let sec = i.source?.activeSec ?? i.activeSec
    if let s = i.source {
        view.sourceSec = sec
        view.sourceName = s.name
    } else if i.sourceUnknown {
        view.sourceSec = sec
        view.sourceAmbiguous = true
    }
    if sec >= MIN_ACTIVE_SEC {
        view.ppmActive = Double(i.count) / (sec / 60.0)
        if i.durationSec > 0.0 {
            view.ppmWall = Double(i.count) / (i.durationSec / 60.0)
        }
    }
    if i.swings >= MIN_SWINGS {
        view.per100Swings = Double(100 * i.count) / Double(i.swings)
    }
    return view
}

/// Co-occurrence counts plus both swing exposures. The active-side count is what turns the gate from
/// a flat swing floor into the lane's own observed rate.
public struct LinkInput {
    public var withCount: Int64
    public var withoutCount: Int64
    /// Your swing attempts logged while the state was active — the denominator of the lane's own
    /// proc rate, and the only reason this classifier can tell a rare proc from a common one.
    public var activeSwings: Int64
    /// Your swing attempts logged while the state was inactive — the exposure the claim rests on.
    public var inactiveSwings: Int64

    public init(withCount: Int64, withoutCount: Int64, activeSwings: Int64, inactiveSwings: Int64) {
        self.withCount = withCount; self.withoutCount = withoutCount
        self.activeSwings = activeSwings; self.inactiveSwings = inactiveSwings
    }
}

/// How many firings the inactive arm was worth, in procs. `max` of two estimates: what the arm
/// actually produced (direct observation beats any model) and what the active arm's rate predicts
/// for that many swings — the only estimate available when `withoutCount == 0`, which is the case
/// the gate exists for.
public func expectedInactiveProcs(_ i: LinkInput) -> Double {
    let rate = i.activeSwings > 0 ? Double(i.withCount) / Double(i.activeSwings) : 0.0
    return Swift.max(Double(i.withoutCount), Double(i.inactiveSwings) * rate)
}

/// Classify a link. The default is `inconclusive`: a lane that never fired without a state is
/// evidence only when the inactive arm had a real chance to produce firings, so concentration alone
/// can never reach `exclusive`.
public func linkStrength(_ i: LinkInput) -> String {
    let total = i.withCount + i.withoutCount
    if total == 0 { return "inconclusive" }
    if expectedInactiveProcs(i) < MIN_EXPECTED_INACTIVE_PROCS { return "inconclusive" }
    if i.withoutCount == 0 { return "exclusive" }
    if Double(i.withCount) / Double(total) >= 0.8 { return "correlated" }
    return "weak"
}

/// `with / (with + without)`, 0 when the lane never fired — never NaN, which a percentage formatter
/// would print as "NaN%".
public func concentrationOf(_ withCount: Int64, _ withoutCount: Int64) -> Double {
    let total = withCount + withoutCount
    return total == 0 ? 0.0 : Double(withCount) / Double(total)
}

public struct ProcLink {
    public var kind: StateKind
    public var key: String
    public var name: String
    public var withCount: Int64
    public var withoutCount: Int64
    public var concentration: Double
    public var inactiveSwings: Int64
    public var strength: String

    public var json: JSONValue {
        [
            "kind": .string(kind.asStr), "key": .string(key), "name": .string(name),
            "withCount": .int(withCount), "withoutCount": .int(withoutCount),
            "concentration": .double(concentration), "inactiveSwings": .int(inactiveSwings),
            "strength": .string(strength),
        ]
    }
}

public struct MarginalEstimate {
    public var nActive: Int
    public var nInactive: Int
    public var medDpsActive: Double
    public var medDpsInactive: Double
    public var iqrActive: [Double]
    public var iqrInactive: [Double]
    public var deltaDps: Double
    public var deltaPct: Double
    public var medProcDpsActive: Double
    public var medProcDpsInactive: Double
    public var medDmgPerSwingActive: Double
    public var medDmgPerSwingInactive: Double

    public var json: JSONValue {
        [
            "nActive": .int(Int64(nActive)), "nInactive": .int(Int64(nInactive)),
            "medDpsActive": .double(medDpsActive), "medDpsInactive": .double(medDpsInactive),
            "iqrActive": .array(iqrActive.map { .double($0) }),
            "iqrInactive": .array(iqrInactive.map { .double($0) }),
            "deltaDps": .double(deltaDps), "deltaPct": .double(deltaPct),
            "medProcDpsActive": .double(medProcDpsActive),
            "medProcDpsInactive": .double(medProcDpsInactive),
            "medDmgPerSwingActive": .double(medDmgPerSwingActive),
            "medDmgPerSwingInactive": .double(medDmgPerSwingInactive),
        ]
    }
}

public struct DirectView {
    public var damage: Int64
    public var heal: Int64
    public var hits: Int64
    public var dpsContribution: Double
    public var lanes: [String]

    public var json: JSONValue {
        [
            "damage": .int(damage), "heal": .int(heal), "hits": .int(hits),
            "dpsContribution": .double(dpsContribution),
            "lanes": .array(lanes.map { .string($0) }),
        ]
    }
}

private func noDirect() -> DirectView {
    DirectView(damage: 0, heal: 0, hits: 0, dpsContribution: 0.0, lanes: [])
}

public struct EffectAttribution {
    public var kind: StateKind
    public var key: String
    public var name: String
    public var direct: DirectView
    public var verdict: String
    public var marginal: MarginalEstimate?
    public var confounds: [String]
    public var note: String

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "kind": .string(kind.asStr), "key": .string(key), "name": .string(name),
            "direct": direct.json, "verdict": .string(verdict),
            "confounds": .array(confounds.map { .string($0) }), "note": .string(note),
        ]
        if let m = marginal { o["marginal"] = m.json }
        return .object(o)
    }
}

public struct AttributionReport {
    public var sessionId: String
    public var windowSec: Int64
    public var windowsTotal: Int
    public var windowsEligible: Int
    public var effects: [EffectAttribution]

    public var json: JSONValue {
        [
            "sessionId": .string(sessionId), "windowSec": .int(windowSec),
            "windowsTotal": .int(Int64(windowsTotal)),
            "windowsEligible": .int(Int64(windowsEligible)),
            "effects": .array(effects.map(\.json)),
        ]
    }
}

/// Linear-interpolated quantile (PERCENTILE.INC / type-7) over an ascending slice. Stated so the IQR
/// the UI prints is reproducible.
func quantile(_ sorted: [Double], _ p: Double) -> Double {
    if sorted.isEmpty { return 0.0 }
    let idx = p * Double(sorted.count - 1)
    let lo = Int(idx.rounded(.down))
    let hi = Int(idx.rounded(.up))
    if lo == hi { return sorted[lo] }
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - Double(lo))
}

/// The three per-window statistics of one arm, each sorted ascending. Kept separate because a state
/// can move proc damage sharply while leaving damage-per-swing flat, and one blended headline would
/// hide that mechanism.
private struct ArmSeries {
    var dps: [Double] = []
    var procDps: [Double] = []
    var perSwing: [Double] = []
}

private func seriesOf(_ ws: [ProcWindow]) -> ArmSeries {
    var s = ArmSeries()
    for w in ws {
        let sec = Double(w.activeMs) / 1000.0
        if sec > 0.0 {
            s.dps.append(Double(w.outDamage) / sec)
            s.procDps.append(Double(w.procDamage) / sec)
        }
        if w.swings > 0 {
            s.perSwing.append(Double(w.outDamage) / Double(w.swings))
        }
    }
    s.dps.sort()
    s.procDps.sort()
    s.perSwing.sort()
    return s
}

/// The matched-window comparison. Both arms' n's ride along: a delta with one n hidden is a
/// precision claim, and the renderer needs both to draw the estimate as a range.
private func marginalOf(_ arms: WindowArms) -> MarginalEstimate {
    let a = seriesOf(arms.active)
    let i = seriesOf(arms.inactive)
    let medA = quantile(a.dps, 0.5)
    let medI = quantile(i.dps, 0.5)
    return MarginalEstimate(
        nActive: arms.active.count,
        nInactive: arms.inactive.count,
        medDpsActive: medA,
        medDpsInactive: medI,
        iqrActive: [quantile(a.dps, 0.25), quantile(a.dps, 0.75)],
        iqrInactive: [quantile(i.dps, 0.25), quantile(i.dps, 0.75)],
        deltaDps: medA - medI,
        deltaPct: medI > 0.0 ? ((medA - medI) / medI) * 100.0 : 0.0,
        medProcDpsActive: quantile(a.procDps, 0.5),
        medProcDpsInactive: quantile(i.procDps, 0.5),
        medDmgPerSwingActive: quantile(a.perSwing, 0.5),
        medDmgPerSwingInactive: quantile(i.perSwing, 0.5))
}

/// Round-half-up, matching JS `Math.round` and not `f64::round`. The two agree on the non-negative
/// fractions passed here; a negative would split them.
private func pctText(_ f: Double) -> String {
    "\(Int64((f * 100.0 + 0.5).rounded(.down)))%"
}

private func fractionActive(_ ws: [ProcWindow], _ key: String) -> Double {
    if ws.isEmpty { return 0.0 }
    let n = ws.filter { $0.stateKeys.contains(key) }.count
    return Double(n) / Double(ws.count)
}

/// Every other tracked state whose presence differs materially between the arms — the one confound
/// the ledger can measure. It exposes "X adds 90 dps" that is really "you happened to be in
/// offensive stance for those minutes".
private func coStateConfounds(_ arms: WindowArms, _ selfKey: String) -> [String] {
    var keys = Set<String>()
    for w in arms.active + arms.inactive { keys.formUnion(w.stateKeys) }
    keys.remove(selfKey)
    // Byte order matches JS's default comparator for these ASCII `<kind>:<key>` strings.
    let sorted = keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    var out: [String] = []
    for k in sorted {
        let fa = fractionActive(arms.active, k)
        let fi = fractionActive(arms.inactive, k)
        if abs(fa - fi) <= CO_STATE_GAP { continue }
        out.append("co-state - \(k) was active in \(pctText(fa)) of active windows but \(pctText(fi)) of inactive ones")
    }
    return out
}

/// True when the arms are temporally separated — every window of one precedes every window of the
/// other. Gear, level and content all drift with time, so a separated comparison is a before/after,
/// not a controlled one.
private func separated(_ a: [ProcWindow], _ b: [ProcWindow]) -> Bool {
    if a.isEmpty || b.isEmpty { return false }
    let aMin = a.map(\.minute).min()!, aMax = a.map(\.minute).max()!
    let bMin = b.map(\.minute).min()!, bMax = b.map(\.minute).max()!
    return aMax < bMin || bMax < aMin
}

/// The declared confound list. Nothing here adjusts a number.
///
/// `zone-mix` is absent by construction, not by oversight: the ledger lives on the `Agg` and a zone
/// change starts a new one, so every window in a report is from one zone.
private func declareConfounds(_ arms: WindowArms, _ selfKey: String) -> [String] {
    var out = coStateConfounds(arms, selfKey)
    if separated(arms.active, arms.inactive) {
        out.append("not-interleaved - the two arms do not overlap in time; gear, level and content all drift with it")
    }
    out.append(UNTESTED_CONFOUNDS)
    return out
}

/// A Tier-A roll-up plus the states it cannot be told apart from.
public struct DirectRollup {
    public var direct: DirectView
    /// Display names of the other states the same lanes fired exclusively under. Two states switched
    /// on together own one body of evidence between them, and both rows must say so.
    public var shared: [String]
}

/// One lane as the Tier-A roll-up reads it — the three fields `directFor` sums plus the links.
public struct LaneForDirect {
    public var name: String
    public var directDamage: Int64
    public var directHeal: Int64
    public var dpsContribution: Double
    public var linked: [ProcLink]

    public init(name: String, directDamage: Int64, directHeal: Int64, dpsContribution: Double,
                linked: [ProcLink]) {
        self.name = name; self.directDamage = directDamage; self.directHeal = directHeal
        self.dpsContribution = dpsContribution; self.linked = linked
    }
}

/// The Tier-A roll-up: every lane whose link to this state came back `exclusive`, which is the
/// rate-aware gate in `linkStrength` and not mere 100% concentration. `damage` / `heal` are the
/// lane's whole totals, because `exclusive` means `withoutCount == 0`.
///
/// It remains a co-occurrence: the log never names what fired a proc, so this measures "these
/// firings all happened with X on", never "X fired them".
public func directFor(_ lanes: [LaneForDirect], _ stateKey: String) -> DirectRollup? {
    var d = noDirect()
    var shared: [String] = []
    for l in lanes {
        guard let link = l.linked.first(where: { stateKeyOf($0.kind, $0.key) == stateKey }) else {
            continue
        }
        if link.strength != "exclusive" { continue }
        d.damage += l.directDamage
        d.heal += l.directHeal
        d.hits += link.withCount
        d.dpsContribution += l.dpsContribution
        d.lanes.append(l.name)
        for other in l.linked
        where other.strength == "exclusive" && stateKeyOf(other.kind, other.key) != stateKey {
            if !shared.contains(other.name) { shared.append(other.name) }
        }
    }
    if d.lanes.isEmpty { return nil }
    shared.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    return DirectRollup(direct: d, shared: shared)
}

/// The confound a shared roll-up declares. Two states committed together leave the same lane
/// exclusive to both and each row reports the full damage, so each must name the other or two rows
/// silently claim one body of evidence twice.
private func sharedConfound(_ shared: [String]) -> String {
    "co-exclusive - \(shared.joined(separator: ", ")) \(shared.count > 1 ? "were" : "was") active for exactly the same firings; the log cannot say which state the proc belongs to"
}

/// The measured row's own note. Names the lanes so the number is auditable, and states the
/// co-occurrence limit so it cannot travel without it.
private func measuredNote(_ d: DirectView) -> String {
    "\(d.hits) firings of \(d.lanes.joined(separator: ", ")) landed only while this state was active, for \(d.damage) damage and \(d.heal) healing - counted, not estimated. A co-occurrence: the log never names what fired a proc."
}

private func shortVerdict(_ nA: Int, _ nI: Int) -> String {
    (nA > 0 && nI > 0) ? "insufficient-sample" : "not-observable"
}

/// Says which arm is short and by how much — never a bare "not enough data".
private func shortNote(_ nA: Int, _ nI: Int) -> String {
    if nA == 0 && nI == 0 {
        return "No minute of this session cleared the volume gates, so no comparison was attempted."
    }
    if nA == 0 {
        return "This state was never active in an eligible minute (\(nI) inactive windows). No comparison is possible."
    }
    if nI == 0 {
        return "This state was active in every one of the \(nA) eligible minutes. No comparison is possible - there is no control group."
    }
    let shortArm = nA < nI ? "active" : "inactive"
    let have = Swift.min(nA, nI)
    return "The \(shortArm) arm has \(have) eligible 60-second windows; \(MIN_ARM_WINDOWS) are needed (\(nA) active / \(nI) inactive)."
}

/// One state to attribute.
public struct EffectInput {
    public var kind: StateKind
    public var key: String
    public var name: String
    public var windows: [ProcWindow]
    /// Tier A, when a lane earned it. Present means the verdict is `measured` and no counterfactual
    /// is attempted.
    public var direct: DirectRollup?
}

/// One state's counterfactual verdict. Four outcomes, and none may be rendered as another:
///
///   `measured`            — an exclusive proc lane behind it, an exact count. Takes precedence over
///                           every window verdict.
///   `estimate`            — both arms cleared `MIN_ARM_WINDOWS`; `marginal` present with confounds
///                           declared beside it, drawn as a range.
///   `insufficient-sample` — both arms have eligible windows but one is short; the note says which.
///   `not-observable`      — one arm is structurally empty, so no comparison is possible. That is
///                           the result, not a defect.
public func attributeEffect(_ i: EffectInput) -> EffectAttribution {
    let stateKey = stateKeyOf(i.kind, i.key)
    // The stance/invocation sentence rides the row whatever the verdict is: an exclusive proc lane
    // measures that lane and says nothing about the base-melee bonus the log never marks.
    let marker: String
    switch i.kind {
    case .stance, .invocation: marker = " \(NO_PER_HIT_MARKER_NOTE)"
    default: marker = ""
    }
    if let rollup = i.direct {
        return EffectAttribution(
            kind: i.kind, key: i.key, name: i.name, direct: rollup.direct, verdict: "measured",
            marginal: nil,
            confounds: rollup.shared.isEmpty ? [] : [sharedConfound(rollup.shared)],
            note: measuredNote(rollup.direct) + marker)
    }
    let arms = partitionWindows(i.windows, stateKey, groupOf(i.kind, i.key))
    let nA = arms.active.count, nI = arms.inactive.count
    if nA >= MIN_ARM_WINDOWS && nI >= MIN_ARM_WINDOWS {
        return EffectAttribution(
            kind: i.kind, key: i.key, name: i.name, direct: noDirect(), verdict: "estimate",
            marginal: marginalOf(arms), confounds: declareConfounds(arms, stateKey),
            note: DIRECT_NOTE + marker)
    }
    return EffectAttribution(
        kind: i.kind, key: i.key, name: i.name, direct: noDirect(), verdict: shortVerdict(nA, nI),
        marginal: nil, confounds: [],
        note: "\(shortNote(nA, nI)) \(DIRECT_NOTE)\(marker)")
}

private let KIND_ORDER: [StateKind] = [.buff, .invocation, .stance, .coat]

private func kindRank(_ k: StateKind) -> Int {
    KIND_ORDER.firstIndex(of: k) ?? Int.max
}

/// The Tier-B report for one zone session. Every observed state gets a row, including the ones whose
/// answer is "no comparison is possible" — omitting those would read as the feature having nothing
/// to say, when what it has to say is that the log never marks them.
public func buildAttributionReport(_ sessionId: String, _ windows: [ProcWindow],
                                   _ states: [StateSpan], _ lanes: [LaneForDirect]) -> AttributionReport {
    // First appearance wins, in the order the spans appear.
    var seen = JSMap<Int>()
    for (i, s) in states.enumerated() {
        let k = stateKeyOf(s.kind, s.key)
        if !seen.containsKey(k) { seen.insert(k, i) }
    }
    let effects0: [EffectAttribution] = seen.pairs.map { (k, i) in
        let s = states[i]
        return attributeEffect(EffectInput(kind: s.kind, key: s.key, name: s.name,
                                           windows: windows, direct: directFor(lanes, k)))
    }
    let effects = stableSorted(effects0) { a, b in
        let ra = kindRank(a.kind), rb = kindRank(b.kind)
        if ra != rb { return ra < rb }
        return Collate.less(a.name, b.name)
    }
    return AttributionReport(sessionId: sessionId, windowSec: WINDOW_MS / 1000,
                             windowsTotal: windows.count, windowsEligible: volumeEligible(windows),
                             effects: effects)
}

/// The per-state firing counts one lane contributes to a link row.
public func linksFor(_ lane: SpellProcLane, _ states: [StateSpan],
                     _ swingsByState: JSMap<Int64>, _ swings: Int64) -> [ProcLink] {
    let count = laneCount(lane)
    return states.map { s in
        let key = stateKeyOf(s.kind, s.key)
        let withCount = sidesCount(lane.byState[key])
        let withoutCount = Swift.max(count - withCount, 0)
        let activeSwings = swingsByState[key] ?? 0
        let inactiveSwings = Swift.max(swings - activeSwings, 0)
        return ProcLink(
            kind: s.kind, key: s.key, name: s.name,
            withCount: withCount, withoutCount: withoutCount,
            concentration: concentrationOf(withCount, withoutCount),
            inactiveSwings: inactiveSwings,
            strength: linkStrength(LinkInput(withCount: withCount, withoutCount: withoutCount,
                                             activeSwings: activeSwings,
                                             inactiveSwings: inactiveSwings)))
    }
}
