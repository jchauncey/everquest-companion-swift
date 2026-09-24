// Encounter + zone-session lifecycle and the summary projections it produces (fold/src/combat/
// lifecycle.rs): what opens a fight, what closes one and on what evidence, and what a finalized
// fight or zone session freezes into. The routing modules decide WHERE a line lands; this decides
// WHEN a segment begins and ends.
//
// The `max(1, …)` in every denominator is the definition, not a guard. A one-line fight has a span
// of zero, and both its wall DPS and its active DPS are DEFINED to be its total rather than an
// infinity — the floor is visible in the goldens.
//
// `activeSec` is `min(dur, activeMs / 1000)`: a fight cannot be active for longer than it lasted.
import Foundation
import EQCompanionCore

/// One row of the snapshot's `segments` array.
public struct SegmentSummary: Sendable {
    public var id: String
    public var kind: String
    public var name: String
    /// The zone this segment happened in (raw display name). Absent — never null — for a session
    /// that started mid-zone, which is a question the log genuinely cannot answer.
    public var zone: String?
    public var durationSec: Double
    public var total: Int64
    public var dps: Double
    /// Active combat time (capped-gap sum) in seconds; never greater than `durationSec`.
    public var activeSec: Double
    /// `total / activeSec` — active-time DPS.
    public var activeDps: Double
    public var startTs: Int64
    public var active: Bool
    /// Healing received by hostile instances during this segment (an annotation, not a total).
    public var enemyHealTotal: Int64

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id),
            "kind": .string(kind),
            "name": .string(name),
            "durationSec": .double(durationSec),
            "total": .int(total),
            "dps": .double(dps),
            "activeSec": .double(activeSec),
            "activeDps": .double(activeDps),
            "startTs": .int(startTs),
            "active": .bool(active),
            "enemyHealTotal": .int(enemyHealTotal),
        ]
        if let zone { o["zone"] = .string(zone) }
        return .object(o)
    }
}

/// One row of the snapshot's `zoneSessions` array.
public struct ZoneSessionSummary: Sendable {
    /// `zone` for the live session, else `zs<n>` for a finalized one.
    public var id: String
    public var zone: String
    /// Absent on the live entry, which has not ended at all.
    public var closedBy: String?
    /// Epoch ms of the first attributed damage in this stay (0 if none / live-unstarted).
    public var startTs: Int64
    /// Epoch ms of the last attributed damage; 0 for the still-live session.
    public var endTs: Int64
    public var total: Int64
    public var dps: Double
    public var live: Bool

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id),
            "zone": .string(zone),
            "startTs": .int(startTs),
            "endTs": .int(endTs),
            "total": .int(total),
            "dps": .double(dps),
            "live": .bool(live),
        ]
        if let closedBy { o["closedBy"] = .string(closedBy) }
        return .object(o)
    }
}

/// Lazily open a fight. Closure is decided by `evalClosure`, which `ingestEvent` runs BEFORE
/// routing, so this only ever has to mint one.
public func ensureEncounter(_ st: EngineState, _ ts: Int64) {
    if st.current != nil { return }
    st.seq += 1
    let enc = Encounter(id: "e\(st.seq)", zone: st.zone, ts: ts)
    // Seed the timeline's pinned rows with whatever stance/invocation is already active, so a fight
    // inherits the standing modifiers.
    if let m = st.stance {
        enc.stanceSpans.append(StanceRaw(group: "stance", name: m.name, start: ts, end: nil))
    }
    if let m = st.invocation {
        enc.stanceSpans.append(StanceRaw(group: "invocation", name: m.name, start: ts, end: nil))
    }
    // Freeze the coats as they stand at engage: "could this pull have been slowed?" is a question
    // about THIS instant, and re-reading at render would re-label past fights after a poison swap.
    enc.coatAtEngage = st.coatUtility
    enc.combatAtEngage = st.coatCombat
    st.current = enc
}

/// Is every engaged hostile instance gone? Two standards, because the evidence differs:
///
///   RETIRED (dead/zoned) → gone immediately. The death line is the evidence, and LINGER_MS in
///     `evalClosure` still covers its trailing damage.
///   LIVE → gone only after PRESENCE_GONE_MS with no presence evidence at all.
///
/// A live charmed pet is never a mob we are killing, so it is excluded — a pet never dies and would
/// pin every charm-grind encounter open forever.
private func hostilePresence(_ st: EngineState, _ enc: Encounter, _ now: Int64) -> (Int, Bool) {
    var hostiles = 0
    var allGone = true
    for id in enc.engaged {
        if st.world.isLivePet(id) { continue }
        hostiles += 1
        let seen = enc.engagedSeen[id] ?? enc.lastTs
        let gone = st.world.isRetired(id) || now - seen >= PRESENCE_GONE_MS
        if !gone {
            allGone = false
            break
        }
    }
    return (hostiles, allGone)
}

