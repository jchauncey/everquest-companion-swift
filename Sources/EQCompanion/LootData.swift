// The Loot tab's pure half: the vocabulary and the arithmetic, ported from the Electron renderer so
// the two apps state the same numbers in the same words.
//
// Nothing here touches SwiftUI, AppKit, the engine client or the clock. Every value is Sendable, so
// the whole aggregation runs in a `Task.detached` off the `loot` module snapshot (2.4k rows) and the
// main thread never folds anything.
//
// WHAT IS PORTED, AND FROM WHERE
//   * `LootName`        — `renderer/src/lib/itemName.ts`: the ` +N` counting boundary.
//   * `LootZone`        — `shared/zones.zoneKey` (membership, instance noise stripped) and
//                         `shared/zoneScope.zoneIdKey` (the row fold), which are two different jobs.
//   * `LootDisposition` — `shared/lootDisposition.ts`: a destroy is bag history, never an acquisition.
//   * `LootProgression` — `shared/progressionStats.ts`, cut to the three spans a loot rate divides
//                         by (duration / active / offline). Nothing else of that query is needed here.
//   * `LootSlice`       — `shared/timeslice.ts`: the range ∩ zone the whole tab is measured over.
//   * `LootSession`     — `shared/sessionSegments.ts`: "start a new session now", as marks and the
//                         half-open intervals between them.
//   * `LootInventory`   — `shared/outputs/inventory.ts` + `main/outputs/inventoryParse.ts`:
//                         `/outputfile inventory` → held counts, faithfully enough that the
//                         "in inventory only" chip counts the same 14 items the Electron app does.
//   * `LootAggregate`   — `features/loot/lootGrouping.ts` + `lootSort.ts` + `shared/lootRates.ts`.
import Foundation
import EQCompanionCore

// MARK: - Item names

/// The counting boundary. EQ Legends drops ` +N` variants of items broadly, and a quest that wants
/// `Sphinx Claw` has to see a looted `Sphinx Claw +1`. The strip is END-anchored and applies to the
/// COUNTING key only — the ledger keeps showing what the log printed.
enum LootName {
    private static let variantSuffix = try! NSRegularExpression(pattern: " \\+\\d+$")

    static func normalize(_ name: String) -> String {
        let r = NSRange(name.startIndex..., in: name)
        guard let m = variantSuffix.firstMatch(in: name, range: r), let range = Range(m.range, in: name) else {
            return name
        }
        return String(name[..<range.lowerBound])
    }

    /// Lowercased, `+N`-stripped counting key.
    static func countKey(_ name: String) -> String { normalize(name).lowercased() }

    /// `0` for a base name, `N` for a ` +N` variant.
    static func variantLevel(_ name: String) -> Int {
        let base = normalize(name)
        guard base.count < name.count else { return 0 }
        let suffix = name.dropFirst(base.count).trimmingCharacters(in: .whitespaces)
        return Int(suffix.dropFirst()) ?? 0
    }
}

// MARK: - Zone folds

