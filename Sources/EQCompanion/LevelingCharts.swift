// The two plots and everything they must AGREE on: one time domain, one set of zone bands, one
// fractional level curve. Ported from src/renderer/src/features/leveling/{zoneBands,levelCurve,
// levelCharts}.tsx — same colours, same refusals, same wording.
import SwiftUI
import Charts
import EQCompanionCore

// MARK: - Zone bands (zoneBands.ts)

struct LvZoneBand: Sendable, Identifiable {
    var key: String
    var name: String
    var start: Int64
    var end: Int64
    var id: String { "\(key)|\(start)" }
    var color: Color { LevelingZoneColor.of(key) }
}

struct LvZoneLegendRow: Sendable, Identifiable {
    var key: String
    var name: String
    var ms: Double
    var id: String { key }
    var color: Color { LevelingZoneColor.of(key) }
}

enum LevelingZoneColor {
    /// The Electron palette, verbatim — a row's swatch is the same hue as its chart band.
    static let palette: [Color] = [
        Color(hex: 0x5b8ff9), Color(hex: 0x61ddaa), Color(hex: 0xf6bd16), Color(hex: 0x7262fd),
        Color(hex: 0x78d3f8), Color(hex: 0x9661bc), Color(hex: 0xf6903d), Color(hex: 0x3ba7a5),
        Color(hex: 0xf08bb4), Color(hex: 0x5ad8a6), Color(hex: 0xd96a6a), Color(hex: 0x8ca0b3)
    ]

    /// FNV-1a over the zone key, so a zone keeps its hue across sessions and surfaces.
    private static func hash32(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 16777619
        }
        return h
    }

    static func of(_ zone: String) -> Color {
        let key = LevelingZone.key(zone).isEmpty ? zone.trimmingCharacters(in: .whitespaces).lowercased() : LevelingZone.key(zone)
        return palette[Int(hash32(key) % UInt32(palette.count))]
    }
}

enum LvZoneBands {
    /// Consecutive visits to the SAME camp merge into one band — the strip answers "where was I",
    /// not "how many zone lines did the log print".
    static func merge(_ snap: LvProgressionColumns, _ t0: Int64, _ t1: Int64) -> [LvZoneBand] {
        var out: [LvZoneBand] = []
        for i in 0..<snap.zoneName.count {
            let open = i < snap.zoneEnd.count ? snap.zoneEnd[i] == 0 : true
            let rawEnd = open ? max(snap.lastTs, snap.zoneStart[i]) : snap.zoneEnd[i]
            let start = max(snap.zoneStart[i], t0)
            let end = min(rawEnd, t1)
            if end <= start { continue }
            let name = snap.zoneName[i]
            let key = LevelingZone.key(name).isEmpty ? name.trimmingCharacters(in: .whitespaces).lowercased() : LevelingZone.key(name)
            if let last = out.last, last.key == key {
                out[out.count - 1].end = max(last.end, end)
                continue
            }
            out.append(LvZoneBand(key: key, name: name, start: start, end: end))
        }
        return out
    }

    /// The legend, longest first. Capped, with the remainder counted rather than hidden.
    static func legend(_ bands: [LvZoneBand], limit: Int = 8) -> (rows: [LvZoneLegendRow], more: Int) {
        var by: [String: LvZoneLegendRow] = [:]
        var order: [String] = []
        for b in bands {
            if by[b.key] == nil {
                by[b.key] = LvZoneLegendRow(key: b.key, name: b.name, ms: 0)
                order.append(b.key)
            }
            by[b.key]?.ms += Double(b.end - b.start)
        }
        let all = order.compactMap { by[$0] }.sorted {
            $0.ms != $1.ms ? $0.ms > $1.ms : $0.name < $1.name
        }
        return (Array(all.prefix(limit)), max(0, all.count - limit))
    }
}

// MARK: - The fractional level curve (levelCurve.ts)

/// Why the curve stops. Each is a hole in the evidence, and each is drawn as a band rather than a
/// dashed line: a dashed stroke between the last stated value and the next one still puts a bar
/// position under every pixel of itself.
enum LvCurveRefusal: String, Sendable {
    case unstated, overfull, clipped, swapped

