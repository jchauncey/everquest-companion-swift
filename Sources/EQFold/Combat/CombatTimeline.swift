// The per-fight timeline view (fold/src/combat/timeline.rs).
//
// Converts the encounter's absolute-ts event ring into ms-since-start, downsamples with a uniform
// stride when over budget, and derives the Y-axis lanes plus the pinned stance/invocation spans.
// Read-only over the encounter, so asking for a timeline cannot move a point of damage.
//
// Truncation is declared, never silent. The ring holds only the most recent instants of a longer
// fight, so `rawCount` is the ring occupancy — the population the stride samples — while
// `totalCount` carries the fight's true instant count. The two are never folded together.
//
// Markers are never downsampled. They are sparse by construction, and drawing one in five would be
// worse than drawing none.
import Foundation
import EQCompanionCore

/// The stable UI ordering of the damage taxonomy.
private let CATEGORY_ORDER: [String] = ["melee", "slay", "spell", "dot", "ds"]

private func categoryRank(_ c: String) -> Int {
    CATEGORY_ORDER.firstIndex(of: c) ?? Int.max
}

public struct TimelineEvent: Sendable {
    var t: Int64
    var lane: String
    var category: String
    var amount: Int64
    var crit: Bool
    /// Absent when the line carried none, so a plain landed hit keeps its exact prior shape.
    var modifiers: [String]?
    var kind: String
    var outcome: String?
    var detail: String?
    var target: String?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "t": .int(t),
            "lane": .string(lane),
            "category": .string(category),
            "amount": .int(amount),
            "crit": .bool(crit),
            "kind": .string(kind),
        ]
        if let modifiers { o["modifiers"] = .array(modifiers.map { .string($0) }) }
        if let outcome { o["outcome"] = .string(outcome) }
        if let detail { o["detail"] = .string(detail) }
        if let target { o["target"] = .string(target) }
        return .object(o)
    }
}

public struct TimelineLane: Sendable {
    var lane: String
    var category: String
    var total: Int64
    var kind: String

    public var json: JSONValue {
        ["lane": .string(lane), "category": .string(category), "total": .int(total), "kind": .string(kind)]
    }
}

public struct StanceSpanView: Sendable {
    var group: String
    var name: String
    var start: Int64
    var end: Int64

    public var json: JSONValue {
        ["group": .string(group), "name": .string(name), "start": .int(start), "end": .int(end)]
    }
}

public struct TimelineMarker: Sendable {
    var t: Int64
    var kind: String
    var label: String
    var detail: String?

    public var json: JSONValue {
        var o: [String: JSONValue] = ["t": .int(t), "kind": .string(kind), "label": .string(label)]
        if let detail { o["detail"] = .string(detail) }
        return .object(o)
    }
}

public struct TimelineView: Sendable {
    var id: String
    var name: String
    var startTs: Int64
    var durationMs: Int64
    var lanes: [TimelineLane]
    var events: [TimelineEvent]
    var stanceSpans: [StanceSpanView]
    var markers: [TimelineMarker]
    var downsampled: Bool
    var rawCount: Int64
    var totalCount: Int64
    var truncated: Bool

    public var json: JSONValue {
        [
            "id": .string(id),
            "name": .string(name),
            "startTs": .int(startTs),
            "durationMs": .int(durationMs),
            "lanes": .array(lanes.map(\.json)),
            "events": .array(events.map(\.json)),
            "stanceSpans": .array(stanceSpans.map(\.json)),
            "markers": .array(markers.map(\.json)),
            "downsampled": .bool(downsampled),
            "rawCount": .int(rawCount),
            "totalCount": .int(totalCount),
            "truncated": .bool(truncated),
        ]
    }
}

