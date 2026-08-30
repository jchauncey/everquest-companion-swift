// The Overview's leveling card, ported from the Electron renderer
// (src/renderer/src/features/overview/overviewLevelingData.ts + overviewLevelingTiles.ts, on
// src/shared/progressionStats.ts, levelEta.ts, aaPace.ts, currentLevel.ts). Window A is the last
// hour of the LOG's clock; window B is the last zone interval. Pure over the `progression` and
// `leveling` module snapshots.
import Foundation
import EQCompanionCore

struct OverviewProgression {
    var lastTs: Int64 = 0
    var windowStart: Int64 = 0
    var levelTs: [Int64] = []
    var levelValue: [Int] = []
    var expTs: [Int64] = []
    var expPct: [Double] = []
    var expFlag: [Int] = []
    var killTs: [Int64] = []
    var killCredit: [Int] = []
    var lootTs: [Int64] = []
    var aaGainTs: [Int64] = []
    var aaGainAmount: [Int] = []
    var zoneName: [String] = []
    var zoneStart: [Int64] = []
    var zoneEnd: [Int64] = []
    var offlineStart: [Int64] = []
    var offlineEnd: [Int64] = []
    var recentKills: [JSONValue] = []

    init() {}

    init(_ v: JSONValue) {
        func ints(_ k: String) -> [Int64] { (v[k].array ?? []).map { $0.int64 ?? 0 } }
        func smallInts(_ k: String) -> [Int] { (v[k].array ?? []).map { $0.int ?? 0 } }
        lastTs = v["lastTs"].int64 ?? 0
        windowStart = v["windowStart"].int64 ?? 0
        levelTs = ints("levelTs"); levelValue = smallInts("levelValue")
        expTs = ints("expTs"); expPct = (v["expPct"].array ?? []).map { $0.double ?? 0 }; expFlag = smallInts("expFlag")
        killTs = ints("killTs"); killCredit = smallInts("killCredit")
        lootTs = ints("lootTs")
        aaGainTs = ints("aaGainTs"); aaGainAmount = smallInts("aaGainAmount")
        zoneName = (v["zoneName"].array ?? []).map { $0.string ?? "" }
        zoneStart = ints("zoneStart"); zoneEnd = ints("zoneEnd")
        offlineStart = ints("offlineStart"); offlineEnd = ints("offlineEnd")
        recentKills = v["recentKills"].array ?? []
    }

    var isEmpty: Bool { lastTs <= 0 }
}

private let idleGapMs: Int64 = 5 * 60_000
private let msPerHour = 3_600_000.0

struct OverviewRangeStats {
    var t0: Int64
    var t1: Int64
    var durationMs: Int64
    var activeMs: Int64
    var idleMs: Int64
    var offlineMs: Int64
    var kills: Int
    var killsPet: Int
    var expSamples: Int
    var expUnstated: Int
    var levelEquiv: Double
    var aaGainEvents: Int
    var aaGained: Int
    var clipped: Bool

    var wallMs: Int64 { max(0, durationMs - offlineMs) }
    var levelsUnknown: Bool { expSamples > 0 && expSamples == expUnstated }
    var levelsPerHourActive: Double? { activeMs > 0 && !levelsUnknown ? levelEquiv / (Double(activeMs) / msPerHour) : nil }
    var levelsPerHourWall: Double? { wallMs > 0 && !levelsUnknown ? levelEquiv / (Double(wallMs) / msPerHour) : nil }
    var killsPerHourActive: Double? { activeMs > 0 ? Double(kills) / (Double(activeMs) / msPerHour) : nil }
    /// AA rates are per hour of ELAPSED online time (the Electron default basis), not active time.
    var aaPerHourWall: Double? { wallMs > 0 ? Double(aaGainEvents) / (Double(wallMs) / msPerHour) : nil }
    var aaPointsPerHourWall: Double? { wallMs > 0 ? Double(aaGained) / (Double(wallMs) / msPerHour) : nil }
}

private struct OvSpan { var start: Int64; var end: Int64 }