    var note: String {
        switch self {
        case .unstated: return "experience lines here stated no percentage - unknown, not zero"
        case .overfull: return "the percentages since the last level-up already exceed a full level"
        case .clipped: return "the retained record no longer reaches back to the level-up this bar started at"
        case .swapped: return "the bar restarted at a class swap the log never announced"
        }
    }
}

struct LvCurvePoint: Sendable {
    var ts: Int64
    var y: Double
}

struct LvCurveRun: Sendable, Identifiable {
    var points: [LvCurvePoint]
    var endTs: Int64
    var id: Int64 { points.first?.ts ?? endTs }
}

struct LvCurveGap: Sendable, Identifiable {
    var kind: LvCurveRefusal
    var t0: Int64
    var t1: Int64
    var level: Int
    var id: Int64 { t0 }
}

struct LvCurveDing: Sendable, Identifiable {
    var ts: Int64
    var level: Int
    var afterSwap: Bool
    var id: Int64 { ts }
}

struct LvLevelCurve: Sendable {
    var runs: [LvCurveRun] = []
    var gaps: [LvCurveGap] = []
    var dings: [LvCurveDing] = []
    var loY: Double = 0
    var hiY: Double = 0

    static let empty = LvLevelCurve()
    var isEmpty: Bool { runs.isEmpty && gaps.isEmpty && dings.isEmpty }

    /// One ascending pass over the capped exp column, then a collapse to at most two vertices per
    /// pixel column. The line between dings is the game's OWN stated percentages, never a
    /// smoothing of them.
    static func build(snap: LvProgressionColumns, segments: [LvLevelSegment], t0: Int64, t1: Int64,
                      columns: Int = 720) -> LvLevelCurve {
        var dings: [LvCurveDing] = []
        for seg in segments {
            for (i, p) in seg.points.enumerated() {
                dings.append(LvCurveDing(ts: p.ts, level: p.level, afterSwap: i == 0 && seg.afterSwap))
            }
        }
        guard !dings.isEmpty else { return .empty }
        var runs: [LvCurveRun] = []
        var gaps: [LvCurveGap] = []
        for k in 0..<dings.count {
            fold(snap: snap, ding: dings[k], next: k + 1 < dings.count ? dings[k + 1] : nil,
                 domainEnd: t1, runs: &runs, gaps: &gaps)
        }
        var out = LvLevelCurve()
        out.runs = runs.compactMap { clip($0, t0) }.map { downsample($0, t0: t0, t1: t1, columns: columns) }
        out.gaps = gaps.map { LvCurveGap(kind: $0.kind, t0: max($0.t0, t0), t1: min($0.t1, t1), level: $0.level) }
            .filter { $0.t1 > $0.t0 }
        out.dings = dings.filter { $0.ts >= t0 && $0.ts <= t1 }
        var lo = Double.infinity, hi = -Double.infinity
        func widen(_ v: Double) { lo = min(lo, v); hi = max(hi, v) }
        for r in out.runs { for p in r.points { widen(p.y) } }
        for d in out.dings { widen(Double(d.level)) }
        for g in out.gaps { widen(Double(g.level)) }
        if lo.isFinite { out.loY = lo; out.hiY = hi }
        return out
    }