/// This app carries two folds of a zone name and they do two different jobs. `placeKey` answers
/// membership — "is this the place I am standing in?" — and strips the instance ordinal and the
/// difficulty parenthetical EQ Legends spells into the name. `idKey` is the ROW fold that drop rows
/// and time spans are joined on, and keeps every byte.
enum LootZone {
    static let unknown = "unknown"

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: opts)
    }

    private static let soloGroup = re("\\s*-\\s*(Solo|Group)\\b.*$", [.caseInsensitive])
    private static let tierOrdinal = re("\\s+\\d+\\s*\\([^)]*\\)\\s*$")
    private static let tierParen = re("\\s+\\([^)]*\\)\\s*$")
    private static let separators = re("[\\s-]+")

    private static func strip(_ s: String, _ rx: NSRegularExpression, with: String = "") -> String {
        rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// `Nagafen's Lair - Solo 4 (Refined)` → `nagafen's lair`. A blank name folds to `""`.
    static func placeKey(_ zone: String?) -> String {
        var s = zone ?? ""
        s = strip(s, soloGroup)
        s = strip(s, tierOrdinal)
        s = strip(s, tierParen)
        s = strip(s.lowercased(), separators, with: " ").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// `Befallen 2 (Adaptive)` → `befallen 2 (adaptive)`.
    static func idKey(_ zone: String) -> String {
        zone.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// The one membership test. `key` is the place fold and is the whole test under the default
    /// membership; `exact` narrows it to one tier and is never widening.
    static func admits(_ name: String, key: String?, exact: String?) -> Bool {
        if let k = key, placeKey(name) != k { return false }
        guard let e = exact else { return true }
        return idKey(name) == e
    }
}

// MARK: - Disposition

/// A row on the loot lane means one of two opposite things, so every reader has to say which it
/// wants. `You successfully destroyed 38 Bone Chips.` is a real line and rides this lane so held
/// counts can subtract it.
enum LootDispositionRule {
    static func isDestroyed(_ d: String?) -> Bool { d == "destroyed" }
    /// Everything except the destroy: the item did come off a corpse even when it was auto-sold.
    static func isAcquisition(_ d: String?) -> Bool { !isDestroyed(d) }
    /// Arrived AND stayed — the ownership question. A `sold` row never reached the bags.
    static func isKept(_ d: String?) -> Bool { d != "destroyed" && d != "sold" }
}

// MARK: - Loot events

/// One row of the `loot` module snapshot, with the two keys precomputed once (the grouping identity
/// and the counting key) so no filter ever re-lowercases thousands of names.
struct LootEvent: Sendable, Equatable {
    var item: String
    var itemKey: String
    var countKey: String
    var source: String?
    var zone: String?
    var ts: Int64
    /// Stack size. A `2 Bone Chips` line is two items.
    var count: Int
    var disposition: String?
    var created: String?

    var isDestroyed: Bool { LootDispositionRule.isDestroyed(disposition) }
    var isAcquisition: Bool { LootDispositionRule.isAcquisition(disposition) }

    static func parse(_ state: JSONValue) -> [LootEvent] {
        (state.array ?? []).compactMap { v in
            guard let item = v["item"].string else { return nil }
            return LootEvent(item: item,
                             itemKey: item.lowercased(),
                             countKey: LootName.countKey(item),
                             source: v["source"].string,
                             zone: v["zone"].string,
                             ts: v["ts"].int64 ?? 0,
                             count: v["count"].int ?? 1,
                             disposition: v["disposition"].string,
                             created: v["created"].string)
        }
    }
}

// MARK: - Progression

/// The columns of the `progression` snapshot this tab reads. The loot rates divide by spans derived
/// from exactly these, which is what makes the numerator and the denominators one slice.
struct LootProgression: Sendable {
    var expTs: [Int64] = []
    var killTs: [Int64] = []
    var lootTs: [Int64] = []
    var witnessTs: [Int64] = []
    var levelTs: [Int64] = []
    var aaGainTs: [Int64] = []
    var zoneStart: [Int64] = []
    var zoneEnd: [Int64] = []
    var zoneName: [String] = []
    var offlineStart: [Int64] = []
    var offlineEnd: [Int64] = []
    var lastTs: Int64 = 0

    static let empty = LootProgression()

    private static func ints(_ v: JSONValue) -> [Int64] { (v.array ?? []).compactMap { $0.int64 } }

    static func parse(_ state: JSONValue) -> LootProgression {
        LootProgression(expTs: ints(state["expTs"]),
                        killTs: ints(state["killTs"]),
                        lootTs: ints(state["lootTs"]),
                        witnessTs: ints(state["witnessTs"]),
                        levelTs: ints(state["levelTs"]),
                        aaGainTs: ints(state["aaGainTs"]),
                        zoneStart: ints(state["zoneStart"]),
                        zoneEnd: ints(state["zoneEnd"]),
                        zoneName: (state["zoneName"].array ?? []).compactMap { $0.string },
                        offlineStart: ints(state["offlineStart"]),
                        offlineEnd: ints(state["offlineEnd"]),
                        lastTs: state["lastTs"].int64 ?? 0)
    }

    /// Where the record starts and ends. Nil when nothing carries a timestamp, which is the empty
    /// state and not a range of zero.
    var bounds: (lo: Int64, hi: Int64)? {
        var lo = Int64.max
        var hi = Int64.min
        for col in [expTs, killTs, witnessTs, lootTs, zoneStart, levelTs, aaGainTs] where !col.isEmpty {
            lo = min(lo, col[0])
            hi = max(hi, col[col.count - 1])
        }
        if lastTs > 0 {
            lo = min(lo, lastTs)
            hi = max(hi, lastTs)
        }
        return lo <= hi ? (lo, hi) : nil
    }

    /// The most recent login the log states — the end of the newest derived offline gap — or nil
    /// when the record states no logout at all, in which case the whole record IS one session.
    var sessionStart: Int64? { offlineEnd.last }

    /// The zone the log last named, or nil before the first zone line.
    var currentZone: (key: String, name: String)? {
        guard let name = zoneName.last else { return nil }
        let k = LootZone.placeKey(name)
        return k.isEmpty ? nil : (k, name)
    }
}

/// The three time columns a loot rate divides by. Named exactly as `RangeStats` names them.
struct LootSpans: Sendable {
    var durationMs: Int64 = 0
    var activeMs: Int64 = 0
    var idleMs: Int64 = 0
    var offlineMs: Int64 = 0
    /// The ONLINE wall clock: `durationMs - offlineMs`, floored. What "elapsed" divides by
    /// everywhere — medding, banking and travelling stay in, and only a logout the log CLOSED with a
    /// login line comes out.
    var wallMs: Int64 { max(0, durationMs - offlineMs) }
}

/// No exp / credited-kill / loot event for longer than this ⇒ idle. A CLASSIFIER, not a grace
/// period: a qualifying gap contributes its whole length.
let lootIdleGapMs: Int64 = 5 * 60_000

private struct LootSpan {
    var start: Int64
    var end: Int64
}

private func lowerBound(_ a: [Int64], _ v: Int64) -> Int {
    var lo = 0, hi = a.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if a[mid] < v { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

private func upperBound(_ a: [Int64], _ v: Int64) -> Int {
    var lo = 0, hi = a.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if a[mid] <= v { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

/// The zone visits covering `[t0, t1)`, clipped, in order — including the `unknown` remainder before
/// the first zone line and the still-open final interval, which together are what make
/// `Σ spans == durationMs` an identity rather than an approximation.
private func lootZoneSegments(_ p: LootProgression, _ t0: Int64, _ t1: Int64,
                              key: String?, exact: String?) -> [LootSpan] {
    var segs: [LootSpan] = []
    let n = p.zoneName.count
    let headEnd = min(n > 0 ? p.zoneStart[0] : t1, t1)
    if headEnd > t0, LootZone.admits(LootZone.unknown, key: key, exact: exact) {
        segs.append(LootSpan(start: t0, end: headEnd))
    }
    var i = max(0, upperBound(p.zoneStart, t0) - 1)
    while i < n, p.zoneStart[i] < t1 {
        let start = max(p.zoneStart[i], t0)
        let rawEnd = i < p.zoneEnd.count && p.zoneEnd[i] != 0 ? p.zoneEnd[i] : t1
        let end = min(rawEnd, t1)
        if end > start, LootZone.admits(p.zoneName[i], key: key, exact: exact) {
            segs.append(LootSpan(start: start, end: end))
        }
        i += 1
    }
    return segs
}

/// The idle spans inside `[t0, t1]`. The samples BRACKETING the range are pulled in unconditionally,
/// so a gap that straddles an edge is measured at its true length instead of the edge manufacturing
/// activity — which is also what makes a session split add up.
private func lootIdleSpans(_ p: LootProgression, _ t0: Int64, _ t1: Int64) -> [LootSpan] {
    let cols = [p.expTs, p.killTs, p.lootTs]
    var stream: [Int64] = []
    for col in cols {
        var i = lowerBound(col, t0)
        let end = lowerBound(col, t1)
        while i < end {
            stream.append(col[i])
            i += 1
        }
    }
    stream.sort()
    let prev = cols.compactMap { col -> Int64? in
        let i = lowerBound(col, t0)
        return i > 0 ? col[i - 1] : nil
    }
    let next = cols.compactMap { col -> Int64? in
        let i = lowerBound(col, t1)
        return i < col.count ? col[i] : nil
    }
    var walk: [Int64] = [prev.max() ?? t0]
    walk.append(contentsOf: stream)
    walk.append(next.min() ?? t1)
    var spans: [LootSpan] = []
    for i in 1..<max(1, walk.count) where walk[i] - walk[i - 1] > lootIdleGapMs {
        let start = max(walk[i - 1], t0)
        let end = min(walk[i], t1)
        if end > start { spans.append(LootSpan(start: start, end: end)) }
    }
    return spans
}

/// The offline intervals overlapping `[t0, t1)`, clipped. Ascending and disjoint by construction —
/// each row is one derived `offlineGap`, quoted exactly as the log's two lines stated it.
private func lootOfflineSpans(_ p: LootProgression, _ t0: Int64, _ t1: Int64) -> [LootSpan] {
    var out: [LootSpan] = []
    let n = p.offlineStart.count
    var i = max(0, upperBound(p.offlineStart, t0) - 1)
    while i < n, p.offlineStart[i] < t1 {
        let start = max(p.offlineStart[i], t0)
        let end = min(i < p.offlineEnd.count ? p.offlineEnd[i] : t1, t1)
        if end > start { out.append(LootSpan(start: start, end: end)) }
        i += 1
    }
    return out
}

/// `spans` minus `cuts` — what makes idle and offline disjoint rather than double-counted. An
/// offline interval always sits inside a silence, so without this the same hours would be both.
private func lootSubtract(_ spans: [LootSpan], _ cuts: [LootSpan]) -> [LootSpan] {
    if cuts.isEmpty { return spans }
    var out: [LootSpan] = []
    for s in spans {
        var start = s.start
        for c in cuts {
            if c.end <= start || c.start >= s.end { continue }
            if c.start > start { out.append(LootSpan(start: start, end: c.start)) }
            start = c.end
        }
        if start < s.end { out.append(LootSpan(start: start, end: s.end)) }
    }
    return out
}

private func lootIntersect(_ spans: [LootSpan], _ segs: [LootSpan]) -> [LootSpan] {
    var out: [LootSpan] = []
    for s in spans {
        for g in segs {
            let start = max(s.start, g.start)
            let end = min(s.end, g.end)
            if end > start { out.append(LootSpan(start: start, end: end)) }
        }
    }
    return out.sorted { $0.start < $1.start }
}

/// What a slice is worth in TIME: the wall clock it covers, the active hours inside it, and the
/// logouts carved out of both. Under a zone filter the duration is Σ of that zone's own visits,
/// which is the only denominator a per-zone rate may divide by.
func lootRangeSpans(_ p: LootProgression, range: LootRange, key: String?, exact: String?) -> LootSpans {
    let t0 = range.t0
    let t1 = max(range.t0, range.t1)
    if t1 <= t0 { return LootSpans() }
    let filtered = key != nil || exact != nil
    let segs = lootZoneSegments(p, t0, t1, key: key, exact: exact)
    let durationMs = filtered ? segs.reduce(Int64(0)) { $0 + ($1.end - $1.start) } : t1 - t0
    var offline = lootOfflineSpans(p, t0, t1)
    var idle = lootSubtract(lootIdleSpans(p, t0, t1), offline)
    if filtered {
        idle = lootIntersect(idle, segs)
        offline = lootIntersect(offline, segs)
    }
    let idleMs = idle.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
    let offlineMs = offline.reduce(Int64(0)) { $0 + ($1.end - $1.start) }
    return LootSpans(durationMs: durationMs,
                     activeMs: max(0, durationMs - idleMs - offlineMs),
                     idleMs: idleMs,
                     offlineMs: offlineMs)
}

// MARK: - The timeslice

/// Ranges are half-open `[t0, t1)` and the newest event is stamped at `bounds.hi` exactly, so a
/// slice ends one millisecond past the record or the last thing that happened falls out of totals
/// the reader can plainly see.
let lootTailMs: Int64 = 1

/// Every slice this tab can describe. The four duration rungs carry the chart timescale's own ids.
enum LootSliceId: String, CaseIterable, Sendable {
    case all, session, zone, zoneSession, d7, h24, h6, h1, custom

    /// The button's word for it. `Zone + Session` is the one long label: neither half survives being
    /// dropped, and a two-letter code for it would be a legend nobody has.
    var label: String {
        switch self {
        case .all: return "All"
        case .session: return "Session"
        case .zone: return "Zone"
        case .zoneSession: return "Zone + Session"
        case .d7: return "7d"
        case .h24: return "24h"
        case .h6: return "6h"
        case .h1: return "1h"
        case .custom: return "Custom"
        }
    }

    /// The rung's own length, or nil when the slice is not a fixed-length one. `all` is not a length.
    var durationMs: Int64? {
        switch self {
        case .d7: return 7 * 24 * 3_600_000
        case .h24: return 24 * 3_600_000
        case .h6: return 6 * 3_600_000
        case .h1: return 3_600_000
        default: return nil
        }
    }
}

struct LootRange: Sendable, Equatable {
    var t0: Int64
    var t1: Int64
}

/// A resolved slice: what to measure, where, and what to call it. Consumers take the WHOLE object —
/// handing three unpacked fields around is how a range from one slice ends up beside a zone filter
/// from another.
struct LootSlice: Sendable, Equatable {
    var id: LootSliceId
    var label: String
    /// How it is worded INSIDE a sentence ("no drops in ___").
    var caption: String
    var range: LootRange
    /// The MEMBERSHIP fold of the zone this slice is restricted to, or nil for every zone.
    var zoneKey: String?
    var zoneName: String?
    /// The exact-tier key. Nil under the default membership, which is what makes the default
    /// byte-identical to an unfiltered read.
    var zoneExactKey: String?
    /// The zone half, worded — `Befallen 2 (Adaptive), every tier`. Nil when there is no zone.
    var zoneCaption: String?

    /// Identity for a `.task(id:)`.
    var key: String { "\(id.rawValue)|\(range.t0)|\(range.t1)|\(zoneKey ?? "")|\(zoneExactKey ?? "")" }
}

enum LootTimeslice {
    /// Which presets THIS record can offer, in the order the control renders them. A preset is
    /// withheld when it could only restate another one (a session with no logout in the log) or when
    /// the log has not said enough to define it.
    static func available(_ p: LootProgression, _ bounds: (lo: Int64, hi: Int64)?) -> [LootSliceId] {
        var out: [LootSliceId] = [.all]
        let session = p.sessionStart
        let zone = p.currentZone
        let span = bounds.map { $0.hi - $0.lo } ?? 0
        let hasSession = session != nil && bounds != nil && session! > bounds!.lo && session! <= bounds!.hi
        if hasSession { out.append(.session) }
        if zone != nil { out.append(.zone) }
        if hasSession, zone != nil { out.append(.zoneSession) }
        for id in [LootSliceId.d7, .h24, .h6, .h1] {
            if let ms = id.durationMs, ms < span { out.append(id) }
        }
        out.append(.custom)
        return out
    }

    /// The picked id if this record can offer it, else `all`. A pick that outlives the record it was
    /// made against degrades to the honest slice rather than to one the log cannot define.
    static func resolveId(_ id: LootSliceId, _ p: LootProgression, _ bounds: (lo: Int64, hi: Int64)?) -> LootSliceId {
        available(p, bounds).contains(id) ? id : .all
    }

    private static func whole(_ bounds: (lo: Int64, hi: Int64)?) -> LootRange {
        guard let b = bounds else { return LootRange(t0: 0, t1: 0) }
        return LootRange(t0: b.lo, t1: b.hi + lootTailMs)
    }

    /// `range` clamped inside the record, never inverted. It is also what resolves an OPEN END: a
    /// segment spelled `[m, .max)` is "from m to the live edge" and grows as the log grows.
    private static func clamp(_ r: LootRange, _ bounds: (lo: Int64, hi: Int64)?) -> LootRange {
        let w = whole(bounds)
        let t0 = max(w.t0, min(r.t0, w.t1))
        return LootRange(t0: t0, t1: max(t0, min(r.t1, w.t1)))
    }

    /// One id plus one snapshot becomes one range and one zone filter. An id the record cannot
    /// define still resolves rather than throwing — a `session` with no logout is the whole record,
    /// which is what "this session" means for a log that never ended one.
    static func resolve(snap p: LootProgression,
                        bounds: (lo: Int64, hi: Int64)?,
                        id: LootSliceId,
                        custom: LootRange? = nil,
                        customCaption: String? = nil) -> LootSlice {
        let w = whole(bounds)
        var range = w
        switch id {
        case .session, .zoneSession:
            if let s = p.sessionStart { range = clamp(LootRange(t0: s, t1: w.t1), bounds) }
        case .custom:
            if let c = custom { range = clamp(c, bounds) }
        case .all, .zone:
            break
        default:
            if let ms = id.durationMs { range = clamp(LootRange(t0: w.t1 - lootTailMs - ms, t1: w.t1), bounds) }
        }
        let zone = (id == .zone || id == .zoneSession) ? p.currentZone : nil
        let zoneCaption = zone.map { "\($0.name), every tier" }
        return LootSlice(id: id,
                         label: id.label,
                         caption: caption(id, zone: zone, custom: customCaption),
                         range: range,
                         zoneKey: zone?.key,
                         zoneName: zone?.name,
                         // Nil under the default membership (every tier), on purpose: every consumer
                         // hands this straight down, so "the default reads what it always read" is a
                         // property of the data rather than a rule each caller has to remember.
                         zoneExactKey: nil,
                         zoneCaption: zoneCaption)
    }

    private static func caption(_ id: LootSliceId, zone: (key: String, name: String)?, custom: String?) -> String {
        switch id {
        case .session: return "this session"
        case .zone: return zone.map { "\($0.name), every tier" } ?? "this zone"
        case .zoneSession: return zone.map { "\($0.name) this session, every tier" } ?? "this zone this session"
        case .custom: return (custom?.isEmpty == false) ? custom! : "the custom range"
        case .all: return "the whole log"
        default: return "last \(id.label) of the log"
        }
    }

    /// The one membership test: does an event at `ts`, recorded in `zone`, belong to this slice?
    /// Half-open at the top exactly like the span query, so a row is counted by the table if and only
    /// if the same instant is inside the range the rates were measured over.
    static func admits(_ slice: LootSlice, ts: Int64, zone: String?) -> Bool {
        if ts < slice.range.t0 || ts >= slice.range.t1 { return false }
        if slice.zoneKey == nil, slice.zoneExactKey == nil { return true }
        return LootZone.admits(zone ?? LootZone.unknown, key: slice.zoneKey, exact: slice.zoneExactKey)
    }
}

// MARK: - The session split

/// One stretch of play between two marks. The `range` is the whole contract: resolve it as a custom
/// slice and every number on the tab is measured over it.
struct LootSessionSegment: Sendable, Identifiable, Equatable {
    /// 1-based, oldest first — the number the label prints.
    var n: Int
    var range: LootRange
    /// Exactly one segment is current: the newest, the one still accruing.
    var current: Bool
    var label: String
    var caption: String
    var id: Int { n }
}

enum LootSessions {
    /// The end that has not happened yet. `clamp` resolves it to the live edge on every read, so a
    /// segment opened with this end grows with the log instead of having to be retyped.
    static let openEnd = Int64.max
    /// The other open end: the first segment starts wherever the RECORD does.
    static let recordStart = Int64.min
    /// A browsing control is only browsable while you can still read it. The OLDEST mark is dropped,
    /// so the segment you are standing in is never the one that falls off.
    static let maxMarks = 24

    /// Add a mark, ascending, deduped and bounded. A mark at or before the newest one is DROPPED
    /// rather than sorted in: it would open a segment that can never hold anything.
    static func add(_ marks: [Int64], at: Int64) -> [Int64] {
        if let last = marks.last, at <= last { return marks }
        var next = marks
        next.append(at)
        return next.count > maxMarks ? Array(next.suffix(maxMarks)) : next
    }

    /// n marks make n+1 segments, tiling the record end to end. With no marks there is ONE segment —
    /// the whole record, still running — which is byte-identical to `All`.
    static func segments(_ marks: [Int64]) -> [LootSessionSegment] {
        let starts = [recordStart] + marks
        return starts.enumerated().map { i, t0 in
            let current = i == starts.count - 1
            return LootSessionSegment(n: i + 1,
                                      range: LootRange(t0: t0, t1: current ? openEnd : starts[i + 1]),
                                      current: current,
                                      label: current ? "Session \(i + 1) (now)" : "Session \(i + 1)",
                                      caption: "session \(i + 1)")
        }
    }
}

// MARK: - The inventory export

/// Which witness the app counts you by. A dump ADDS, it never subtracts: an `/outputfile inventory`
/// only covers what was OPEN when it was written, so the combination is fully additive.
enum LootCountSource: String, CaseIterable, Sendable {
    case both, log, inventory

    var label: String {
        switch self {
        case .both: return "Both (higher of the two)"
        case .log: return "Log only (ever looted)"
        case .inventory: return "Export only (as dumped)"
        }
    }
}

/// A parsed `/outputfile inventory` dump, cut to what the ledger asks of it: the flat held counts,
/// keyed by the RAW lowercased name, and where the file was.
struct LootInventoryDump: Sendable {
    /// Raw lowercased item name → copies the file vouches for.
    var counts: [String: Int] = [:]
    /// First-seen display spelling per raw key, so a dump-only row reads `Ivory Sky Diamond`.
    var names: [String: String] = [:]
    var path: String = ""
    /// When the file was written. 0 ⇒ nothing loaded.
    var generatedAt: Int64 = 0

    var isEmpty: Bool { counts.isEmpty }
}

enum LootInventory {
    private static let itemColumns = ["Name", "ID", "Count", "Slots"]
    private static let keyRingColumns = ["Name", "ID"]
    /// The one keyring category that holds real copies rather than claimed appearances. `Activated`
    /// stays out until a dump proves which it is.
    private static let heldKeyRing: Set<String> = ["Equipment"]

    /// Parse a dump's text into held counts.
    ///
    /// The rules that are easy to get wrong, all measured against a real dump:
    ///   * a SECTION HEADER is any row whose SECOND column is literally `Name`; the header's
    ///     remaining columns say how to READ that section, so a table spelling the item header's own
    ///     five columns is read as items whatever it is called (the Dragon's Hoard, which nobody has
    ///     a sample of, is exactly that table);
    ///   * `Empty`/blank names never count, a Count of 0 or nonsense counts as 1, and a held keyring
    ///     row counts ONE — that table has no Count column, and a copy is a row.
    static func parse(text: String, path: String = "", generatedAt: Int64 = 0) -> LootInventoryDump {
        var dump = LootInventoryDump(path: path, generatedAt: generatedAt)
        var shape = "items"
        for line in text.components(separatedBy: CharacterSet.newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let cols = line.components(separatedBy: "\t")
            if cols.count >= 2, cols[1].trimmingCharacters(in: .whitespaces) == "Name" {
                var declared = cols.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
                while let last = declared.last, last.isEmpty { declared.removeLast() }
                shape = declared == itemColumns ? "items" : (declared == keyRingColumns ? "keyRing" : "unknown")
                continue
            }
            switch shape {
            case "items":
                guard cols.count >= 4 else { continue }
                let name = cols[1].trimmingCharacters(in: .whitespaces)
                if name.isEmpty || name == "Empty" { continue }
                let n = Int(cols[3].trimmingCharacters(in: .whitespaces)) ?? 0
                add(&dump, name, n > 0 ? n : 1)
            case "keyRing":
                guard cols.count >= 3 else { continue }
                let category = cols[0].trimmingCharacters(in: .whitespaces)
                let name = cols[1].trimmingCharacters(in: .whitespaces)
                if !heldKeyRing.contains(category) || name.isEmpty || name == "Empty" { continue }
                add(&dump, name, 1)
            default:
                // A section whose header shape we do not recognize is retained by the deep model and
                // never interpreted. Here there is nothing to retain it in, so it is simply skipped.
                continue
            }
        }
        return dump
    }

    private static func add(_ dump: inout LootInventoryDump, _ name: String, _ n: Int) {
        let key = name.lowercased()
        dump.counts[key, default: 0] += n
        if dump.names[key] == nil { dump.names[key] = name }
    }

    /// The newest `<Name>_<server>-Inventory.txt` under the install root. The `outputFiles` module
    /// names it lower-cased and the file on disk is not, so the match is case-insensitive.
    static func find(root: URL, character: String, server: String) -> URL? {
        let wanted = "\(character)_\(server)-inventory.txt".lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return nil }
        guard let hit = names.first(where: { $0.lowercased() == wanted }) else { return nil }
        return root.appendingPathComponent(hit)
    }

    /// Read and parse the dump, or an empty one when there is nothing to read. Never throws: a
    /// missing export is a STATE the ledger words for itself.
    static func load(root: URL, character: String, server: String) -> LootInventoryDump {
        guard let url = find(root: root, character: character, server: server),
              let data = try? Data(contentsOf: url) else { return LootInventoryDump() }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let ms = mtime.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        return parse(text: text, path: url.path, generatedAt: ms)
    }
}

// MARK: - Turn-ins

/// One completed NPC trade, as the `turnins` module states it: the items handed over, and when.
struct LootTurnIn: Sendable {
    var npc: String
    var ts: Int64
    /// Counting keys, one entry per item line the trade carried.
    var itemKeys: [String]
    var itemNames: [String]

    static func parse(_ state: JSONValue) -> [LootTurnIn] {
        (state.array ?? []).map { v in
            let names = (v["items"].array ?? []).compactMap { $0.string }
            return LootTurnIn(npc: v["npc"].string ?? "",
                              ts: v["ts"].int64 ?? 0,
                              itemKeys: names.map(LootName.countKey),
                              itemNames: names)
        }
    }
}

// MARK: - The grouped row

/// One row of the grouped table: one item, everything the ledger knows about it.
struct LootGroupRow: Sendable, Identifiable, Equatable {
    /// Stable identity — the raw lowercase item name, or `inv:<countKey>` for an inventory-only row.
    var key: String
    var countKey: String
    var item: String
    /// Times looted, stack-aware. `-` on an inventory-only row: never looted is a fact about this
    /// log, not a measurement of the item.
    var count: Int
    var last: Int64
    var topSource: String?
    var zoneCount: Int
    /// Shown only when ALL of the group's rows share one, so a mixed item stays unlabeled rather
    /// than mislabeled.
    var disposition: String?
    /// Held per the export but never looted this epoch.
    var invOnly: Bool = false
    /// The reconciled estimate the "In inventory (est.)" chip prints.
    var estimate: Int = 0
    var id: String { key }
}

/// Which order the grouped table is in. Every comparator is TOTAL and bottoms out in the item name:
/// EQ log timestamps are second-resolution, so a corpse that yields three items writes three rows
/// with the SAME ts, and ties are the common case rather than the corner.
enum LootSort: String, CaseIterable, Sendable {
    case count, recent, name, zones

    var label: String {
        switch self {
        case .count: return "Times looted"
        case .recent: return "Last looted"
        case .name: return "Name"
        case .zones: return "Zones"
        }
    }

    func compare(_ a: LootGroupRow, _ b: LootGroupRow) -> Bool {
        switch self {
        case .count:
            if a.count != b.count { return a.count > b.count }
            if a.last != b.last { return a.last > b.last }
        case .recent:
            if a.last != b.last { return a.last > b.last }
            if a.count != b.count { return a.count > b.count }
        case .zones:
            if a.zoneCount != b.zoneCount { return a.zoneCount > b.zoneCount }
            if a.count != b.count { return a.count > b.count }
        case .name:
            break
        }
        return a.item.lowercased() < b.item.lowercased()
    }
}

// MARK: - The aggregate

/// Everything the Loot tab derives from one snapshot, folded once off the main thread.
///
/// It is a pure function of its input: same snapshot + same slice ⇒ same answer, no clock read.
struct LootAggregate: Sendable {
    /// Loot LINES inside the slice.
    var events: Int = 0
    /// Loot lines in the whole record — stated beside the sliced count, because "in totality vs this
    /// session" is the literal question the slice control was asked for.
    var total: Int = 0
    /// One row per item, unsorted and unfiltered (the view sorts and filters; both are cheap).
    var groups: [LootGroupRow] = []
    /// Held per the export but never looted inside this slice. The toolbar chip counts these.
    var invOnly: [LootGroupRow] = []
    /// Σ stack sizes inside the slice — the numerator of both rates. A `2 Bone Chips` line is two.
    var drops: Int = 0
    var spans = LootSpans()
    /// Drops per hour of ACTIVE time. Nil when there is no active time: unknown is not zero.
    var dropsPerHourActive: Double?
    /// Drops per hour of ONLINE WALL time. Nil when the window is entirely offline.
    var dropsPerHourWall: Double?
    /// The sliced events, kept for the drill-down (2.4k rows; filtering one item out of them is free).
    var sliced: [LootEvent] = []
    /// countKey → what the turn-in ledger took off it.
    var consumed: [String: Int] = [:]

    struct Input: Sendable {
        var events: [LootEvent]
        var prog: LootProgression
        var slice: LootSlice
        var inventory: LootInventoryDump
        var turnIns: [LootTurnIn]
        var countSource: LootCountSource
    }

    /// The fold. Every step is the Electron renderer's, in its order.
    static func build(_ input: Input) -> LootAggregate {
        var out = LootAggregate()
        out.total = input.events.count

        // 1. THE SLICE IS APPLIED ONCE, HERE, and everything below reads the result. Under `All` it
        //    keeps every row, so this costs one pass and changes nothing.
        let sliced = input.events.filter { LootTimeslice.admits(input.slice, ts: $0.ts, zone: $0.zone) }
        out.sliced = sliced
        out.events = sliced.count

        // 2. The witnesses, all-time: what the LOG says you hold, and what the DUMP vouched for.
        let log = heldFromLog(input.events)
        var inv: [String: Int] = [:]
        var invNames: [String: String] = [:]
        for (raw, n) in input.inventory.counts {
            let k = LootName.countKey(raw)
            inv[k, default: 0] += n
            if invNames[k] == nil { invNames[k] = input.inventory.names[raw] ?? raw }
        }
        let dumpAt = input.inventory.generatedAt
        // The dump is discounted by what the log says you destroyed after it was written, and — under
        // `both` — credited with what dropped after it: a witness about to be charged for a window
        // has to be allowed to earn in the same one.
        var destroyedSince: [String: Int] = [:]
        var lootedSince: [String: Int] = [:]
        if dumpAt > 0 {
            for e in input.events where e.ts > dumpAt {
                if e.isDestroyed {
                    destroyedSince[e.countKey, default: 0] += e.count
                } else if e.disposition != "sold" && e.disposition != "combined" {
                    lootedSince[e.countKey, default: 0] += e.count
                }
            }
        }
        // What the turn-ins actually took, from the ledger's own rows — the items the log saw handed
        // over, never an inference from a quest the app assumes you ran.
        var consumedAll: [String: Int] = [:]
        var consumedSinceDump: [String: Int] = [:]
        for t in input.turnIns {
            for k in t.itemKeys {
                consumedAll[k, default: 0] += 1
                if dumpAt > 0, t.ts > dumpAt { consumedSinceDump[k, default: 0] += 1 }
            }
        }
        out.consumed = consumedAll

        func estimate(_ key: String) -> Int {
            let l = max(0, (log[key] ?? 0) - (consumedAll[key] ?? 0))
            let credit = input.countSource == .both ? (lootedSince[key] ?? 0) : 0
            let dumpBase = max(0, (inv[key] ?? 0) + credit - (destroyedSince[key] ?? 0))
            let d = max(0, dumpBase - (consumedSinceDump[key] ?? 0))
            switch input.countSource {
            case .log: return l
            case .inventory: return d
            case .both: return max(l, d)
            }
        }

        // 3. ONE ROW PER ITEM, over the ACQUISITIONS only. A destroy names no mob and answers none of
        //    this table's columns, and adding its stack size to a times-looted count would make
        //    emptying a bag look like farming.
        struct Group {
            var item: String
            var countKey: String
            var count = 0
            var last: Int64 = 0
            var sources: [String: Int] = [:]
            var zones: Set<String> = []
            var dispositions: Set<String?> = []
        }
        var map: [String: Group] = [:]
        var order: [String] = []
        for e in sliced where e.isAcquisition {
            if map[e.itemKey] == nil {
                map[e.itemKey] = Group(item: e.item, countKey: e.countKey)
                order.append(e.itemKey)
            }
            map[e.itemKey]!.count += e.count
            map[e.itemKey]!.last = max(map[e.itemKey]!.last, e.ts)
            if let s = e.source { map[e.itemKey]!.sources[s, default: 0] += 1 }
            if let z = e.zone { map[e.itemKey]!.zones.insert(z) }
            map[e.itemKey]!.dispositions.insert(e.disposition)
        }
        out.groups = order.map { key in
            let g = map[key]!
            let top = g.sources.sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }.first?.key
            return LootGroupRow(key: key,
                                countKey: g.countKey,
                                item: g.item,
                                count: g.count,
                                last: g.last,
                                topSource: top,
                                zoneCount: g.zones.count,
                                disposition: g.dispositions.count == 1 ? g.dispositions.first! : nil,
                                estimate: estimate(g.countKey))
        }

        // 4. The tail of items the export knows about but that were never looted in this slice — bank
        //    stock, pre-epoch gear, anything acquired before this log started. THE WITNESS IS THE
        //    DUMP'S OWN COUNT, not the reconciled net: under the `log` source the net is 0 for every
        //    item the log never saw, which would empty this list for exactly the player it is for.
        let lootedKeys = Set(sliced.map(\.countKey))
        out.invOnly = inv.filter { $0.value > 0 && !lootedKeys.contains($0.key) }
            .sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
            .map { key, n in
                LootGroupRow(key: "inv:\(key)",
                             countKey: key,
                             item: invNames[key] ?? key,
                             count: 0,
                             last: 0,
                             topSource: nil,
                             zoneCount: 0,
                             disposition: nil,
                             invOnly: true,
                             estimate: n)
            }

        // 5. How fast the slice is paying, over BOTH denominators, so neither reading can pass for
        //    the other. A destroy is not a drop.
        var drops = 0
        for e in sliced where !e.isDestroyed { drops += e.count }
        out.drops = drops
        out.spans = lootRangeSpans(input.prog,
                                   range: input.slice.range,
                                   key: input.slice.zoneKey,
                                   exact: input.slice.zoneExactKey)
        out.dropsPerHourActive = perHour(drops, out.spans.activeMs)
        out.dropsPerHourWall = perHour(drops, out.spans.wallMs)
        return out
    }

    /// What the LOG says you hold: everything looted, less everything destroyed, floored per row.
    /// `sold` and `combined` never entered the bags and are skipped.
    static func heldFromLog(_ events: [LootEvent]) -> [String: Int] {
        var c: [String: Int] = [:]
        for e in events {
            if e.disposition == "sold" || e.disposition == "combined" { continue }
            let k = e.countKey
            c[k] = e.isDestroyed ? max(0, (c[k] ?? 0) - e.count) : (c[k] ?? 0) + e.count
        }
        return c
    }

    private static func perHour(_ amount: Int, _ windowMs: Int64) -> Double? {
        windowMs > 0 ? Double(amount) / (Double(windowMs) / 3_600_000) : nil
    }
}

// MARK: - Words

/// The tab's own spellings. Every honesty rule this feature has is a formatting decision — whether a
/// rate prints or an em-dash prints, which denominator a number stands on, whether a span is stated
/// at all — so they live together where they can be read in one screen.
enum LootFmt {
    /// The app's one spelling of unknown. A window with no active time did not measure zero drops an
    /// hour; it measured nothing.
    static let none = "-"

    /// `31h 47m`, `2d 16h`, `12m`, `44s`.
    static func duration(_ ms: Int64) -> String {
        let total = max(0, Int((Double(ms) / 1000).rounded()))
        let hrs = total / 3600
        if hrs >= 48 { return "\(hrs / 24)d \(hrs % 24)h" }
        let mins = (total % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return mins > 0 ? "\(mins)m" : "\(total % 60)s"
    }

    /// Two decimals under 10, one under 100, integer above. A farming rate lives in the 0–50 band and
    /// a damage formatter would render an honest 3.2 as a flat `3`.
    static func small(_ n: Double) -> String {
        guard n.isFinite else { return none }
        let v = abs(n)
        if v >= 100 { return String(format: "%.0f", n) }
        if v >= 10 { return String(format: "%.1f", n) }
        return String(format: "%.2f", n)
    }

    /// `81.2 drops/hr`. The word is `drops` whatever the item is: the number counts stack sizes, so
    /// "motes per hour" is this rate on a mote's row and needs no second spelling.
    static func dropRate(_ n: Double) -> String { "\(small(n)) drops/hr" }

    /// One half of the pair: the rate, then the span it was measured over, then which hour that is.
    /// A null rate keeps its WORD — so the reader still sees which denominator came up empty — and
    /// loses its span, because there was no span to state.
    static func rateHalf(_ rate: Double?, _ ms: Int64, _ word: String) -> String {
        guard let r = rate else { return "\(none) drops/hr \(word)" }
        return "\(dropRate(r)) over \(duration(ms)) \(word)"
    }

    /// The caption's rate line, or nil when there is nothing to state. A slice you looted nothing in
    /// already says so above; a line reading `0.00 drops/hr active · 0.00 drops/hr elapsed` would be
    /// three ways of saying one thing.
    static func rateLine(_ a: LootAggregate) -> String? {
        guard a.drops > 0 else { return nil }
        let drops = "\(Format.count(a.drops)) drop\(a.drops == 1 ? "" : "s")"
        return "\(drops) · \(rateHalf(a.dropsPerHourActive, a.spans.activeMs, "active")) · "
            + "\(rateHalf(a.dropsPerHourWall, a.spans.wallMs, "elapsed"))"
    }

    private static let edgeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    private static let exportFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "M/d/yyyy, h:mm:ss a"
        return f
    }()

    /// `Aug 17, 16:41` — an end of the slice's window.
    static func edge(_ ms: Int64) -> String {
        guard ms > 0, ms != Int64.max, ms != Int64.min else { return "" }
        return edgeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// `8/28/2026, 6:54:19 AM` — when the inventory export was written.
    static func exportStamp(_ ms: Int64) -> String {
        guard ms > 0 else { return "" }
        return exportFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// A drop rate over your own kills of one mob, as a percentage. Nil when the kill count is
    /// unknown: no kills recorded is not a rate of zero.
    static func dropPct(drops: Int, kills: Int) -> String {
        guard kills > 0 else { return none }
        return String(format: "%.1f%%", Double(drops) / Double(kills) * 100)
    }
}
