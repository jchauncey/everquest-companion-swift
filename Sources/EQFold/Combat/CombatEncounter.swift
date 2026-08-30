// Encounter / zone-session record types, the segmentation constants and the encounter naming rule
// (fold/src/combat/encounter.rs). Pure data shapes and numbers; nothing here reads or mutates
// engine state.
//
// Closure is decided on two independent axes, and conflating them splits a multi-mob pull:
//
//   TIMING (damage only) — LINGER_MS runs against the encounter's last ATTRIBUTED DAMAGE, and a
//     fight finalizes at that ts, never at the eval moment. Nothing else may touch this clock.
//   PRESENCE (any evidence) — whether an engaged instance is still in the fight, refreshed by any
//     observation of it. Presence never opens or extends an encounter; it only vetoes closing one.
//
// PRESENCE_GONE_MS is 4x LINGER_MS because real fights go quiet for many seconds at a time (miss
// streaks, cast phases, a stun), and a fled mob still closes at FALLBACK_IDLE_MS. CC_HOLD_MS
// exceeds FALLBACK_IDLE_MS so an actively refreshed mez holds a fight open; the hold vetoes only
// the death-close, never closure as such.
import Foundation
import EQCompanionCore

// MARK: - Constants (the Rust spellings, so every worker names one number one way).

public let LINGER_MS: Int64 = 5_000
public let PRESENCE_GONE_MS: Int64 = 20_000
public let FALLBACK_IDLE_MS: Int64 = 60_000
public let CC_HOLD_MS: Int64 = 120_000
/// Per-hit active-time cap AND the "in combat" freshness window.
public let ACTIVE_MS: Int64 = 3_000
public let ZONE_HISTORY_CAP: Int = 24
/// How many classified lines the live processing log holds. A display buffer: nothing keys, counts
/// or attributes off it, and a snapshot serializes at most the newest 150.
public let RECENT_CAP: Int = 300
/// How many recent qualifying pulls (a slow-capable coat on at engage) the rolling time-to-slow
/// ring keeps.
public let SLOW_SAMPLE_CAP: Int = 25
/// Per-encounter timeline ring bound. An overflow is DECLARED rather than silent, via
/// `eventsTotal` and the view's `truncated` flag.
public let TIMELINE_CAP: Int = 8_000
/// How many finalized encounters keep their event ring after finalize.
public let TIMELINE_HISTORY_CAP: Int = 60
/// Max events serialized into a single timeline view; above this the engine downsamples with a
/// uniform stride and flags it.
public let TIMELINE_BUDGET: Int = 2_000
/// Per-encounter marker ring. Markers are never downsampled and never counted from.
public let MARKER_CAP: Int = 1_000

// MARK: - Record shapes.

/// One coated poison and when it went on.
public struct CoatSlot: Sendable {
    /// DB spell name, or `unknown` when the line refused to name it.
    public var poison: String
    /// Epoch ms of the coat line.
    public var sinceTs: Int64

    public init(poison: String, sinceTs: Int64) { self.poison = poison; self.sinceTs = sinceTs }

    public var json: JSONValue { ["poison": .string(poison), "sinceTs": .int(sinceTs)] }
}

/// Internal raw timeline record (absolute ts; converted to relative at snapshot).
public struct TimelineRaw: Sendable {
    public var ts: Int64
    public var lane: String
    public var category: String
    public var amount: Int64
    public var crit: Bool
    public var modifiers: [String]
    public var kind: String
    /// `miss` / `resist` for avoided and resisted instants; `nil` = a landed hit.
    public var outcome: String?
    /// Miss subtype (dodge/parry/…) or `resisted`, for the tooltip.
    public var detail: String?
    /// Target/defender name, for the tooltip.
    public var target: String?

    public init(ts: Int64, lane: String, category: String, amount: Int64, crit: Bool,
                modifiers: [String], kind: String, outcome: String? = nil,
                detail: String? = nil, target: String? = nil) {
        self.ts = ts; self.lane = lane; self.category = category; self.amount = amount
        self.crit = crit; self.modifiers = modifiers; self.kind = kind
        self.outcome = outcome; self.detail = detail; self.target = target
    }
}

/// Internal raw timeline MARKER (absolute ts; converted to relative at snapshot).
public struct MarkerRaw: Sendable {
    public var ts: Int64
    public var kind: String
    public var label: String
    public var detail: String?

    public init(ts: Int64, kind: String, label: String, detail: String? = nil) {
        self.ts = ts; self.kind = kind; self.label = label; self.detail = detail
    }
}

/// Internal raw stance/invocation span (absolute ts). `end` is nil while active.
public struct StanceRaw: Sendable {
    public var group: String
    public var name: String
    public var start: Int64
    public var end: Int64?

    public init(group: String, name: String, start: Int64, end: Int64? = nil) {
        self.group = group; self.name = name; self.start = start; self.end = end
    }
}

/// Why a zone session stopped accruing. `zone` — a zone line (or the epoch boundary). `mark` — the
/// user pressed "New session". It is the merge-back eligibility test, which is why it is recorded
/// rather than inferred: a split the USER made is reversible, a boundary the WORLD made is not.
public enum ZoneSessionClose: String, Sendable {
    case zone
    case mark

    public var asStr: String { rawValue }
}