    private static func firstAfter(_ arr: [Int64], _ v: Int64) -> Int {
        var lo = 0, hi = arr.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if arr[mid] <= v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func fold(snap: LvProgressionColumns, ding: LvCurveDing, next: LvCurveDing?,
                             domainEnd: Int64, runs: inout [LvCurveRun], gaps: inout [LvCurveGap]) {
        let barEnd = next?.ts ?? domainEnd
        if let next, next.afterSwap || next.level <= ding.level {
            gaps.append(LvCurveGap(kind: .swapped, t0: ding.ts, t1: next.ts, level: ding.level))
            return
        }
        if snap.windowStart > 0, ding.ts < snap.windowStart {
            gaps.append(LvCurveGap(kind: .clipped, t0: ding.ts, t1: barEnd, level: ding.level))
            return
        }
        var points = [LvCurvePoint(ts: ding.ts, y: Double(ding.level))]
        var equiv = 0.0
        var refusal: (kind: LvCurveRefusal, ts: Int64)?
        var i = firstAfter(snap.expTs, ding.ts)
        while i < snap.expTs.count, snap.expTs[i] < barEnd {
            let ts = snap.expTs[i]
            if i < snap.expFlag.count, snap.expFlag[i] & 1 != 0 { refusal = (.unstated, ts); break }
            equiv += (i < snap.expPct.count ? snap.expPct[i] : 0) / 100
            if equiv >= 1 { refusal = (.overfull, ts); break }
            points.append(LvCurvePoint(ts: ts, y: Double(ding.level) + equiv))
            i += 1
        }
        if let refusal {
            runs.append(LvCurveRun(points: points, endTs: refusal.ts))
            gaps.append(LvCurveGap(kind: refusal.kind, t0: refusal.ts, t1: barEnd, level: ding.level))
            return
        }
        if let next {
            points.append(LvCurvePoint(ts: next.ts, y: Double(next.level)))
            runs.append(LvCurveRun(points: points, endTs: next.ts))
            return
        }
        runs.append(LvCurveRun(points: points, endTs: max(domainEnd, points[points.count - 1].ts)))
    }

    private static func clip(_ run: LvCurveRun, _ t0: Int64) -> LvCurveRun? {
        if run.endTs < t0 { return nil }
        var anchor = -1
        for (i, p) in run.points.enumerated() {
            if p.ts <= t0 { anchor = i } else { break }
        }
        if anchor <= 0 { return run }
        return LvCurveRun(points: Array(run.points[anchor...]), endTs: run.endTs)
    }

    /// At most two vertices per pixel column: the first and the last of each column's run, which
    /// preserves the extremes a plain stride would drop.
    private static func downsample(_ run: LvCurveRun, t0: Int64, t1: Int64, columns: Int) -> LvCurveRun {
        guard run.points.count > 2 else { return run }
        let span = Double(max(1, t1 - t0))
        func col(_ p: LvCurvePoint) -> Int { Int(Double(p.ts - t0) / span * Double(columns)) }
        var out: [LvCurvePoint] = []
        var runStart = 0
        var i = 1
        while i <= run.points.count {
            if i < run.points.count, col(run.points[i]) == col(run.points[runStart]) { i += 1; continue }
            out.append(run.points[runStart])
            if i - 1 > runStart { out.append(run.points[i - 1]) }
            runStart = i
            i += 1
        }
        return LvCurveRun(points: out, endTs: run.endTs)
    }
}

// MARK: - Drawing

private func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

/// The hue this feature uses for "the log cannot see here" — one meaning, one colour.
let lvSwapColor = Color(hex: 0x8fa3b8)

/// The zone strip that runs along the top of both plots. Identical on both, so the legend under
/// the lower chart is drawn once.
struct LvZoneBandStrip: View {
    var bands: [LvZoneBand]
    var t0: Int64
    var t1: Int64

