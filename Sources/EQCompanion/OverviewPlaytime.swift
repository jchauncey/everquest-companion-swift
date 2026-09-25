// The Overview's leveling card over ALL of your play, like every other card on the sheet: where
// you started and where you are, how long you have played and how much of it was active, the
// levels, ability points and kills that time bought, and a bar per day you played.
//
// NOT A PORT: the Electron card (OverviewLeveling.swift) is a last-hour pace readout, which is
// blank whenever you are not grinding. Everything here is read from the same `progression` columns
// through the same `overviewRangeStats`, so its active/idle split and its rates agree with the
// Leveling tab's.
import Foundation
import EQCompanionCore

struct OverviewPlaytime: Equatable {
    struct Day: Equatable, Identifiable {
        /// Local midnight, epoch ms.
        var start: Int64
        var activeMs: Int64
        /// Levels of progress the log stated that day (dings plus the percent between them).
        var levels: Double
        var aa: Int
        var kills: Int
        var id: Int64 { start }
    }

    var empty = true
    /// The first and last levels the log states, and the level now (a later /who outranks a ding).
    var firstLevel: Int?
    var level: Int?
    /// Level-ups: a ding to a higher level than the one before it (a class swap's reset is not one).
    var levelUps = 0
    var swaps = 0
    /// From your first logged activity to the log's last line.
    var sinceTs: Int64 = 0
    var playedMs: Int64 = 0
    var activeMs: Int64 = 0
    var aa = 0
    var kills = 0
    var days: [Day] = []
    /// The last few level-ups and how long each took, online time only.
    var history: String?

    var activePerLevelMs: Double? { levelUps > 0 && activeMs > 0 ? Double(activeMs) / Double(levelUps) : nil }
    var aaPerActiveHour: Double? { activeMs > 0 ? Double(aa) / (Double(activeMs) / 3_600_000) : nil }
    var killsPerActiveHour: Double? { activeMs > 0 ? Double(kills) / (Double(activeMs) / 3_600_000) : nil }
}

/// The whole log's summary. `calendar` decides where a day starts (the viewer's own by default).
func overviewPlaytime(_ s: OverviewProgression, statedLevel: (level: Int, ts: Int64, source: String)?,
                      calendar: Calendar = .current) -> OverviewPlaytime {
    var out = OverviewPlaytime()
    guard s.lastTs > 0 else { return out }
    out.empty = false

    // The first activity of any kind the columns hold.
    let firsts = [s.expTs.first, s.killTs.first, s.lootTs.first, s.levelTs.first, s.aaGainTs.first, s.zoneStart.first]
        .compactMap { $0 }.filter { $0 > 0 }
    let t0 = firsts.min() ?? s.lastTs
    out.sinceTs = t0
    // Ranges are half-open, [t0, t1): end one past the last line so its own events count.
    let end = s.lastTs + 1
    let all = overviewRangeStats(s, t0: t0, t1: end)
    out.playedMs = all.wallMs
    out.activeMs = all.activeMs
    out.aa = all.aaGained
    out.kills = all.kills

    // Levels: the series as the log stated it, then the latest statement of any kind.
    let n = min(s.levelTs.count, s.levelValue.count)
    if n > 0 { out.firstLevel = s.levelValue[0] }
    for i in 1..<max(1, n) {
        if s.levelValue[i] > s.levelValue[i - 1] { out.levelUps += 1 } else { out.swaps += 1 }
    }
    var level = n > 0 ? (s.levelValue[n - 1], s.levelTs[n - 1]) : nil as (Int, Int64)?
    if let st = statedLevel, level == nil || st.ts > level!.1 { level = (st.level, st.ts) }
    out.level = level?.0

    // One bar per calendar day with any activity.
    var dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(t0) / 1000))
    while true {
        let a = Int64(dayStart.timeIntervalSince1970 * 1000)
        guard a <= s.lastTs, let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
        let b = Int64(next.timeIntervalSince1970 * 1000)
        let d = overviewRangeStats(s, t0: max(a, t0), t1: min(b, end))
        if d.activeMs > 0 || d.kills > 0 || d.aaGained > 0 {
            out.days.append(.init(start: a, activeMs: d.activeMs, levels: d.levelEquiv, aa: d.aaGained, kills: d.kills))
        }
        dayStart = next
    }

    // The last five level-ups, online time only. A class swap's reset is stepped over, not an end:
    // this is the whole log, not the current class's run.
    var spans: [String] = []
    var i = n - 1
    while i > 0, spans.count < 5 {
        let from = s.levelValue[i - 1], to = s.levelValue[i]
        if to <= from { i -= 1; continue }
        let offline = overviewRangeStats(s, t0: s.levelTs[i - 1], t1: s.levelTs[i]).offlineMs
        spans.append("\(from)→\(to) \(OverviewWords.delta(s.levelTs[i] - s.levelTs[i - 1] - offline))")
        i -= 1
    }
    if !spans.isEmpty { out.history = "lvl " + spans.reversed().joined(separator: " · ") }
    return out
}