/// Evaluate deferred closure of the current encounter as of `now`. Encounters can close purely from
/// time passing, so this runs at the top of each damage/CC ingest AND (live only) from the snapshot.
/// Finalization always stamps the encounter's own `lastTs` — a damage timestamp — never `now`.
///
/// The CC hold is a veto on ONE path, not on closure. It vetoes only the death-close, because that
/// is the judgement it informs; the fallback asks whether anything at all has happened, and a CC
/// application or refresh stamps `lastActivityTs`.
///
/// A hold only ever speaks for an engaged hostile. Two entities are excluded because they cannot
/// answer its question: a RETIRED instance (handled at the retirement site) and a LIVE PET of ours.
public func evalClosure(_ st: EngineState, _ now: Int64) {
    guard let enc = st.current else { return }

    let sinceDamage = now - enc.lastTs
    let sinceActivity = now - st.lastActivityTs

    // Fallback: no damage and no CC for the idle window (mob fled / deaggroed). Evaluated FIRST, so
    // it is reachable regardless of any outstanding hold.
    if sinceActivity >= FALLBACK_IDLE_MS {
        finalizeCurrent(st)
        return
    }

    // CC-hold: any engaged instance still under an unexpired hold vetoes the death-close, except one
    // of your own live pets.
    for (id, until) in enc.ccActiveUntil.pairs where until > now && !st.world.isLivePet(id) {
        return
    }

    let (hostiles, allGone) = hostilePresence(st, enc, now)

    // Death-close: every engaged hostile is dead or gone and the linger has elapsed.
    if allGone && hostiles > 0 && sinceDamage >= LINGER_MS {
        finalizeCurrent(st)
    }
}

/// Freeze the open fight into history. A no-op when nothing is open.
public func finalizeCurrent(_ st: EngineState) {
    guard let enc = st.current else { return }
    st.current = nil
    // Close any open stance/invocation spans at the fight's end, BEFORE the drop rule below, so a
    // dropped shell's spans are closed on the way out too.
    let lastTs = enc.lastTs
    for i in enc.stanceSpans.indices where enc.stanceSpans[i].end == nil {
        enc.stanceSpans[i].end = lastTs
    }
    // Drop empty encounters: a CC application or a lone miss can open one that never accrues
    // attributed damage, and a 0-damage shell must not pollute the history or the session picker.
    if enc.agg.isEmpty { return }
    // Rolling time-to-slow. A pull qualifies only when a slow-capable utility coat was on AT ENGAGE.
    // A qualifying pull that never slowed is pushed as nil — counted as a miss, never averaged in
    // as a zero.
    if let c = enc.coatAtEngage, isSlowCapable(c.poison) {
        let first = enc.agg.procs.firstSlowTs
        st.slowSamples.append(first > 0 ? max(first - enc.startTs, 0) : nil)
        if st.slowSamples.count > SLOW_SAMPLE_CAP { st.slowSamples.removeFirst() }
    }
    st.zoneFinalizedMs += max(enc.lastTs - enc.startTs, 0)
    st.zoneActiveMs += enc.activeMs
    // Compute the immutable summary once, now that the encounter is frozen. A finalized fight's
    // summary never uses `now`, so 0 is a safe sentinel.
    enc.summary = encSummary(enc, "fight", 0)
    st.history.append(enc)
    // Timeline memory bound: keep the event ring only for the most recent TIMELINE_HISTORY_CAP
    // finalized encounters. The aggregate and the summary are untouched.
    if st.history.count > TIMELINE_HISTORY_CAP {
        let dropIdx = st.history.count - 1 - TIMELINE_HISTORY_CAP
        // Swift-only: the compact digest is taken from the ring before it goes, so an older fight
        // still has a DPS curve and damage-by-mob to draw (CombatDigest.swift).
        st.history[dropIdx].digest = FightDigest.build(st.history[dropIdx])
        st.history[dropIdx].events.removeAll()
    }
}

