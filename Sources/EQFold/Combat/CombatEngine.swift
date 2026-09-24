// The combat engine — the Swift port of `fold/src/combat/mod.rs`, a state machine over the log
// stream. One file here per Rust module there.
//
// No wall clock, ever. `snapshot(now:…)` takes `now` as a parameter and the recorder passes the
// slice's last event ts; the hydrating gate, deferred encounter closure, the charm sweep and the
// ally-bind expiry all evaluate against it.
//
// A live snapshot ages the model — the four sweeps — so it is a mutating read. Determinism comes
// from the gate, not from purity: while `hydrating` the sweep block is not entered at all.
//
// Three models are live-only and so publish nothing in a historical fold: the pet nudge (armed only
// when `!hydrating`), the classification ring (written only `if recording`) and the session mark
// (refused while hydrating).
import Foundation
import EQLog
import EQCompanionCore

/// How many classified lines one snapshot carries — the newest 150. Half the ring's own bound: what
/// the engine remembers and what a payload costs are different budgets.
let RECENT_VIEW = 150

/// `shared/combat.ts SnapshotOpts`.
public struct SnapshotOpts: Sendable {
    public var selectedId: String?
    /// Include lines the engine could not classify (damage-shaped but unmatched). Reads the
    /// classification ring, which a historical fold never writes.
    public var showUnparsed: Bool
    /// Cap on how many finalized-fight summaries to serialize, newest-first. A payload bound, never
    /// a retention one.
    public var maxSegments: Int
    /// Include the selected encounter's event timeline. Off by default: heavier than the bar view.
    public var timeline: Bool
    /// Swift-only: include the selected fight's `FightDigest` when its event ring is gone. Absent
    /// unless asked, so no ported answer changes shape.
    public var digest: Bool = false

    public init(selectedId: String? = nil, showUnparsed: Bool = false, maxSegments: Int = 0, timeline: Bool = false,
                digest: Bool = false) {
        self.selectedId = selectedId; self.showUnparsed = showUnparsed
        self.maxSegments = maxSegments; self.timeline = timeline; self.digest = digest
    }

    /// The recorder's full-fat options.
    public static func full() -> SnapshotOpts {
        SnapshotOpts(selectedId: nil, showUnparsed: true, maxSegments: 100_000, timeline: true)
    }

    /// The per-scope walk's options — one segment, one resolved selection, no timeline.
    public static func scope(_ id: String) -> SnapshotOpts {
        SnapshotOpts(selectedId: id, showUnparsed: false, maxSegments: 1, timeline: false)
    }
}

/// The rolling time-to-slow rollup. Statistics are computed over the landed samples only and the
/// nulls surface as `noLand`; with no landed samples every statistic is absent rather than 0.
struct SlowRollup {
    var pulls: Int
    var landed: Int
    var noLand: Int
    var window: Int
    var avgMs: Int64?
    var medianMs: Int64?
    var minMs: Int64?
    var maxMs: Int64?

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "pulls": .int(Int64(pulls)), "landed": .int(Int64(landed)),
            "noLand": .int(Int64(noLand)), "window": .int(Int64(window)),
        ]
        if let v = avgMs { o["avgMs"] = .int(v) }
        if let v = medianMs { o["medianMs"] = .int(v) }
        if let v = minMs { o["minMs"] = .int(v) }
        if let v = maxMs { o["maxMs"] = .int(v) }
        return .object(o)
    }
}

/// The live stance/invocation pair. Every field is absent rather than null when never observed this
/// session.
struct StanceState {
    var stance: String?
    var stanceTs: Int64?
    var invocation: String?
    var invocationTs: Int64?

    var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let v = stance { o["stance"] = .string(v) }
        if let v = stanceTs { o["stanceTs"] = .int(v) }
        if let v = invocation { o["invocation"] = .string(v) }
        if let v = invocationTs { o["invocationTs"] = .int(v) }
        return .object(o)
    }
}

/// One engine owning one `EngineState`, plus snapshot assembly.
public final class CombatEngine {
    /// `snapshot()` is a mutating read when live — it ages the model, and the deferred closure it
    /// evaluates finalizes the open fight, so the answer has to stick.
    public let st = EngineState()
    /// Whose log this is, held so `reset()` can re-inject it the way every construction path does
    /// (`reset()` then `setPlayerName`).
    var playerName: String?

    public init() {}

    /// Inject the player's own character name.
    public func setPlayerName(_ name: String) {
        playerName = name
        st.setPlayerName(name)
    }

    public func reset() {
        st.reset()
        if let name = playerName { st.setPlayerName(name) }
    }

    /// The scan has handed over to the tail — made at the end of the historical scan and before the
    /// tailer starts. From here on `hydrating` is false, so every snapshot runs the four sweeps at
    /// the instant it was asked for. A historical fold never calls it.
    public func setLive() { st.setLive() }

    /// Is this engine still replaying? The flag the snapshot publishes.
    public var hydrating: Bool { st.hydrating }