    var body: some View {
        GeometryReader { geo in
            let span = Double(max(1, t1 - t0))
            ZStack(alignment: .leading) {
                ForEach(bands) { b in
                    let x = Double(b.start - t0) / span * geo.size.width
                    let w = Double(b.end - b.start) / span * geo.size.width
                    if w >= 0.5 {
                        b.color.opacity(0.75)
                            .frame(width: max(1, w))
                            .offset(x: x)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(b.name)
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

struct LvZoneLegendStrip: View {
    var rows: [LvZoneLegendRow]
    var more: Int

    var body: some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                ForEach(rows) { r in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(r.color).frame(width: 8, height: 8)
                        Text(r.name).foregroundStyle(Theme.textDim)
                        Text(LevelingFormat.delta(r.ms)).foregroundStyle(Theme.textFaint)
                    }
                }
                if more > 0 { Text("+\(more) more").foregroundStyle(Theme.textFaint) }
            }
            .font(.caption2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Cumulative AA over the window. The floor is the total BEFORE the window opened, so a zoomed
/// view shows the gains it contains instead of a flat line pinned to the top of a big cumulative.
struct LvAaAreaChart: View {
    var points: [LvAaPoint]
    var bands: [LvZoneBand]
    var t0: Int64
    var t1: Int64

    private struct Vertex: Identifiable {
        var id: Int
        var date: Date
        var y: Double
    }

    var body: some View {
        let base = max(0, Double((points.first?.y ?? 0) - (points.first?.gain ?? points.first?.y ?? 0)))
        let top = Double(points.last?.y ?? 0)
        var verts = points.enumerated().map { Vertex(id: $0.offset, date: date($0.element.ts), y: Double($0.element.y)) }
        // Hold the curve flat to the end of the shared domain — cumulative AA is a step function
        // between gain lines, so the plateau is what the series actually says.
        if let last = verts.last, last.date < date(t1) { verts.append(Vertex(id: verts.count, date: date(t1), y: last.y)) }
        let pad = max(0.5, (top - base) * 0.12)
        return VStack(alignment: .leading, spacing: 3) {
            LvZoneBandStrip(bands: bands, t0: t0, t1: t1)
            Chart(verts) { v in
                AreaMark(x: .value("When", v.date), yStart: .value("Base", base), yEnd: .value("AA", v.y))
                    .foregroundStyle(Theme.blue.opacity(0.18))
                LineMark(x: .value("When", v.date), y: .value("AA", v.y))
                    .foregroundStyle(Theme.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartXScale(domain: date(t0)...date(t1))
            .chartYScale(domain: base...(top + pad))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 130)
            .overlay(alignment: .topLeading) {
                Text(LevelingFormat.grouped(Int(top))).font(.caption2).foregroundStyle(Theme.blue)
            }
            .overlay(alignment: .bottomLeading) {
                if base > 0 {
                    Text(LevelingFormat.grouped(Int(base))).font(.caption2).foregroundStyle(Theme.blue)
                }
            }
        }
    }
}

/// Level over time: every ding, plus the fractional bar the game's own percentages state between
/// them, plus a band wherever the log stopped stating them.
struct LvLevelStepChart: View {
    var curve: LvLevelCurve
    var bands: [LvZoneBand]
    var t0: Int64
    var t1: Int64

    private struct Vertex: Identifiable {
        var id: String
        var run: Int64
        var date: Date
        var y: Double
    }

    var body: some View {
        let lo = curve.loY.rounded(.down)
        let hi = max(lo + 1, curve.hiY.rounded(.up))
        var verts: [Vertex] = []
        for run in curve.runs {
            for p in run.points {
                verts.append(Vertex(id: "\(run.id)|\(p.ts)|\(p.y)", run: run.id, date: date(p.ts), y: p.y))
            }
            // The trailing plateau: the last stated value held to the end of the run.
            if let last = run.points.last, run.endTs > last.ts {
                verts.append(Vertex(id: "\(run.id)|end", run: run.id, date: date(run.endTs), y: last.y))
            }
        }
        return VStack(alignment: .leading, spacing: 3) {
            LvZoneBandStrip(bands: bands, t0: t0, t1: t1)
            Chart {
                ForEach(curve.gaps) { g in
                    RectangleMark(xStart: .value("From", date(g.t0)), xEnd: .value("To", date(g.t1)),
                                  yStart: .value("Lo", lo), yEnd: .value("Hi", hi))
                        .foregroundStyle(lvSwapColor.opacity(0.10))
                }
                ForEach(verts) { v in
                    LineMark(x: .value("When", v.date), y: .value("Level", v.y), series: .value("Run", v.run))
                        .foregroundStyle(Theme.gold)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                ForEach(curve.dings) { d in
                    PointMark(x: .value("When", date(d.ts)), y: .value("Level", Double(d.level)))
                        .foregroundStyle(d.afterSwap ? lvSwapColor : Theme.gold)
                        .symbolSize(18)
                }
            }
            .chartXScale(domain: date(t0)...date(t1))
            .chartYScale(domain: lo...hi)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 150)
            .overlay(alignment: .topLeading) {
                Text("\(Int(hi))").font(.caption2).foregroundStyle(Theme.gold)
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(Int(lo))").font(.caption2).foregroundStyle(Theme.gold)
            }
        }
    }
}
