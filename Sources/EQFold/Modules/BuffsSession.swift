// The buffs model's SESSION FRAME: the last instant the character was seen in the log, and the
// log-hole state machine built on it.
//
// It holds one question. A break in the event stream arrived — did the character LEAVE, or did we
// lose the thread? A logout freezes every buff with the character and hands it back at login; a lost
// thread means whatever we believed was standing is stale.
//
// It waits, because the hole is always observed BEFORE the thing that explains it. What it waits for
// is EVIDENCE, not a clock: a hole is unexplained only when `inWorldEvidence` arrives with no login
// in between.
//
// The hold is wider than the hole:
//
//   the HOLD (60 s, the detector's emit floor) — every absence a pause can be reported for.
//   the HOLE (30 min) — an absence long enough that, unexplained, it means we lost the thread.
//     Only a hole ever DROPS anything.
// (fold/src/modules/buffs_session.rs)
import Foundation
import EQLog
import EQCompanionCore

public final class SessionFrame {
    /// ts of the newest primary event folded so far (0 before the first).
    private var lastEventTs: Int64 = 0
    /// Last instant seen before an OPEN absence, or 0 when there is none.
    private var fromTs: Int64 = 0
    /// True when the open absence is past the log-HOLE boundary, so ruling it drops rows.
    private var isHole = false
    /// True once a login turned up for the open absence: the pause is on its way.
    private var explained = false

    public init() {}

    public func reset() {
        lastEventTs = 0
        closeHole()
    }

    /// The last-known-online instant of an OPEN absence, or 0. A BUFF older than this is exempt from
    /// the hygiene sweep while the absence is unresolved.
    public var heldBeforeTs: Int64 { fromTs }

    /// A login (or a character rebirth) settled the question: close the hole with no casualties.
    public func closeHole() {
        fromTs = 0
        isHole = false
        explained = false
    }

    /// Fold one primary event. Returns the last-known-online instant of a hole that has JUST been
    /// ruled unexplained — the caller drops what predates it — or nil.
    public func observe(_ ev: Event) -> Int64? {
        // Open first, then rule: a hole is always revealed BY the event on its far side, so the same
        // event has to be able to open it and answer it.
        openAbsence(ev)
        let ruling = rule(ev)
        lastEventTs = ev.ts
        return ruling
    }

    /// Rule on the OPEN absence, if this event says anything about it. A login EXPLAINS it, and the
    /// hold stays up until the gap that follows closes it. In-world evidence with no login RULES it.
    private func rule(_ ev: Event) -> Int64? {
        if fromTs == 0 { return nil }
        if ev.kind == "sessionStart" {
            explained = true
            return nil
        }
        if !inWorldEvidence(ev) { return nil }
        let from = fromTs
        let unexplainedHole = isHole && !explained
        closeHole()
        return unexplainedHole ? from : nil
    }

    /// Open an absence when this event follows a quiet stretch worth pausing for.
    private func openAbsence(_ ev: Event) {
        if lastEventTs <= 0 { return }
        let quietMs = ev.ts - lastEventTs
        if quietMs < offlineGapMinMs { return }
        // A second quiet stretch before the first was resolved is the SAME unresolved absence: keep
        // the oldest known-online instant and let either stretch make it a hole.
        if fromTs == 0 { fromTs = lastEventTs }
        if quietMs >= BuffsShapes.sessionGapMs { isHole = true }
    }

    // MARK: - Checkpoint

    /// All four fields: a checkpoint can land INSIDE an open absence, and the resumed fold must
    /// still rule on it — hold the same buffs, drop the same rows — when the far side arrives.
    func checkpointState() -> JSONValue {
        .object(["lastEventTs": .int(lastEventTs), "fromTs": .int(fromTs),
                 "isHole": .bool(isHole), "explained": .bool(explained)])
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let last = v["lastEventTs"].int64, let from = v["fromTs"].int64,
              let hole = v["isHole"].bool, let exp = v["explained"].bool else { return false }
        lastEventTs = last
        fromTs = from
        isHole = hole
        explained = exp
        return true
    }
}