private func lowerBound(_ a: [Int64], _ v: Int64) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let mid = (lo + hi) >> 1; if a[mid] < v { lo = mid + 1 } else { hi = mid } }
    return lo
}

private func upperBound(_ a: [Int64], _ v: Int64) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let mid = (lo + hi) >> 1; if a[mid] <= v { lo = mid + 1 } else { hi = mid } }
    return lo
}

private func offlineSpans(_ s: OverviewProgression, _ t0: Int64, _ t1: Int64) -> [OvSpan] {
    var out: [OvSpan] = []
    var i = max(0, upperBound(s.offlineStart, t0) - 1)
    while i < s.offlineStart.count, s.offlineStart[i] < t1 {
        let start = max(s.offlineStart[i], t0), end = min(s.offlineEnd[i], t1)
        if end > start { out.append(OvSpan(start: start, end: end)) }
        i += 1
    }
    return out
}

private func offlineMsIn(_ s: OverviewProgression, _ t0: Int64, _ t1: Int64) -> Int64 {
    offlineSpans(s, t0, t1).reduce(0) { $0 + ($1.end - $1.start) }
}

private func idleSpans(_ s: OverviewProgression, _ t0: Int64, _ t1: Int64) -> [OvSpan] {
    let cols = [s.expTs, s.killTs, s.lootTs]
    var stream: [Int64] = []
    for c in cols { let lo = lowerBound(c, t0), hi = lowerBound(c, t1); if hi > lo { stream.append(contentsOf: c[lo..<hi]) } }
    stream.sort()
    let prev = cols.compactMap { c -> Int64? in let i = lowerBound(c, t0); return i > 0 ? c[i - 1] : nil }
    let next = cols.compactMap { c -> Int64? in let i = lowerBound(c, t1); return i < c.count ? c[i] : nil }
    let walk = [prev.max() ?? t0] + stream + [next.min() ?? t1]
    var spans: [OvSpan] = []
    for i in 1..<walk.count where walk[i] - walk[i - 1] > idleGapMs {
        let start = max(walk[i - 1], t0), end = min(walk[i], t1)
        if end > start { spans.append(OvSpan(start: start, end: end)) }
    }
    return spans
}

private func subtract(_ spans: [OvSpan], _ cuts: [OvSpan]) -> [OvSpan] {
    if cuts.isEmpty { return spans }
    var out: [OvSpan] = []
    for s in spans {
        var start = s.start
        for c in cuts {
            if c.end <= start || c.start >= s.end { continue }
            if c.start > start { out.append(OvSpan(start: start, end: c.start)) }
            start = c.end
        }
        if start < s.end { out.append(OvSpan(start: start, end: s.end)) }
    }
    return out
}

func overviewRangeStats(_ s: OverviewProgression, t0: Int64, t1: Int64) -> OverviewRangeStats {
    let offline = offlineSpans(s, t0, t1)
    let idle = subtract(idleSpans(s, t0, t1), offline)
    let offlineMs = offline.reduce(0) { $0 + ($1.end - $1.start) }
    let idleMs = idle.reduce(0) { $0 + ($1.end - $1.start) }
    var kills = 0, killsPet = 0
    for i in lowerBound(s.killTs, t0)..<lowerBound(s.killTs, t1) {
        kills += 1
        if i < s.killCredit.count, s.killCredit[i] == 1 { killsPet += 1 }
    }
    var expSamples = 0, expUnstated = 0, levelEquiv = 0.0
    for i in lowerBound(s.expTs, t0)..<lowerBound(s.expTs, t1) {
        expSamples += 1
        let flag = i < s.expFlag.count ? s.expFlag[i] : 0
        if flag & 1 != 0 { expUnstated += 1 } else if i < s.expPct.count { levelEquiv += s.expPct[i] / 100 }
    }
    var aaEvents = 0, aaGained = 0
    for i in lowerBound(s.aaGainTs, t0)..<lowerBound(s.aaGainTs, t1) {
        aaEvents += 1
        aaGained += i < s.aaGainAmount.count ? s.aaGainAmount[i] : 0
    }
    let duration = max(0, t1 - t0)
    return OverviewRangeStats(t0: t0, t1: t1, durationMs: duration,
                      activeMs: max(0, duration - idleMs - offlineMs), idleMs: idleMs, offlineMs: offlineMs,
                      kills: kills, killsPet: killsPet, expSamples: expSamples, expUnstated: expUnstated,
                      levelEquiv: levelEquiv, aaGainEvents: aaEvents, aaGained: aaGained,
                      clipped: s.windowStart > 0 && t0 < s.windowStart)
}