/// The whole-stay row that `snapshot()` appends to `segments` after the fights.
public func zoneSummary(_ st: EngineState) -> SegmentSummary {
    let total = Agg.sum(st.zoneAgg.out)
    let dur = zoneDurationSec(st)
    let activeSec = min(dur, zoneActiveSec(st))
    return SegmentSummary(
        id: "zone",
        kind: "zone",
        name: "\(st.zone ?? "Session") - overall",
        zone: st.zone,
        durationSec: dur,
        total: total,
        dps: Double(total) / dur,
        activeSec: activeSec,
        activeDps: Double(total) / max(1.0, activeSec),
        startTs: 0,
        active: false,
        enemyHealTotal: Agg.sumHeal(st.zoneAgg.enemyHeal)
    )
}

/// One fight's summary. `kind` is `current` for the open one and `fight` for a finalized one, and it
/// decides both the NAMING mode and whether `active` can be true at all.
public func encSummary(_ e: Encounter, _ kind: String, _ now: Int64) -> SegmentSummary {
    let total = Agg.sum(e.agg.out)
    let dur = max(1.0, Double(e.lastTs - e.startTs) / 1000.0)
    let activeSec = min(dur, Double(e.activeMs) / 1000.0)
    return SegmentSummary(
        id: e.id,
        kind: kind,
        name: encounterName(e, kind == "current"),
        // The fight-search haystack is name + zone, so a fight carries where it happened. Stamped at
        // open from the same field a zone session is named from, so the two cannot disagree.
        zone: e.zone,
        durationSec: dur,
        total: total,
        dps: Double(total) / dur,
        activeSec: activeSec,
        activeDps: Double(total) / max(1.0, activeSec),
        startTs: e.startTs,
        active: kind == "current" && now - e.lastTs < ACTIVE_MS,
        enemyHealTotal: Agg.sumHeal(e.agg.enemyHeal)
    )
}

/// The live zone stay's wall span in seconds, floored at 1. The open encounter's span rides on top
/// of the finalized total.
public func zoneDurationSec(_ st: EngineState) -> Double {
    let cur = st.current.map { $0.lastTs - $0.startTs } ?? 0
    return max(1.0, Double(st.zoneFinalizedMs + cur) / 1000.0)
}

/// The live zone stay's active seconds — finalized encounters' `activeMs` plus the open one's.
public func zoneActiveSec(_ st: EngineState) -> Double {
    let cur = st.current?.activeMs ?? 0
    return Double(st.zoneActiveMs + cur) / 1000.0
}

/// The zone-session list for the snapshot: the LIVE session first (id `zone`), then the finalized
/// history NEWEST-FIRST. The live entry's timing and total are computed fresh; the finalized ones
/// reuse what was frozen at finalize, because their aggregates are immutable.
public func zoneSessionSummaries(_ st: EngineState) -> [ZoneSessionSummary] {
    let liveTotal = Agg.sum(st.zoneAgg.out)
    let liveDur = zoneDurationSec(st)
    var out = [ZoneSessionSummary(
        id: "zone",
        zone: st.zone ?? "Session",
        closedBy: nil,
        startTs: st.zoneStartTs,
        endTs: 0,
        total: liveTotal,
        dps: Double(liveTotal) / liveDur,
        live: true
    )]
    for s in st.zoneHistory.reversed() {
        let total = Agg.sum(s.agg.out)
        let durSec = max(1.0, Double(s.finalizedMs) / 1000.0)
        out.append(ZoneSessionSummary(
            id: s.id,
            zone: s.zone,
            closedBy: s.closedBy.asStr,
            startTs: s.startTs,
            endTs: s.lastTs,
            total: total,
            dps: Double(total) / durSec,
            live: false
        ))
    }
    return out
}

/// The finalized fight summaries a snapshot serializes, newest-first and capped. Only the current
/// encounter is recomputed per call; finalized summaries are memoized. The current encounter is
/// always included regardless of the cap, and the zone summary is appended by the caller.
public func collectSegments(_ st: EngineState, _ now: Int64, _ maxSegments: Int) -> [SegmentSummary] {
    var segments: [SegmentSummary] = []
    if let cur = st.current {
        segments.append(encSummary(cur, "current", now))
    }
    let stop = st.history.count > maxSegments ? st.history.count - maxSegments : 0
    for i in stride(from: st.history.count - 1, through: stop, by: -1) {
        let e = st.history[i]
        segments.append(e.summary ?? encSummary(e, "fight", now))
    }
    return segments
}