/// One ring record → one serialized timeline instant (absolute ts → ms-since-start).
private func timelineEvent(_ r: TimelineRaw, _ start: Int64) -> TimelineEvent {
    TimelineEvent(
        t: max(r.ts - start, 0),
        lane: r.lane,
        category: r.category,
        amount: r.amount,
        crit: r.crit,
        modifiers: r.modifiers.isEmpty ? nil : r.modifiers,
        kind: r.kind,
        // A plain `hit` outcome is never serialized. The ring does not write one today; the filter
        // is the shape's rule, not an observation about the corpus.
        outcome: r.outcome.flatMap { $0 != "hit" ? $0 : nil },
        detail: r.detail.flatMap { $0.isEmpty ? nil : $0 },
        target: r.target.flatMap { $0.isEmpty ? nil : $0 }
    )
}

/// Walk the ring once, aggregating every event into its lane while emitting only the stride-sampled
/// ones — so lane totals and ordering stay accurate under downsampling.
private func collectTimeline(_ raw: [TimelineRaw], _ start: Int64, _ stride: Int) -> ([TimelineEvent], [TimelineLane]) {
    var events: [TimelineEvent] = []
    var laneAgg: JSMap<TimelineLane> = JSMap()
    for (i, r) in raw.enumerated() {
        if !laneAgg.containsKey(r.lane) {
            laneAgg.insert(r.lane, TimelineLane(lane: r.lane, category: r.category, total: 0, kind: r.kind))
        }
        if var l = laneAgg[r.lane] {
            l.total += r.amount
            laneAgg[r.lane] = l
        }
        if i % stride != 0 { continue }
        events.append(timelineEvent(r, start))
    }
    // Stable: category rank, then total descending, ties keeping the JS map's insertion order.
    let lanes = laneAgg.values.enumerated().sorted { a, b in
        let ra = categoryRank(a.element.category), rb = categoryRank(b.element.category)
        if ra != rb { return ra < rb }
        if a.element.total != b.element.total { return a.element.total > b.element.total }
        return a.offset < b.offset
    }.map(\.element)
    return (events, lanes)
}

/// Build the selected encounter's timeline view. nil for the zone selection, for an id that resolves
/// to nothing, and for an encounter whose event ring the history cap evicted — there the answer is
/// "no timeline available", never an empty one reading as "this fight had no instants".
public func buildTimeline(_ st: EngineState, _ id: String, _ now: Int64) -> TimelineView? {
    if id == "zone" { return nil }
    let isCurrent = st.current?.id == id
    let found: Encounter? = isCurrent ? st.current : st.history.first { $0.id == id }
    guard let e = found else { return nil }
    if e.events.isEmpty && !isCurrent { return nil }
    let start = e.startTs
    let endTs = isCurrent ? max(e.lastTs, now) : e.lastTs
    let durationMs = max(endTs - start, 1)
    let rawCount = e.events.count
    let totalCount = max(Int64(rawCount), e.eventsTotal)
    let truncated = totalCount > Int64(rawCount)
    // Uniform stride keeps the temporal shape while capping the payload on a dense fight.
    let stride = rawCount > TIMELINE_BUDGET ? (rawCount + TIMELINE_BUDGET - 1) / TIMELINE_BUDGET : 1
    let (events, lanes) = collectTimeline(e.events, start, stride)
    return TimelineView(
        id: e.id,
        name: encounterName(e, isCurrent),
        startTs: start,
        durationMs: durationMs,
        lanes: lanes,
        events: events,
        stanceSpans: e.stanceSpans.map { s in
            StanceSpanView(group: s.group, name: s.name,
                           start: max(s.start - start, 0),
                           end: max((s.end ?? endTs) - start, 0))
        },
        markers: e.markers.map { m in
            TimelineMarker(t: max(m.ts - start, 0), kind: m.kind, label: m.label,
                           detail: m.detail.flatMap { $0.isEmpty ? nil : $0 })
        },
        downsampled: stride > 1,
        rawCount: Int64(rawCount),
        totalCount: totalCount,
        truncated: truncated
    )
}