// MARK: - Level ETA

enum OverviewLevelEta {
    case blocked(String)
    case estimate(ms: Double, toLevel: Int, progress: Double, offlineMs: Int64)
}

private let etaBlockedTitle: [String: String] = [
    "no-ding": "No level-up has been recorded yet, so your place in the bar is unknown.",
    "unstated": "Experience lines since your last level-up stated no percentage - unknown, not zero.",
    "clipped": "The retained record no longer reaches back to your last level-up.",
    "overfull": "The percentages since your last level-up already exceed a full level.",
    "offline": "Most of this stretch is time you were logged out.",
    "no-pace": "This stretch states no levels of progress.",
    "swapped": "Your /who reports a different level than your last level-up - the bar restarted where the log cannot see."
]

func overviewLevelEta(_ s: OverviewProgression, _ stats: OverviewRangeStats, stated: (level: Int, ts: Int64, source: String)?) -> OverviewLevelEta {
    guard let dingTs = s.levelTs.last, let dinged = s.levelValue.last else { return .blocked("no-ding") }
    if let st = stated, st.source == "who", st.ts > dingTs, st.level != dinged { return .blocked("swapped") }
    if s.windowStart > 0, dingTs < s.windowStart { return .blocked("clipped") }
    var equiv = 0.0, unstated = 0
    var i = s.expTs.count - 1
    while i >= 0, s.expTs[i] > dingTs {
        if (i < s.expFlag.count ? s.expFlag[i] : 0) & 1 != 0 { unstated += 1 } else if i < s.expPct.count { equiv += s.expPct[i] / 100 }
        i -= 1
    }
    if unstated > 0 { return .blocked("unstated") }
    if equiv >= 1 { return .blocked("overfull") }
    if stats.offlineMs > 0, stats.durationMs - stats.offlineMs < 15 * 60_000 { return .blocked("offline") }
    guard stats.levelsPerHourActive != nil, let perHour = stats.levelsPerHourWall, perHour > 0 else { return .blocked("no-pace") }
    return .estimate(ms: ((1 - equiv) / perHour) * msPerHour, toLevel: dinged + 1, progress: equiv, offlineMs: stats.offlineMs)
}

// MARK: - Wording (formatRate.ts, levelChartGeometry.ts)

enum OverviewWords {
    static let none = "-"

    static func small(_ n: Double) -> String {
        guard n.isFinite else { return "-" }
        let v = abs(n)
        if v >= 100 { return String(format: "%.0f", n) }
        if v >= 10 { return String(format: "%.1f", n) }
        return String(format: "%.2f", n)
    }

    static func levelRate(_ n: Double?) -> String { n.map { "\(small($0)) lvl/hr" } ?? none }
    static func killRate(_ n: Double?) -> String { n.map { "\(small($0)) kills/hr" } ?? none }

    /// `51m`, `1.5h`, `2.3d` — a span between two dings.
    static func delta(_ ms: Int64) -> String {
        if ms <= 0 { return "-" }
        let mins = Double(ms) / 60000
        if mins < 60 { return "\(Int(mins.rounded()))m" }
        let hrs = mins / 60
        if hrs < 48 { return String(format: "%.1fh", hrs) }
        return String(format: "%.1fd", hrs / 24)
    }

    /// `2h 10m`, `25m`, `40s`, `3d 4h`.
    static func duration(_ ms: Double) -> String {
        let total = max(0, Int((ms / 1000).rounded()))
        let hrs = total / 3600
        if hrs >= 48 { return "\(hrs / 24)d \(hrs % 24)h" }
        let mins = (total % 3600) / 60
        if hrs > 0 { return "\(hrs)h \(mins)m" }
        return mins > 0 ? "\(mins)m" : "\(total % 60)s"
    }
}

