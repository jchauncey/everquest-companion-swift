// The window arithmetic behind every rate on the Leveling tab: which stretch of the log the
// numbers are about, which tiers of a camp that stretch admits, and which of the two honest
// denominators the rates are divided by.
//
// Ported from src/shared/{progressionStats,timeslice,zoneScope,rateBasis,zones}.ts and
// src/renderer/src/features/leveling/{chartWindow,windowScope}.ts. The vocabulary is the app's,
// not this tab's — the Loot ledger reads the same slice ids and the same wording.
import Foundation
import EQCompanionCore

// MARK: - Zone folds (shared/zones.ts, shared/zoneScope.ts)

enum LevelingZone {
    private static let soloGroup = try! NSRegularExpression(pattern: "\\s*-\\s*(Solo|Group)\\b.*$", options: [.caseInsensitive])
    private static let tierOrdinal = try! NSRegularExpression(pattern: "\\s+\\d+\\s*\\([^)]*\\)\\s*$")
    private static let tierParen = try! NSRegularExpression(pattern: "\\s+\\([^)]*\\)\\s*$")
    private static let separators = try! NSRegularExpression(pattern: "[\\s-]+")

    /// Canonical key for a zone name: instance noise stripped, leading article folded, separators
    /// normalized. `The Ruins of Old Guk 2 (Adaptive)` and `The Ruins of Old Guk` fold together.
    static func key(_ zone: String) -> String {
        var s = zone
        for re in [soloGroup, tierOrdinal, tierParen] {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        s = s.lowercased()
        s = separators.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("the ") { s = String(s.dropFirst(4)) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The TIER key: the raw spelling, case-folded. Two tiers of one camp differ here and agree
    /// under `key`, which is the whole of the membership question.
    static func idKey(_ zone: String) -> String {
        zone.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func admits(_ name: String, key wanted: String?, exact: String?) -> Bool {
        if let wanted, key(name) != wanted { return false }
        guard let exact else { return true }
        return idKey(name) == exact
    }
}

/// Which tiers of a camp the numbers count.
enum LvZoneScope: String, CaseIterable, Sendable {
    case allTiers, exactTier

    /// The app OPENS on `exactTier` — the numbers are about the tier you are standing in.
    static let opening: LvZoneScope = .exactTier

    var label: String { self == .allTiers ? "every tier" : "this tier" }
    var phrase: String { self == .allTiers ? "every tier" : "this tier only" }
    var title: String {
        self == .allTiers
            ? "The numbers count every visit to this camp, at any tier - the difficulty and instance spelled into the zone name are folded away."
            : "The numbers count only the tier you are standing in - visits to the same camp under any other spelling of the zone name are left out."
    }
}

// MARK: - Which hour the rates divide by (shared/rateBasis.ts)

enum LvRateBasis: String, CaseIterable, Sendable {
    case elapsed, active

    static let opening: LvRateBasis = .elapsed
    /// A stretch shorter than the idle threshold is too little to state as a rate per hour.
    static let minMs: Double = LvProgressionColumns.idleGapMs

    var title: String {
        self == .active
            ? "Active time is the window minus the gaps longer than five minutes with nothing happening in them, and minus the time the log says you were logged out."
            : "Elapsed time is the window's wall clock minus only the time the log says you were logged out - medding, looting and travel are all in it."
    }
    var buttonTitle: String { "Divides every rate by \(rawValue) time. \(title)" }

    func ms(durationMs: Double, activeMs: Double, offlineMs: Double) -> Double {
        self == .active ? activeMs : max(0, durationMs - offlineMs)
    }
}

/// The denominator in force, and whether there is enough of it to divide by.
struct LvBasisRead: Sendable {
    var basis: LvRateBasis
    var ms: Double
    var measurable: Bool

    init(_ basis: LvRateBasis, durationMs: Double, activeMs: Double, offlineMs: Double) {
        self.basis = basis
        self.ms = basis.ms(durationMs: durationMs, activeMs: activeMs, offlineMs: offlineMs)
        self.measurable = self.ms >= LvRateBasis.minMs
    }

    var word: String { basis.rawValue }
    /// `over 42m active` — the span the rate beside it was measured over.
    var spanText: String { "over \(LevelingFormat.duration(ms)) \(word)" }

    func pick(active: Double?, elapsed: Double?) -> Double? {
        guard measurable else { return nil }
        return basis == .active ? active : elapsed
    }
}

// MARK: - The capped analytics series (`progression`)

/// The columnar snapshot, decoded once per push. Every column is ascending by construction, which
/// is what lets every fold below be a binary search rather than a scan.
struct LvProgressionColumns: Sendable {
    static let idleGapMs: Double = 5 * 60_000

    var levelTs: [Int64] = []
    var levelValue: [Int] = []
    var expTs: [Int64] = []
    var expPct: [Double] = []
    var expFlag: [Int] = []
    var aaGainTs: [Int64] = []
    var aaGainAmount: [Int] = []
    var killTs: [Int64] = []
    var lootTs: [Int64] = []
    var witnessTs: [Int64] = []
    var zoneName: [String] = []
    var zoneStart: [Int64] = []
    var zoneEnd: [Int64] = []
    var offlineStart: [Int64] = []
    var offlineEnd: [Int64] = []
    var lastTs: Int64 = 0
    var windowStart: Int64 = 0

    static let empty = LvProgressionColumns()

    init() {}

    init(_ v: JSONValue) {
        func ints(_ k: String) -> [Int64] { (v[k].array ?? []).map { $0.int64 ?? 0 } }
        func nums(_ k: String) -> [Double] { (v[k].array ?? []).map { $0.double ?? 0 } }
        levelTs = ints("levelTs")
        levelValue = (v["levelValue"].array ?? []).map { $0.int ?? 0 }
        expTs = ints("expTs")
        expPct = nums("expPct")
        expFlag = (v["expFlag"].array ?? []).map { $0.int ?? 0 }
        aaGainTs = ints("aaGainTs")
        aaGainAmount = (v["aaGainAmount"].array ?? []).map { $0.int ?? 0 }
        killTs = ints("killTs")
        lootTs = ints("lootTs")
        witnessTs = ints("witnessTs")
        zoneName = (v["zoneName"].array ?? []).map { $0.string ?? "" }
        zoneStart = ints("zoneStart")
        zoneEnd = ints("zoneEnd")
        offlineStart = ints("offlineStart")
        offlineEnd = ints("offlineEnd")
        lastTs = v["lastTs"].int64 ?? 0
        windowStart = v["windowStart"].int64 ?? 0
    }

    var isEmpty: Bool { lastTs == 0 && zoneName.isEmpty && expTs.isEmpty }

    /// Where the record starts and ends. It is where a window's numbers stop: the drawn window
    /// runs past the newest event by design, and counting that as time would invent silence.
    func bounds(extraTs: [Int64]) -> (lo: Int64, hi: Int64)? {
        var lo = Int64.max, hi = Int64.min
        func widen(_ ts: Int64) {
            guard ts > 0 else { return }
            if ts < lo { lo = ts }
            if ts > hi { hi = ts }
        }
        for ts in extraTs { widen(ts) }
        for col in [expTs, killTs, witnessTs, lootTs, zoneStart, levelTs, aaGainTs] where !col.isEmpty {
            widen(col[0]); widen(col[col.count - 1])
        }
        widen(lastTs)
        return lo <= hi ? (lo, hi) : nil
    }

    var sessionStart: Int64? { offlineEnd.last }

    var currentZone: (key: String, name: String)? {
        guard let name = zoneName.last else { return nil }
        let k = LevelingZone.key(name)
        return k.isEmpty ? nil : (k, name)
    }
}

// MARK: - Binary searches

private func lowerBound(_ arr: [Int64], _ v: Int64) -> Int {
    var lo = 0, hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid] < v { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

private func upperBound(_ arr: [Int64], _ v: Int64) -> Int {
    var lo = 0, hi = arr.count
    while lo < hi {
        let mid = (lo + hi) / 2
        if arr[mid] <= v { lo = mid + 1 } else { hi = mid }
    }
    return lo
}

// MARK: - rangeStats (shared/progressionStats.ts)

struct LvZoneSeg: Sendable {
    var key: String
    var name: String
    var start: Int64
    var end: Int64
}

struct LvTimeSpan: Sendable {
    var start: Int64
    var end: Int64
    var ms: Double { Double(max(0, end - start)) }
}

/// What one window of the record says. The AA half is what the pace panel divides; the spans are
/// what it divides BY, and both denominators travel with it so a rate can always state its hour.
struct LvRangeStats: Sendable {
    var t0: Int64 = 0
    var t1: Int64 = 0
    var durationMs: Double = 0
    var activeMs: Double = 0
    var idleMs: Double = 0
    var idleGaps = 0
    var offlineMs: Double = 0
    var offlineGaps = 0
    var aaGained = 0
    var aaGainEvents = 0
    var aaPerHourActive: Double?
    var aaPointsPerHourActive: Double?
    var aaPerHourWall: Double?
    var aaPointsPerHourWall: Double?
    /// the ELAPSED denominator: the window minus only the logged-out time.
    var wallMs: Double { max(0, durationMs - offlineMs) }

    static let empty = LvRangeStats()
}

enum LvProgressionStats {
    private static let msPerHour: Double = 3_600_000

    private static func perHour(_ amount: Double, _ windowMs: Double) -> Double? {
        windowMs > 0 ? amount / (windowMs / msPerHour) : nil
    }

    /// Every visit to a zone the filter admits, clipped to the range. The head segment before the
    /// first zone line is `unknown`, which the zone filters reject and an unfiltered range keeps.
    static func zoneSegments(_ snap: LvProgressionColumns, _ t0: Int64, _ t1: Int64,
                             key: String?, exact: String?) -> [LvZoneSeg] {
        var segs: [LvZoneSeg] = []
        let n = snap.zoneName.count
        let headEnd = min(n > 0 ? snap.zoneStart[0] : t1, t1)
        if headEnd > t0, LevelingZone.admits("unknown", key: key, exact: exact) {
            segs.append(LvZoneSeg(key: "unknown", name: "unknown", start: t0, end: headEnd))
        }
        var i = max(0, upperBound(snap.zoneStart, t0) - 1)
        while i < n, snap.zoneStart[i] < t1 {
            let start = max(snap.zoneStart[i], t0)
            let end = min(snap.zoneEnd[i] == 0 ? t1 : snap.zoneEnd[i], t1)
            let name = snap.zoneName[i]
            if end > start, LevelingZone.admits(name, key: key, exact: exact) {
                segs.append(LvZoneSeg(key: LevelingZone.idKey(name), name: name, start: start, end: end))
            }
            i += 1
        }
        return segs
    }

    private static func segAt(_ segs: [LvZoneSeg], _ ts: Int64) -> Int {
        var lo = 0, hi = segs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segs[mid].end <= ts { lo = mid + 1 } else { hi = mid }
        }
        return lo < segs.count && segs[lo].start <= ts ? lo : -1
    }

    private static func intersect(_ spans: [LvTimeSpan], _ segs: [LvZoneSeg]) -> [LvTimeSpan] {
        var out: [LvTimeSpan] = []
        for s in spans {
            for g in segs {
                let start = max(s.start, g.start), end = min(s.end, g.end)
                if end > start { out.append(LvTimeSpan(start: start, end: end)) }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Gaps longer than five minutes with no exp, kill or loot line in them. The walk is anchored
    /// on the last event BEFORE the range and the first one after it, so a range that opens inside
    /// a long silence sees the silence.
    private static func idleSpans(_ snap: LvProgressionColumns, _ t0: Int64, _ t1: Int64) -> [LvTimeSpan] {
        let cols = [snap.expTs, snap.killTs, snap.lootTs]
        var stream: [Int64] = []
        for col in cols {
            let lo = lowerBound(col, t0), hi = lowerBound(col, t1)
            if hi > lo { stream.append(contentsOf: col[lo..<hi]) }
        }
        stream.sort()
        var prev: [Int64] = [], next: [Int64] = []
        for col in cols {
            let i = lowerBound(col, t0)
            if i > 0 { prev.append(col[i - 1]) }
            let j = lowerBound(col, t1)
            if j < col.count { next.append(col[j]) }
        }
        var walk: [Int64] = [prev.max() ?? t0]
        walk.append(contentsOf: stream)
        walk.append(next.min() ?? t1)
        var spans: [LvTimeSpan] = []
        for i in 1..<walk.count {
            if Double(walk[i] - walk[i - 1]) <= LvProgressionColumns.idleGapMs { continue }
            let start = max(walk[i - 1], t0), end = min(walk[i], t1)
            if end > start { spans.append(LvTimeSpan(start: start, end: end)) }
        }
        return spans
    }

    private static func offlineSpans(_ snap: LvProgressionColumns, _ t0: Int64, _ t1: Int64) -> [LvTimeSpan] {
        var out: [LvTimeSpan] = []
        let n = snap.offlineStart.count
        var i = max(0, upperBound(snap.offlineStart, t0) - 1)
        while i < n, snap.offlineStart[i] < t1 {
            let start = max(snap.offlineStart[i], t0)
            let end = min(i < snap.offlineEnd.count ? snap.offlineEnd[i] : t1, t1)
            if end > start { out.append(LvTimeSpan(start: start, end: end)) }
            i += 1
        }
        return out
    }

    /// Time the log SAYS you were logged out, between two instants.
    static func offlineMsIn(_ snap: LvProgressionColumns, _ t0: Int64, _ t1: Int64) -> Double {
        offlineSpans(snap, t0, t1).reduce(0) { $0 + $1.ms }
    }

    private static func subtract(_ spans: [LvTimeSpan], _ cuts: [LvTimeSpan]) -> [LvTimeSpan] {
        if cuts.isEmpty { return spans }
        var out: [LvTimeSpan] = []
        for s in spans {
            var start = s.start
            for c in cuts {
                if c.end <= start || c.start >= s.end { continue }
                if c.start > start { out.append(LvTimeSpan(start: start, end: c.start)) }
                start = c.end
            }
            if start < s.end { out.append(LvTimeSpan(start: start, end: s.end)) }
        }
        return out
    }

    /// ONE query per window. A zone filter narrows the DENOMINATOR too: `durationMs` becomes the
    /// time actually spent in the admitted zones, never the wall clock across the whole range.
    static func stats(snap: LvProgressionColumns, t0 rawT0: Int64, t1 rawT1: Int64,
                      zoneKey: String?, zoneExactKey: String?) -> LvRangeStats {
        let t0 = rawT0, t1 = max(rawT0, rawT1)
        let filtered = zoneKey != nil || zoneExactKey != nil
        let segs = zoneSegments(snap, t0, t1, key: zoneKey, exact: zoneExactKey)
        let durationMs = filtered ? segs.reduce(0.0) { $0 + Double($1.end - $1.start) } : Double(t1 - t0)
        var idle: [LvTimeSpan] = [], offline: [LvTimeSpan] = []
        if t1 > t0 {
            offline = offlineSpans(snap, t0, t1)
            idle = subtract(idleSpans(snap, t0, t1), offline)
            if filtered {
                idle = intersect(idle, segs)
                offline = intersect(offline, segs)
            }
        }
        var out = LvRangeStats()
        out.t0 = t0
        out.t1 = t1
        out.durationMs = durationMs
        out.idleMs = idle.reduce(0) { $0 + $1.ms }
        out.idleGaps = idle.count
        out.offlineMs = offline.reduce(0) { $0 + $1.ms }
        out.offlineGaps = offline.count
        out.activeMs = max(0, durationMs - out.idleMs - out.offlineMs)
        var i = lowerBound(snap.aaGainTs, t0)
        let hi = lowerBound(snap.aaGainTs, t1)
        while i < hi {
            if segAt(segs, snap.aaGainTs[i]) >= 0 {
                out.aaGained += i < snap.aaGainAmount.count ? snap.aaGainAmount[i] : 0
                out.aaGainEvents += 1
            }
            i += 1
        }
        let wall = out.wallMs
        out.aaPerHourActive = perHour(Double(out.aaGainEvents), out.activeMs)
        out.aaPointsPerHourActive = perHour(Double(out.aaGained), out.activeMs)
        out.aaPerHourWall = perHour(Double(out.aaGainEvents), wall)
        out.aaPointsPerHourWall = perHour(Double(out.aaGained), wall)
        return out
    }
}

// MARK: - The timeslice (shared/timeslice.ts)

enum LvSliceId: String, CaseIterable, Sendable {
    case all, session, zone, zoneSession, d7, h24, h6, h1, custom

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

    var durationMs: Double? {
        switch self {
        case .d7: return 7 * 86_400_000
        case .h24: return 86_400_000
        case .h6: return 6 * 3_600_000
        case .h1: return 3_600_000
        default: return nil
        }
    }
}

/// The resolved slice: which stretch, which zone, which tiers of it, and the words for each.
struct LvTimeslice: Sendable {
    static let tailMs: Int64 = 1

    var id: LvSliceId = .all
    var t0: Int64 = 0
    var t1: Int64 = 0
    var zoneKey: String?
    var zoneName: String?
    var zoneScope: LvZoneScope = .allTiers
    var zoneExactKey: String?
    var zoneCaption: String?
    var caption = "the whole log"

    var label: String { id.label }

    /// `Aug 28, 05:12 → Aug 28, 11:42 · Innothule Swamp, this tier only`. The membership clause is
    /// printed even under the default, because the default admits visits this line does not name.
    var windowCaption: String {
        let ends = "\(LevelingFormat.edge(t0)) → \(LevelingFormat.edge(t1))"
        return zoneCaption.map { "\(ends) · \($0)" } ?? ends
    }

    static func available(_ snap: LvProgressionColumns, bounds: (lo: Int64, hi: Int64)?) -> [LvSliceId] {
        var out: [LvSliceId] = [.all]
        let session = snap.sessionStart
        let zone = snap.currentZone
        let spanMs = bounds.map { Double($0.hi - $0.lo) } ?? 0
        let hasSession = session != nil && bounds != nil && session! > bounds!.lo && session! <= bounds!.hi
        if hasSession { out.append(.session) }
        if zone != nil { out.append(.zone) }
        if hasSession, zone != nil { out.append(.zoneSession) }
        for id in [LvSliceId.d7, .h24, .h6, .h1] {
            if let ms = id.durationMs, ms < spanMs { out.append(id) }
        }
        out.append(.custom)
        return out
    }

    static func resolve(id: LvSliceId, snap: LvProgressionColumns, bounds: (lo: Int64, hi: Int64)?,
                        scope: LvZoneScope, custom: (t0: Int64, t1: Int64)?) -> LvTimeslice {
        let whole: (t0: Int64, t1: Int64) = bounds.map { ($0.lo, $0.hi + tailMs) } ?? (0, 0)
        func clamp(_ r: (t0: Int64, t1: Int64)) -> (t0: Int64, t1: Int64) {
            let t0 = max(whole.t0, min(r.t0, whole.t1))
            return (t0, max(t0, min(r.t1, whole.t1)))
        }
        var range = whole
        switch id {
        case .session, .zoneSession:
            if let s = snap.sessionStart { range = clamp((s, whole.t1)) }
        case .custom:
            if let c = custom { range = clamp(c) }
        default:
            if let ms = id.durationMs { range = clamp((whole.t1 - tailMs - Int64(ms), whole.t1)) }
        }
        var out = LvTimeslice(id: id, t0: range.t0, t1: range.t1)
        let zone = (id == .zone || id == .zoneSession) ? snap.currentZone : nil
        if let zone {
            out.zoneKey = zone.key
            out.zoneName = zone.name
            out.zoneScope = scope
            out.zoneExactKey = scope == .exactTier ? LevelingZone.idKey(zone.name) : nil
            out.zoneCaption = "\(zone.name), \(scope.phrase)"
        }
        switch id {
        case .session: out.caption = "this session"
        case .zone: out.caption = out.zoneCaption ?? "this zone"
        case .zoneSession:
            out.caption = zone.map { "\($0.name) this session, \(scope.phrase)" } ?? "this zone this session"
        case .custom: out.caption = "the custom range"
        case .all: out.caption = "the whole log"
        default: out.caption = "last \(id.label) of the log"
        }
        return out
    }
}

// MARK: - The drawn window (features/leveling/chartWindow.ts)

/// The chart's time base. A fixed-length rung SLIDES — anchored on the newest event and snapped
/// outward to the bucket grid so it advances a whole bucket at a time; every other slice is
/// anchored on the DATA at both ends and carries its own exact range into the numbers.
struct LvChartWindow: Sendable {
    static let trailingFrac = 0.04
    static let targetBuckets = 360.0
    private static let ladder: [Double] = [1000, 5000, 15_000, 30_000, 60_000, 120_000, 300_000,
                                           900_000, 1_800_000, 3_600_000, 7_200_000, 21_600_000,
                                           43_200_000, 86_400_000]

    var t0: Int64
    var t1: Int64
    var bucketMs: Double

    static func bucketMs(forSpan spanMs: Double) -> Double {
        let span = max(1, spanMs)
        for step in ladder where span / step <= targetBuckets { return step }
        return (span / targetBuckets / 86_400_000).rounded(.up) * 86_400_000
    }

    /// The whole record plus a trailing gutter, so the newest point is not drawn on the frame.
    static func over(_ t0: Int64, _ t1: Int64) -> LvChartWindow {
        let span = Double(max(1, t1 - t0))
        let end = t1 + Int64(span * trailingFrac)
        return LvChartWindow(t0: t0, t1: end, bucketMs: bucketMs(forSpan: Double(end - t0)))
    }

    static func fixed(lo: Int64, hi: Int64, ms: Double) -> LvChartWindow {
        let bucket = bucketMs(forSpan: ms * (1 + trailingFrac))
        let t0 = (Double(hi) - ms) / bucket
        let t1 = (Double(hi) + ms * trailingFrac) / bucket
        return LvChartWindow(t0: Int64(t0.rounded(.down) * bucket), t1: Int64(t1.rounded(.up) * bucket), bucketMs: bucket)
    }

    static func forSlice(_ slice: LvTimeslice, bounds: (lo: Int64, hi: Int64)) -> LvChartWindow {
        if let ms = slice.id.durationMs { return fixed(lo: bounds.lo, hi: bounds.hi, ms: ms) }
        // The slice's range ends one ms past the newest event so a half-open query holds it; the
        // DRAWN domain wants the event's own instant.
        return over(slice.t0, max(slice.t0, slice.t1 - LvTimeslice.tailMs))
    }
}

// MARK: - The scope (features/leveling/windowScope.ts)

/// The one scope every number on the tab reads: the slice's range, clamped to the record, plus the
/// stats measured over it and the words that describe it.
struct LevelingScope: Sendable {
    var label: String
    var t0: Int64
    var t1: Int64
    var zoneCaption: String?
    var stats: LvRangeStats

    static func make(snap: LvProgressionColumns, slice: LvTimeslice, window: LvChartWindow,
                     bounds: (lo: Int64, hi: Int64)) -> LevelingScope {
        let range: (t0: Int64, t1: Int64)
        if slice.id.durationMs != nil {
            // The rung's drawn window runs past the newest event; the numbers stop at the record.
            let t0 = max(window.t0, bounds.lo)
            range = (t0, max(t0, min(window.t1, bounds.hi + LvTimeslice.tailMs)))
        } else {
            range = (slice.t0, slice.t1)
        }
        return LevelingScope(
            label: slice.caption,
            t0: range.t0,
            t1: range.t1,
            zoneCaption: slice.zoneCaption,
            stats: LvProgressionStats.stats(snap: snap, t0: range.t0, t1: range.t1,
                                          zoneKey: slice.zoneKey, zoneExactKey: slice.zoneExactKey))
    }
}
