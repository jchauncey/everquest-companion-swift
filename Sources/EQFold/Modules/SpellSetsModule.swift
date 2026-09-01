// Port of fold/src/modules/spell_sets.rs — what is in your gems, and which named set holds it.
//
// A save is an instant, a load is a burst. `Spell set primary saved.` is a photograph: the set's
// definition becomes the memorized state right then. `Spell set dam loaded.` is a starting pistol —
// the load line is followed by a run of `You forget` lines and the memorizes trickle in over ten
// seconds — so a load opens a PENDING window and the definition is taken when the burst SETTLES.
//
// Settle = 10 s with no memorize/forget/begin line, OR the next spell-set line, whichever comes
// first. Both halves are needed.
//
// The clock is the log's, and every event advances it. `onTick` does the same from the wall clock
// for a live log that falls silent, and is never called on a historical fold.
//
// The memorized map's order is published — `memorized` and every set's `spells` are
// `[...map.values()]`, so insertion order is the serialized array's.
//
// One quirk ported verbatim: the epoch branch calls the module's own `reset()`, which zeroes `seq`
// AFTER the `seq = ev.seq` at the top of `onEvent`. So this module reports seq 0 between the epoch
// event and the next event it folds. That is faithful, not a bug to tidy.
import Foundation
import EQLog
import EQCompanionCore

/// `SETTLE_MS` — no memorize or forget line for this long and a load's burst is over. Measured.
private let settleMs: Int64 = 10_000

/// `SPELL_SETS_SHAPE_VERSION`.
private let spellSetsShapeVersion: Int64 = 1

public final class SpellSetsModule: EqModule {
    public let id = "spellSets"

    private struct SpellSetDef {
        var spells: [String]
        var observedAt: Int64
        /// `saved` or `loaded` — which line defined it.
        var source: String
        var json: JSONValue {
            ["spells": .array(spells.map { .string($0) }), "observedAt": .int(observedAt), "source": .string(source)]
        }
    }

    /// A `loaded` line whose burst has not finished yet.
    private struct PendingLoad {
        var set: String
        /// The last memorize/forget/begin line seen since the load — the settle clock's anchor.
        var lastActivityTs: Int64
    }

    private var memorized = JSMap<String>()
    private var sets = JSMap<SpellSetDef>()
    private var pending: PendingLoad?
    private var seq: Int64 = 0
    /// The announce cursor. It needs the cursor's out-of-band half: `pending` is not published, but
    /// the SETTLE it opens is a real change to `sets`, and a settle can arrive from the wall clock
    /// with no event behind it at all.
    private var announce = Announce()

    public init() {}

    /// A finished memorize loads the gem; a begin line only proves the player is still working.
    private func onMemorize(_ ts: Int64, _ spell: String, _ done: Bool) {
        noteActivity(ts)
        // A begin line publishes nothing: it only keeps an open load window open, and the window is
        // not published state.
        if !done { return }
        memorized.insert(JSFn.memoKey(spell), JS.trim(spell))
        announce.changed(seq)
    }

    private func onForget(_ ts: Int64, _ spell: String) {
        noteActivity(ts)
        memorized.remove(JSFn.memoKey(spell))
        announce.changed(seq)
    }

    /// Gem activity keeps an open load window open.
    private func noteActivity(_ ts: Int64) {
        if pending != nil { pending?.lastActivityTs = ts }
    }

    /// A spell-set line CLOSES any open load first (the "whichever comes first" half of the settle
    /// rule) and then does its own work.
    private func onSpellSet(_ ts: Int64, _ set: String, _ action: String) {
        settleNow(ts)
        switch action {
        case "saved": define(set, ts, "saved")
        case "deleted":
            sets.remove(set)
            announce.changed(seq)
        // `loaded`: the bar is about to be rewritten, and nothing changes until the burst settles.
        // Until then the set keeps its previous definition, the only reading that never states
        // something false.
        default: pending = PendingLoad(set: set, lastActivityTs: ts)
        }
    }