// MARK: - The card's state

struct OverviewLevelingTile: Identifiable {
    var id: String
    var value: String
    var unit: String
    var label: String
    var title: String
}

struct OverviewSparkBucket: Identifiable {
    var id: Int
    var value: Double
    var zone: String
    var t0: Int64
}

struct OverviewLevelingState {
    var empty = true
    var level: Int?
    var levelCue = ""
    var tiles: [OverviewLevelingTile] = []
    var killRate = "-"
    var activity = ""
    var offline: String?
    var aaLine: String?
    var zoneLine: String?
    var history: String?
    var verdict: String?
    var etaTitle = ""
    var kills = 0
    var atCap = false
    var spark: [OverviewSparkBucket] = []
    var sparkPeak = 0.0
}

private func zoneAt(_ s: OverviewProgression, _ t: Int64) -> String {
    var i = s.zoneStart.count - 1
    while i >= 0 {
        if s.zoneStart[i] > t { i -= 1; continue }
        let end = i < s.zoneEnd.count ? s.zoneEnd[i] : 0
        return end == 0 || t < end ? s.zoneName[i] : ""
    }
    return ""
}

func overviewLeveling(_ s: OverviewProgression, statedLevel: (level: Int, ts: Int64, source: String)?) -> OverviewLevelingState {
    var st = OverviewLevelingState()
    guard s.lastTs > 0 else { return st }
    st.empty = false
    let hourT0 = s.lastTs - 60 * 60_000
    let a = overviewRangeStats(s, t0: hourT0, t1: s.lastTs)

    // Level: the last statement (a /who outranks the ding only if later), with its age cue.
    var statement = statedLevel
    if let lt = s.levelTs.last, let lv = s.levelValue.last {
        if statement == nil || lt > statement!.ts { statement = (lv, lt, "ding") }
    }
    if let stmt = statement {
        st.level = stmt.level
        let age = max(0, s.lastTs - stmt.ts)
        let stale = age >= 6 * 3_600_000
        let ago = OverviewWords.duration(Double(age)) + " ago"
        st.levelCue = stmt.source == "who" ? (stale ? "/who \(ago)" : "/who") : (stale ? ago : "")
    }

    let eta = overviewLevelEta(s, a, stated: statedLevel)
    let rateText = OverviewWords.levelRate(a.levelsPerHourActive)
    var tiles: [OverviewLevelingTile] = []
    if let l = st.level {
        tiles.append(OverviewLevelingTile(id: "level", value: String(l), unit: "", label: st.levelCue.isEmpty ? "level" : "level · \(st.levelCue)", title: "The level the log last stated."))
    }
    let parts = rateText.split(separator: " ", maxSplits: 1).map(String.init)
    tiles.append(OverviewLevelingTile(id: "rate", value: parts.first ?? rateText, unit: parts.count > 1 ? parts[1] : "lvl/hr", label: "last hour",
                              title: "Levels of progress per hour of active time."))
    tiles.append(OverviewLevelingTile(id: "aa", value: String(a.aaGained), unit: "", label: "AA this hour", title: "Ability points from the gain lines in this hour."))
    switch eta {
    case .estimate(let ms, let to, let progress, let offlineMs):
        let absurd = ms > 24 * msPerHour
        tiles.append(OverviewLevelingTile(id: "eta", value: absurd ? ">1 day" : "~\(OverviewWords.duration(ms))", unit: "", label: "to level \(to)",
                                  title: "\(Int((progress * 100).rounded()))% of level \(to - 1) stated since your last level-up, projected at the last hour's pace." + (offlineMs > 0 ? " Time logged out is excluded." : "")))
        st.etaTitle = tiles.last!.title
    case .blocked(let why):
        st.etaTitle = etaBlockedTitle[why] ?? why
    }
    st.tiles = tiles

    st.killRate = OverviewWords.killRate(a.killsPerHourActive)
    let active = "\(OverviewWords.duration(Double(a.activeMs))) active"
    st.activity = a.idleMs > 0 ? "\(active) · \(OverviewWords.duration(Double(a.idleMs))) idle" : active
    st.offline = a.offlineMs > 0 ? "\(OverviewWords.duration(Double(a.offlineMs))) offline" : nil
    st.kills = a.kills
    st.atCap = a.levelsUnknown

    // AA line: completions and points per hour of active time, then the next-AA estimate.
    if let perHr = a.aaPerHourWall, let pts = a.aaPointsPerHourWall, a.aaGainEvents > 0 {
        var line = "\(OverviewWords.small(perHr)) AA/hr · \(OverviewWords.small(pts)) pts/hr"
        if a.aaGainEvents >= 2, let last = s.aaGainTs.last {
            let onlineWall = Double(a.durationMs - a.offlineMs)
            let mean = onlineWall / Double(a.aaGainEvents)
            let since = Double(max(0, s.lastTs - last - offlineMsIn(s, last, s.lastTs)))
            if since <= mean * 3 {
                line += since > mean ? " · next AA due (inferred)" : " · ~\(OverviewWords.duration(mean - since)) to next AA (inferred)"
            }
        }
        st.aaLine = line
    }

    // Window B: the last zone interval.
    if let i = s.zoneName.indices.last {
        let t0 = s.zoneStart[i]
        let end = (i < s.zoneEnd.count && s.zoneEnd[i] != 0) ? min(s.zoneEnd[i], s.lastTs) : s.lastTs
        if end > t0 {
            let b = overviewRangeStats(s, t0: t0, t1: end)
            st.zoneLine = "in \(s.zoneName[i]): \(OverviewWords.levelRate(b.levelsPerHourActive)) · \(OverviewWords.killRate(b.killsPerHourActive)) since \(Format.time(ms: t0).replacingOccurrences(of: ":00 ", with: " "))"
        }
    }

    // History: the last five level spans, online time.
    var spans: [(from: Int, to: Int, ms: Int64)] = []
    var i = s.levelTs.count - 1
    while i > 0, spans.count < 5 {
        let from = s.levelValue[i - 1], to = s.levelValue[i]
        if to <= from { break }
        let off = offlineMsIn(s, s.levelTs[i - 1], s.levelTs[i])
        spans.append((from, to, s.levelTs[i] - s.levelTs[i - 1] - off))
        i -= 1
    }
    spans.reverse()
    if !spans.isEmpty {
        st.history = "lvl " + spans.map { "\($0.from)→\($0.to) \(OverviewWords.delta($0.ms))" }.joined(separator: " · ")
        if spans.count >= 2, let wall = a.levelsPerHourWall, wall > 0 {
            let now = msPerHour / wall
            let sorted = spans.map { Double($0.ms) }.sorted()
            let med = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            if med > 0 {
                st.verdict = now < med * 0.8 ? "ahead of your recent pace" : (now > med / 0.8 ? "behind your recent pace" : "about your recent pace")
            }
        }
    }

    // Spark: the hour in twelve columns of stated level-bar progress, tinted by zone.
    let width = Double(max(1, s.lastTs - hourT0)) / 12
    var buckets = (0..<12).map { k -> OverviewSparkBucket in
        let t0 = hourT0 + Int64(Double(k) * width)
        return OverviewSparkBucket(id: k, value: 0, zone: zoneAt(s, t0 + Int64(width / 2)), t0: t0)
    }
    var j = s.expTs.count - 1
    while j >= 0, s.expTs[j] >= hourT0 {
        if s.expTs[j] <= s.lastTs, (j < s.expFlag.count ? s.expFlag[j] : 0) & 1 == 0 {
            let b = min(11, Int(Double(s.expTs[j] - hourT0) / width))
            buckets[b].value += (j < s.expPct.count ? s.expPct[j] : 0) / 100
        }
        j -= 1
    }
    st.spark = buckets
    st.sparkPeak = buckets.map(\.value).max() ?? 0
    return st
}

/// A stable colour per zone name for the spark and the zone strips (zoneBands.ts hashes the name).
func overviewZoneColorIndex(_ zone: String) -> Int {
    var h: UInt32 = 2166136261
    for b in zone.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return Int(h % 8)
}