/// A finalized zone session: the live zone aggregate frozen at a zone line into a capped ring, so a
/// past zone's overall meter stays selectable.
public final class ZoneSession {
    public var id: String
    public var zone: String
    public var agg: Agg
    public var closedBy: ZoneSessionClose
    /// First/last attributed-damage ts. 0 means the session saw none — and those are dropped.
    public var startTs: Int64
    public var lastTs: Int64
    /// Sum of finalized-encounter wall durations (ms) — the DPS denominator.
    public var finalizedMs: Int64
    /// Sum of finalized-encounter `activeMs`.
    public var activeMs: Int64

    public init(id: String, zone: String, agg: Agg, closedBy: ZoneSessionClose,
                startTs: Int64, lastTs: Int64, finalizedMs: Int64, activeMs: Int64) {
        self.id = id; self.zone = zone; self.agg = agg; self.closedBy = closedBy
        self.startTs = startTs; self.lastTs = lastTs
        self.finalizedMs = finalizedMs; self.activeMs = activeMs
    }
}

/// One in-progress or finalized FIGHT.
public final class Encounter {
    public var id: String
    /// The zone this fight happened in, stamped at open. Absent — never null — for a session that
    /// started mid-zone.
    public var zone: String?
    public var startTs: Int64
    public var lastTs: Int64
    public var agg: Agg
    /// Instance ids engaged as hostiles. The one thing that can veto closure.
    public var engaged: Set<String>
    /// instanceId → ts of the last evidence this instance is still in the fight. The presence axis;
    /// it drives only the "gone" staleness in `evalClosure` and never feeds firstHit/lastHit/DPS.
    public var engagedSeen: JSMap<Int64>
    /// Active-combat time accumulator (ms): on each attributed damage hit we add
    /// `min(ts - prevDamageTs, ACTIVE_MS)`. The first hit adds 0.
    public var activeMs: Int64
    /// ts of the previous attributed damage hit, for the `activeMs` delta.
    public var prevDamageTs: Int64?
    /// instanceId → epoch-ms until which this engaged instance is CC-held. A CC'd instance counts
    /// as alive, so a mez-and-wait keeps the encounter open regardless of damage gaps.
    public var ccActiveUntil: JSMap<Int64>
    /// Display name of the most recent outgoing-damage target — the LIVE encounter name tracks
    /// whatever you are currently swinging at. On finalize the name switches to the largest target.
    public var lastOutTarget: String?
    /// The finalized fight's memoized summary, computed once at finalize because the aggregate is
    /// immutable thereafter.
    public var summary: SegmentSummary?
    /// Per-encounter timeline event ring (absolute ts), capped drop-oldest at TIMELINE_CAP.
    public var events: [TimelineRaw]
    /// True count of every instant ever pushed, including ones the cap evicted. The only way a
    /// consumer can tell "the ring is full" from "the fight was that long".
    public var eventsTotal: Int64
    /// Stance/invocation spans that overlapped this encounter (absolute ts). Deliberately not the
    /// session state timeline: this list feeds the timeline view. Two lists, one writer.
    public var stanceSpans: [StanceRaw]
    /// Point annotations on this fight's clock. Never downsampled and never counted from.
    public var markers: [MarkerRaw]
    /// The utility blade coat on at open and the combat venoms alongside it, snapshotted here
    /// because "could this pull have been slowed?" is a question about the moment of ENGAGE.
    public var coatAtEngage: CoatSlot?
    public var combatAtEngage: [CoatSlot]

    public init(id: String, zone: String?, ts: Int64) {
        self.id = id
        self.zone = zone
        self.startTs = ts
        self.lastTs = ts
        self.agg = Agg()
        self.engaged = []
        self.engagedSeen = JSMap()
        self.activeMs = 0
        self.prevDamageTs = nil
        self.ccActiveUntil = JSMap()
        self.lastOutTarget = nil
        self.summary = nil
        self.events = []
        self.eventsTotal = 0
        self.stanceSpans = []
        self.markers = []
        self.coatAtEngage = nil
        self.combatAtEngage = []
    }
}

/// The name of an encounter. Two modes:
///
///   `live = false` — named after the largest target. The log has no HP, so "most damage absorbed"
///     is a labeled proxy for "the thing we were killing" (world-model law 6).
///   `live = true` — named after whatever you are presently swinging at, so a live pull is labeled
///     by the mob in front of you rather than by whichever twin ends up taking the most damage.
///
/// Both keep the `+N` suffix counting the other distinct engaged targets.
///
/// The sort must be STABLE: two targets that absorbed exactly the same damage are named in the
/// order they were first struck.
public func encounterName(_ e: Encounter, _ live: Bool) -> String {
    let targets = e.agg.targets.values
    if targets.isEmpty { return "Combat" }
    let others = targets.count - 1
    let suffix = others > 0 ? " +\(others)" : ""
    if live, let name = e.lastOutTarget { return "\(name)\(suffix)" }
    // Stable descending sort by amount: Swift's `sort` is not stable, so the original index breaks
    // every tie the way an insertion-ordered walk would.
    let ranked = targets.enumerated().sorted { a, b in
        a.element.amount != b.element.amount ? a.element.amount > b.element.amount : a.offset < b.offset
    }
    return "\(ranked[0].element.name)\(suffix)"
}