    /// Fold one canonical event.
    ///
    /// `live` is the belt-and-braces half of going live. It has to be cleared before the rest of the
    /// event folds — the pet-summon nudge is gated on `!hydrating`. The roster is refreshed first
    /// and once, which is exactly the per-decision live pull.
    public func onEvent(_ ev: Event, live: Bool, roster: RosterSource?) {
        if live { st.setLive() }
        st.refreshRoster(roster)
        ingestEvent(st, ev)
    }

    /// A session mark — "start a new session now".
    ///
    /// The move a zone line makes, minus the room change: close the open fight, freeze the running
    /// stay tagged `closedBy: 'mark'`, mint fresh accumulators. Everything else the zone case does is
    /// a statement about having LEFT, so `st.zone` keeps its value.
    ///
    /// Refused while hydrating, which makes replay determinism structural. An empty stay mints
    /// nothing, so a double-click is harmless.
    @discardableResult
    public func sessionMark(_ ts: Int64) -> Bool {
        if st.hydrating { return false }
        evalClosure(st, ts)
        finalizeCurrent(st)
        st.finalizeZoneSession(.mark)
        st.resetZoneAccumulators()
        return true
    }

    /// The snapshot, at the instant it is asked for.
    ///
    /// The four sweeps run only when live. A replay is not a moment in time, so `hydrating` is the
    /// whole gate. The order is not arbitrary: charm, ally, nudge, then closure — the charm sweep
    /// uncharms through the world model, which is evidence the closure test then reads.
    public func snapshot(now: Int64, opts: SnapshotOpts, roster: RosterSource?) -> JSONValue {
        if !st.hydrating {
            st.sweepCharm(now)
            st.sweepAlly(now)
            st.petNudge.sweep(now)
            evalClosure(st, now)
        }

        var segments = collectSegments(st, now, opts.maxSegments)
        segments.append(zoneSummary(st))

        // `inCombat` — the one thing `now` decides in a historical fold besides a summary's `active`
        // flag: whether the open fight's last damage is inside the freshness window.
        let inCombat = st.current.map { now - $0.lastTs < ACTIVE_MS } ?? false

        let selectedId = resolveSelectedId(st, opts)
        // Null, not an empty shell: with no fights at all the selection resolves to nothing.
        let selected = buildSelected(st, selectedId, now)?.json ?? .null

        // The classification ring, empty for the whole of a historical fold. The filter runs before
        // the slice and the two are not interchangeable: a burst of refused lines must not push every
        // classified one out of a panel that was not showing them anyway.
        let kept = st.recent.filter { opts.showUnparsed || $0.cat != "unparsed" }
        let recent = kept[max(0, kept.count - RECENT_VIEW)...].map(\.json)

        var out: [String: JSONValue] = [
            "selectedId": .string(selectedId),
            "selected": selected,
            "segments": .array(segments.map(\.json)),
            "inCombat": .bool(inCombat),
            "recent": .array(Array(recent)),
            "stance": stanceState(st).json,
            "poison": ["coat": coatState(st), "slow": slowRollup(st).json],
            "zoneSessions": .array(zoneSessionSummaries(st).map(\.json)),
            "hydrating": .bool(st.hydrating),
            "roster": st.rosterSnap(roster).json,
        ]
        // Absent is not null: `zone` until the first `You have entered X.` line, `currentTarget`
        // while no fight is open or none has landed an outgoing hit.
        if let zone = st.zone { out["zone"] = .string(zone) }
        if let target = currentTarget(st) { out["currentTarget"] = target }
        // `timeline` is absent when the caller did not ask, and present-and-null when it asked and
        // the selection carries no timeline.
        if opts.timeline {
            out["timeline"] = buildTimeline(st, selectedId, now)?.json ?? .null
        }
        // Swift-only, and only when asked: a fight whose ring the history cap dropped still has its
        // digest (CombatDigest.swift). Absent when the ring is there or no digest exists.
        if opts.digest, st.current?.id != selectedId,
           let e = st.history.first(where: { $0.id == selectedId }), e.events.isEmpty, let d = e.digest {
            out["digest"] = d.json
        }
        // The pet nudge is absent in every state but the one. It reads the same `now` the sweep above
        // used, so a nudge can never survive the poll that expired it.
        if let nudge = st.petNudge.view(now) { out["petNudge"] = nudge.json }
        return .object(out)
    }

    /// The fight-search corpus. The open fight as `kind: "current"`, then every finalized encounter
    /// newest-first and uncapped.
    ///
    /// A separate door from `snapshot()` so a search pays for no selection, zone list, stance or
    /// roster, and so the whole-stay `kind: "zone"` row is not findable as a fight. Read-only.
    public func fightSummaries(now: Int64) -> [JSONValue] {
        collectSegments(st, now, Int.max).map(\.json)
    }