    /// Replace a set's definition with the memorized state right now.
    private func define(_ set: String, _ ts: Int64, _ source: String) {
        sets.insert(set, SpellSetDef(spells: memorized.values, observedAt: ts, source: source))
        // Both callers rewrite the set's definition, so reaching here is a published change.
        announce.changed(seq)
    }

    /// Close an open load window if the log has been quiet long enough.
    private func settleIfIdle(_ ts: Int64) {
        if let p = pending, ts - p.lastActivityTs >= settleMs { settleNow(ts) }
    }

    /// Close an open load window now, recording the bar as it stands. `observedAt` is the SETTLE
    /// time rather than the load line's: the definition describes the bar at the moment it was read.
    private func settleNow(_ ts: Int64) {
        guard let open = pending else { return }
        pending = nil
        define(open.set, ts, "loaded")
    }

    private func state() -> JSONValue {
        ["v": .int(spellSetsShapeVersion),
         "memorized": .array(memorized.values.map { .string($0) }),
         "sets": sets.json(\.json)]
    }

    public func reset() {
        memorized.clear()
        sets.clear()
        pending = nil
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        if ev.kind == "epoch" {
            // A rebirth behind the same name is a different character's bar. See the header on what
            // this does to `seq`.
            reset()
            // After the reset, and off `ev.seq` rather than `seq`, which the reset just zeroed:
            // bumping off the zeroed field would put the cursor BELOW the log-line seq a client
            // still holds in `knownSeq`, so the bar would be emptied here and left on screen there.
            announce.changed(ev.seq)
            return
        }
        let ts = ev.ts
        settleIfIdle(ts)
        switch ev.kind {
        case "spellMemorize": onMemorize(ts, ev.str(.spell) ?? "", ev.bool(.done))
        case "spellForget": onForget(ts, ev.str(.spell) ?? "")
        case "spellSet": onSpellSet(ts, ev.str(.set) ?? "", ev.str(.action) ?? "")
        default: break
        }
    }

    /// The wall-clock half of the settle rule. Never called on a historical fold.
    ///
    /// A settle here has no event behind it and still moves the cursor: `Announce.changed` lands
    /// strictly above the fold position, so a set that settles on a quiet log is announced instead
    /// of waiting for the next line.
    public func onTick(nowMs: Int64, timerRows: [BuffTimerRow]) {
        settleIfIdle(nowMs)
    }

    /// Moves on a gem loaded or forgotten, or a set defined, deleted or settled. See `announce`.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": state()] }
}

// MARK: - Checkpoint

extension SpellSetsModule: FoldCheckpointable {
    /// `pending` is a load burst that has not settled — unpublished, and exactly what a checkpoint
    /// without it would corrupt: the settle after resume would never fire and the set would keep
    /// its stale spell list.
    public func checkpointState() -> JSONValue {
        var o: [String: JSONValue] = [
            "memorized": memorized.checkpoint { .string($0) },
            "sets": sets.checkpoint(\.json),
            "seq": .int(seq),
            "announce": .int(announce.cursor),
        ]
        if let p = pending {
            o["pending"] = .object(["set": .string(p.set), "lastActivityTs": .int(p.lastActivityTs)])
        }
        return .object(o)
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let mem = JSMap<String>.fromCheckpoint(state["memorized"], { $0.string }),
              let defs = JSMap<SpellSetDef>.fromCheckpoint(state["sets"], { v in
                  guard let spells = v["spells"].array, let at = v["observedAt"].int64,
                        let src = v["source"].string else { return nil }
                  return SpellSetDef(spells: spells.compactMap(\.string), observedAt: at, source: src)
              }),
              let savedSeq = state["seq"].int64, let cursor = state["announce"].int64 else { return false }
        memorized = mem
        sets = defs
        if case .object = state["pending"] {
            guard let name = state["pending"]["set"].string,
                  let ts = state["pending"]["lastActivityTs"].int64 else { return false }
            pending = PendingLoad(set: name, lastActivityTs: ts)
        }
        seq = savedSeq
        announce.restore(cursor: cursor)
        return true
    }
}
