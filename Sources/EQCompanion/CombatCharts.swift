// The Combat tab's two charts, drawn with Swift Charts over the derivations in CombatData.swift.
//
//  - `DpsOverTimeCard`  — the dashboard's WHEN cell: the rolling 5s rate for you+pet(+group) as a
//    filled area with the pet, group and incoming bands drawn over it (DpsOverTime.tsx).
//  - `CombatTimelinePane` — the Timeline sub-tab: the fight's lanes, and cumulative damage per
//    side over the encounter clock with the stance/invocation spans shaded behind it
//    (CombatTimeline.tsx / TimelineChart.tsx, at the density a native pane can carry).
//
// Both read the encounter's event ring, so both degrade to a quiet note when the selection has
// none, and both wear the `~` note when that ring is inexact.

import SwiftUI
import Charts
import EQCompanionCore

// MARK: - DPS over time

private struct DpsPoint: Identifiable {
    var id: Int
    var t: Double
    var value: Double
    var series: String
}

struct DpsOverTimeCard: View {
    var timeline: JSONValue
    var live: Bool
    /// Why the selection has no per-event ring — the wording of the quiet note.
    var noRing: String

    var body: some View {
        let tl = timeline
        let series: DpsSeries? = tl.isNull ? nil : buildDpsSeries(tl, live: live)
        let window = series.map { dpsWindow($0, live: live) }
        return CombatCard(title: "DPS over time", trailing: {
            if let s = series, let w = window, s.hasAny {
                Text("\(s.estimated ? "~" : "")\(CFmt.rate(w.peakVis)) peak")
                    .font(.caption).foregroundStyle(CombatColor.out).monospacedDigit()
            }
        }) {
            if tl.isNull {
                CombatNote(noRing)
            } else if let s = series, let w = window, s.hasAny {
                VStack(alignment: .leading, spacing: 4) {
                    chart(s, w)
                    HStack(spacing: 12) {
                        legend(s)
                        Spacer(minLength: 4)
                        Text("\(Int((s.smoothMs / 1000).rounded()))s rolling\(w.scrolling ? " · last 2:00" : "")")
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                    if let note = approxNote(tl) {
                        Text(note).font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                    }
                }
            } else {
                CombatNote("No damage in this selection yet.")
            }
        }
    }

    /// The four bands. `out` owns the area fill; pet/group/inc are components drawn over it, and
    /// each is present only when the fight actually had it (the same question, once per line).
    private func points(_ s: DpsSeries, _ w: DpsWindow) -> [DpsPoint] {
        var out: [DpsPoint] = []
        out.reserveCapacity(w.count * 3)
        var id = 0
        for i in w.i0..<s.n {
            // The sample for bucket `i` is anchored at the bucket's CENTRE — the instant a lookup
            // at that x resolves back to.
            let t = (Double(i) + 0.5) * s.bucketMs / 1000
            out.append(DpsPoint(id: id, t: t, value: s.out(i), series: outLabel(s))); id += 1
            if s.hasPet { out.append(DpsPoint(id: id, t: t, value: s.pet[i], series: "pet")); id += 1 }
            if s.hasGroup { out.append(DpsPoint(id: id, t: t, value: s.group[i], series: "group")); id += 1 }
            if s.hasInc { out.append(DpsPoint(id: id, t: t, value: s.inc[i], series: "incoming")); id += 1 }
        }
        return out
    }

    /// The headline curve's label names exactly what it sums.
    private func outLabel(_ s: DpsSeries) -> String { s.hasGroup ? "you + pet + group" : "you + pet" }

    @ViewBuilder
    private func chart(_ s: DpsSeries, _ w: DpsWindow) -> some View {
        let pts = points(s, w)
        let label = outLabel(s)
        Chart {
            ForEach(pts.filter { $0.series == label }) { p in
                AreaMark(x: .value("t", p.t), y: .value("dps", p.value))
                    .foregroundStyle(CombatColor.out.opacity(0.16))
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                LineMark(x: .value("t", p.t), y: .value("dps", p.value), series: .value("series", p.series))
                    .foregroundStyle(by: .value("series", p.series))
                    .lineStyle(StrokeStyle(lineWidth: p.series == label ? 1.8 : 1.2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartForegroundStyleScale([
            label: CombatColor.out,
            "pet": CombatColor.pet,
            "group": CombatColor.member,
            "incoming": CombatColor.inc
        ])
        .chartLegend(.hidden)
        .chartXScale(domain: (w.t0 / 1000)...(w.t1 / 1000))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let sec = v.as(Double.self) { Text(CFmt.dur(sec)).font(.system(size: 9)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let n = v.as(Double.self) { Text(CFmt.num(n)).font(.system(size: 9)) }
                }
            }
        }
        .frame(minHeight: 90)
    }

    @ViewBuilder
    private func legend(_ s: DpsSeries) -> some View {
        HStack(spacing: 10) {
            legendEntry(outLabel(s), CombatColor.out)
            if s.hasPet { legendEntry("pet", CombatColor.pet) }
            if s.hasGroup { legendEntry("group", CombatColor.member) }
            if s.hasInc { legendEntry("incoming", CombatColor.inc) }
        }
    }

    private func legendEntry(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
    }
}

// MARK: - Timeline

private struct CumulativePoint: Identifiable {
    var id: Int
    var t: Double
    var total: Double
    var side: String
}

private struct SpanBand: Identifiable {
    var id: String
    var name: String
    var group: String
    var start: Double
    var end: Double
}

/// The Timeline sub-tab: the fight's own lanes, and the cumulative damage each side dealt over
/// the encounter clock with the stance/invocation spans shaded behind it.
struct CombatTimelinePane: View {
    var timeline: JSONValue

    var body: some View {
        let tl = timeline
        if tl.isNull {
            CombatCard(title: "Timeline") {
                CombatNote("No timeline for this selection - pick a recent fight.")
            }
        } else {
            VStack(spacing: 12) {
                CombatCard(title: "\(tl["name"].string ?? "") · timeline", caps: false, trailing: {
                    Text(counts(tl)).font(.caption).foregroundStyle(Theme.textDim).monospacedDigit()
                }) {
                    chart(tl)
                }
                CombatCard(title: "Lanes", trailing: {
                    Text("\((tl["lanes"].array ?? []).count) lanes").font(.caption).foregroundStyle(Theme.textDim)
                }) {
                    lanes(tl)
                }
            }
        }
    }

    private func counts(_ tl: JSONValue) -> String {
        let shown = (tl["events"].array ?? []).count
        let total = tl["totalCount"].int ?? shown
        // The count after "of" is the fight's TRUE instant count, so a ring that overflowed its
        // drop-oldest cap reports what it LOST rather than its own size.
        let events = isApproximate(tl) ? "\(shown) of \(total) events" : "\(total) events"
        return "\(CFmt.durMs(tl["durationMs"].double ?? 0)) · \(events)"
    }

    /// Cumulative damage per side over the fight's own clock — one running total for your side
    /// (you + pets + group) and one for the enemies, so the two curves cross where the fight did.
    private func cumulative(_ tl: JSONValue) -> [CumulativePoint] {
        var out: [CumulativePoint] = []
        var yours = 0.0, theirs = 0.0
        var id = 0
        out.append(CumulativePoint(id: id, t: 0, total: 0, side: "yours")); id += 1
        out.append(CumulativePoint(id: id, t: 0, total: 0, side: "enemies")); id += 1
        for e in tl["events"].array ?? [] {
            if e["outcome"].string != nil { continue }
            let amount = e["amount"].double ?? 0
            let t = (e["t"].double ?? 0) / 1000
            if e["kind"].string == "enemy" {
                theirs += amount
                out.append(CumulativePoint(id: id, t: t, total: theirs, side: "enemies"))
            } else {
                yours += amount
                out.append(CumulativePoint(id: id, t: t, total: yours, side: "yours"))
            }
            id += 1
        }
        return out
    }

    private func spans(_ tl: JSONValue) -> [SpanBand] {
        (tl["stanceSpans"].array ?? []).enumerated().map { i, s in
            SpanBand(id: "\(i)",
                     name: s["name"].string ?? "",
                     group: s["group"].string ?? "",
                     start: (s["start"].double ?? 0) / 1000,
                     end: (s["end"].double ?? 0) / 1000)
        }
    }

    @ViewBuilder
    private func chart(_ tl: JSONValue) -> some View {
        let pts = cumulative(tl)
        let bands = spans(tl)
        let dur = max(1, (tl["durationMs"].double ?? 0) / 1000)
        Chart {
            ForEach(bands) { b in
                RectangleMark(xStart: .value("start", b.start), xEnd: .value("end", b.end))
                    .foregroundStyle(CombatColor.marker(b.group).opacity(0.07))
            }
            ForEach(pts) { p in
                LineMark(x: .value("t", p.t), y: .value("damage", p.total), series: .value("side", p.side))
                    .foregroundStyle(by: .value("side", p.side))
                    .interpolationMethod(.stepEnd)
            }
        }
        .chartForegroundStyleScale(["yours": CombatColor.out, "enemies": CombatColor.inc])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartXScale(domain: 0...dur)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let sec = v.as(Double.self) { Text(CFmt.dur(sec)).font(.system(size: 9)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel {
                    if let n = v.as(Double.self) { Text(CFmt.num(n)).font(.system(size: 9)) }
                }
            }
        }
        .frame(minHeight: 200)
        .overlay(alignment: .topLeading) {
            // The pinned spans, named where they start — the stance/invocation the fight ran under.
            HStack(spacing: 8) {
                ForEach(bands) { b in
                    HStack(spacing: 3) {
                        Circle().fill(CombatColor.marker(b.group)).frame(width: 6, height: 6)
                        Text(b.name).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    }
                }
            }
            .padding(.leading, 34)
        }
    }

    @ViewBuilder
    private func lanes(_ tl: JSONValue) -> some View {
        let rows = (tl["lanes"].array ?? [])
        let maxTotal = max(1, rows.compactMap { $0["total"].double }.max() ?? 1)
        ScrollView {
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, lane in
                    MeterBarRow(rank: nil,
                                color: CombatColor.kind(lane["kind"].string ?? ""),
                                pct: (lane["total"].double ?? 0) / maxTotal * 100,
                                name: lane["lane"].string ?? "",
                                tag: lane["category"].string,
                                right: CFmt.num(lane["total"].double ?? 0))
                }
            }
        }
    }
}
