// Port of fold/src/modules/alerts.rs — `src/main/modules/alerts.ts`, the alert evaluator.
//
// Two maps fold on REPLAY events as well as live ones, so they are complete the moment the renderer
// hydrates: `spellLastCast` (spell display name with the rank suffix INTACT → newest cast ts;
// nothing downstream of it decides whether an alert fires) and `poisonSlowSeen` (absent until a slow
// is actually observed — an offer is never made from an assumption).
//
// FIRING IS LIVE-ONLY, gated one line above the matcher: replay must never make a sound. Defs arrive
// only through `alerts.define`, so a world this build constructs itself has none. The matcher is
// `AlertsRules.swift` and the early-warning schedule is `AlertsEarly.swift`; `onTick` takes the timer
// projection as a parameter, because a module here cannot borrow two modules the registry is
// iterating.
//
// `spellLastCast` evicts the least recently cast, expressed as the first key in iteration order —
// true only because every write deletes the key before re-inserting it.
import Foundation
import EQLog
import EQCompanionCore

/// Max distinct spell display names kept in the rank-recency map. A bound, not a policy.
private let spellCastCap = 400

/// The observation the slow-poison offer is made from.
private struct PoisonSlowRecency {
    var lastAt: Int64
    var count: Int64
    var lastTarget: String
    var json: JSONValue {
        ["lastAt": .int(lastAt), "count": .int(count), "lastTarget": .string(lastTarget)]
    }
}

public final class AlertsModule: EqModule, Defines {
    public let id = "alerts"
    private var seq: Int64 = 0
    /// Rank-preserving cast recency. See the header on why the iteration order matters.
    private var spellLastCast = JSMap<Int64>()
    private var poisonSlowSeen: PoisonSlowRecency?
    /// The user's own definitions and the clocks they fire under. Empty until `alerts.define` pushes
    /// a set.
    private let rules = AlertRuleSet()
    /// The state machine holding a warning between the landing that armed it and the deadline it
    /// speaks at.
    private let early = EarlyWarnings()
    /// Fires accumulated since the ingest last drained them.
    private var pending: [Fire] = []
    /// The announce cursor.
    ///
    /// Only `defs`, `history`, `spellLastCast` and `poisonSlowSeen` are published; the compiled
    /// rules, cooldown clocks, armed warnings and pending queue are not. `alerts.define` replaces
    /// the published `defs` and advances no log seq, so the cursor has to land strictly above the
    /// fold position to announce a change with no event behind it.
    private var announce = Announce()

    public init() {}

    /// Runs for replay events as well as live ones: the map describes the character, not the session.
    private func noteCast(_ ev: Event) {
        if ev.kind != "castBegin" { return }
        let name = JS.trim(ev.str(Key.spell) ?? "")
        if name.isEmpty { return }
        let ts = ev.ts
        // A stamp that went backwards moves neither the recency nor the key's position: the refusal
        // is above the delete, not below it.
        if let prev = spellLastCast[name], prev >= ts { return }
        // Re-insert so the iteration order stays least-recent-first for the eviction below.
        spellLastCast.remove(name)
        spellLastCast.insert(name, ts)
        if spellLastCast.count > spellCastCap, let oldest = spellLastCast.keys.first {
            spellLastCast.remove(oldest)
        }
        // Past both refusals, so the published recency map really moved.
        announce.changed(seq)
    }

    /// `effect` is the unambiguous half of a poison proc: the two shared emotes are shared between
    /// strikes that AGREE on their effect, so 'slow' is Weakening Strike's landing and nothing else.
    private func notePoisonSlow(_ ev: Event) {
        if ev.kind != "poisonProc" || ev.str(Key.effect) != "slow" { return }
        let ts = ev.ts
        let target = ev.str(Key.target) ?? ""
        let prevLastAt = poisonSlowSeen?.lastAt ?? 0
        let lastTarget = ts >= prevLastAt ? target : (poisonSlowSeen?.lastTarget ?? target)
        poisonSlowSeen = PoisonSlowRecency(lastAt: max(prevLastAt, ts),
                                           count: (poisonSlowSeen?.count ?? 0) + 1,
                                           lastTarget: lastTarget)
        announce.changed(seq)
    }

    /// Defs persist across character switches — they are user prefs, not log state. The cast-recency
    /// map is character state, so it goes, and the replay that follows repopulates it.
    public func reset() {
        seq = 0
        announce.reset()
        spellLastCast.clear()
        poisonSlowSeen = nil
        // Only the per-character firing bookkeeping; the defs survive.
        rules.reset()
        // A pending warning is about a debuff on a mob THIS character was fighting, and the replay
        // that follows re-arms nothing (a replay never fires).
        early.reset()
        pending.removeAll()
    }

    /// No `epoch` branch, deliberately: a rebirth behind the same name still casts the same spells,
    /// and the fires ledger is user-facing history. These maps span the launch boundary.
    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        noteCast(ev)
        notePoisonSlow(ev)
        // The boundary law, one gate above the matcher: replay must never make a sound. A historical
        // fold reaches no rule, spends no cooldown and writes no history.
        if !live { return }
        // A fire is the only thing that writes the published history, so an empty batch is a rule
        // swallowed by a cooldown, taken by an early warning, or an event no rule wanted.
        let fired = rules.fire(ev, early)
        if !fired.isEmpty { announce.changed(seq) }
        pending.append(contentsOf: fired)
    }

    /// The one module that ever reads the timer projection, and only while it has something to
    /// measure against it. Asked one beat ahead so the projection is not built when nothing owes.
    public var wantsTimerRows: Bool { !early.idle || rules.hasBreakWatchers() }

    /// The wall-clock heartbeat, and it exists for one thing: the early-warning offset, whose subject
    /// is a deadline that arrives while the log is idle.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        for due in early.tick(nowMs, timerRows, rules) {
            if let fire = rules.fireWarning(due, nowMs) {
                pending.append(fire)
                // A warning spoken by the heartbeat writes history with no line behind it.
                announce.changed(seq)
            }
        }
    }

    /// The dirty bit: a cast that moved the recency map, a slow proc, a fire that wrote history, or
    /// a pushed def set.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue {
        var state: [String: JSONValue] = [
            // From the settings store, never from the log.
            "defs": .array(rules.defs),
            // Written by a fire and by nothing else, so it is empty through any historical fold.
            "history": rules.history(),
            "spellLastCast": spellLastCast.json { .int($0) }
        ]
        // Omitted rather than null: an absent key is the honest encoding of "no slow has ever been
        // observed for this character".
        if let p = poisonSlowSeen { state["poisonSlowSeen"] = p.json }
        return ["seq": .int(seq), "state": .object(state)]
    }

    public var asDefines: Defines? { self }

    public func takeFires() -> [Fire] {
        let out = pending
        pending = []
        return out
    }

    // MARK: - Defines

    public var family: String { "alerts" }

    /// The whole rule set, replaced. The payload is the defs ARRAY rather than a params object,
    /// because the family's knowledge IS the list; anything else leaves the previous set standing.
    public func define(_ payload: JSONValue) {
        guard let list = payload.array else { return }
        rules.setDefs(list)
        // The published `defs` just changed with no event behind it.
        announce.changed(seq)
    }
}