    /// The per-scope walk, as `goldenOracle.mts walkScopes` performs it: every zone session and every
    /// finalized fight resolved through the same `snapshot({selectedId})` door the UI uses.
    ///
    /// Uncapped — a cap is a hole in an acceptance oracle. Zone sessions first, then fights with
    /// `kind == 'zone'` skipped, because array order is a claim the comparator checks.
    public func walkScopes(now: Int64, roster: RosterSource?) -> [JSONValue] {
        let base = snapshot(now: now, opts: .full(), roster: roster)
        var out: [JSONValue] = []
        for zs in base["zoneSessions"].array ?? [] {
            let id = zs["id"].string ?? ""
            let sel = snapshot(now: now, opts: .scope(id), roster: roster)
            out.append(["kind": "zoneSession", "id": .string(id), "selected": sel["selected"]])
        }
        for seg in base["segments"].array ?? [] {
            if seg["kind"] == .string("zone") { continue }
            let id = seg["id"].string ?? ""
            let sel = snapshot(now: now, opts: .scope(id), roster: roster)
            out.append(["kind": "fight", "id": .string(id), "selected": sel["selected"]])
        }
        return out
    }
}

/// Default selection = the fight scope's head row: the open fight, else the most recent finalized
/// one. It must never wander into the zone aggregate; overall is reached by asking for a
/// zone-session id (`zone` / `zs<n>`), never by default.
///
/// An explicit request is validated against all encounters, not just the capped segment window.
func resolveSelectedId(_ st: EngineState, _ opts: SnapshotOpts) -> String {
    let defaultId = st.current?.id ?? st.history.last?.id ?? ""
    guard let want = opts.selectedId, !want.isEmpty else { return defaultId }
    let selectable = want == "zone"
        || st.current?.id == want
        || st.history.contains { $0.id == want }
        || st.zoneHistory.contains { $0.id == want }
    return selectable ? want : defaultId
}

/// The mob in front of you (world-model law 6, live half). Absent when no encounter is open or the
/// open one has landed no outgoing hit — never a guess, and never the largest target, which is the
/// finalized naming rule and would relabel a live pull retroactively.
///
/// Read-only, and deliberately does not evaluate closure: the snapshot has already done so.
func currentTarget(_ st: EngineState) -> JSONValue? {
    guard let e = st.current, let name = e.lastOutTarget else { return nil }
    return [
        "name": .string(name),
        "others": .int(Int64(max(0, e.agg.targets.count - 1))),
        "lastTs": .int(e.lastTs),
    ]
}

/// The live blade-coat pair, copied out so a consumer cannot mutate engine state. Every consumer must
/// render both slots: a rogue can run combat venoms with no utility poison on at all.
func coatState(_ st: EngineState) -> JSONValue {
    var out: [String: JSONValue] = ["combat": .array(st.coatCombat.map(\.json))]
    if let u = st.coatUtility { out["utility"] = u.json }
    return .object(out)
}

func stanceState(_ st: EngineState) -> StanceState {
    StanceState(stance: st.stance?.name, stanceTs: st.stance?.ts,
                invocation: st.invocation?.name, invocationTs: st.invocation?.ts)
}

/// `engine.ts slowRollup`. The median of an even-length sample is the rounded mean of the two middle
/// values, and the mean is rounded too — `Math.round`, which differs from Rust only for negatives.
func slowRollup(_ st: EngineState) -> SlowRollup {
    var landed = st.slowSamples.compactMap { $0 }
    landed.sort()
    let pulls = st.slowSamples.count
    var out = SlowRollup(pulls: pulls, landed: landed.count, noLand: pulls - landed.count,
                         window: SLOW_SAMPLE_CAP, avgMs: nil, medianMs: nil, minMs: nil, maxMs: nil)
    if landed.isEmpty { return out }
    let sum = landed.reduce(Int64(0), &+)
    let mid = landed.count >> 1
    out.avgMs = jsRound(Double(sum) / Double(landed.count))
    out.medianMs = landed.count % 2 == 1 ? landed[mid] : jsRound(Double(landed[mid - 1] + landed[mid]) / 2.0)
    out.minMs = landed[0]
    out.maxMs = landed[landed.count - 1]
    return out
}

/// `Math.round` — round half UP, which is not `f64::round` (half away from zero). They differ only
/// for negatives; stated so a later reader does not "simplify" it.
func jsRound(_ v: Double) -> Int64 { Int64((v + 0.5).rounded(.down)) }

// MARK: - Checkpoint

extension CombatEngine: FoldCheckpointable {
    /// The whole engine is the one `EngineState`, so the codec is the state's; the per-model codecs
    /// live beside the private fields they capture (world, charm, ally, others, timelines, ledgers).
    ///
    /// `playerName` is deliberately NOT carried: it is attach-time injection (`setPlayerName`), the
    /// one constructor-style dependency, and every attach re-injects it after a restore. What events
    /// MUTATE is the state's own `playerKey` / `playerKeyInjected` / `knownPlayers` (the heal-learned
    /// fallback), and those the blob carries.
    public func checkpointState() -> JSONValue { st.checkpointState() }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool { st.restoreCheckpoint(state) }
}
