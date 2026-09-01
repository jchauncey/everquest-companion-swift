// Port of fold/src/modules/combo.rs — which classes was this character running, and when did that
// change? The `EqModule` shell only; the thinking lives in four pure siblings: `ComboEvidence`
// (intake), `ComboScore` (presence · exclusivity · sustain), `ComboLevels` (dings against `/who`
// rows) and `ComboIntervals` (detectors and assembly).
//
// EQ Legends runs up to three classes at once, the displayed level is the MINIMUM of their levels,
// and a loadout swap is never logged. So the app either infers the combo and labels it inferred, or
// it says nothing at all.
//
// Registered first, so within one bus delivery every later module (and the combat engine) sees an
// already-advanced combo state. It consumes and emits no derived events.
//
// Intervals are recomputed from scratch whenever anything changes — a `/who` row or a user
// correction re-labels an arbitrary span — so interval ids are snapshot-scoped.
//
// `seq` is this module's own revision: a correction changes every interval and advances no log seq,
// and `useModule` dedupes deltas with `d.seq <= knownSeq`.
import Foundation
import EQLog
import EQCompanionCore

public final class ComboModule: EqModule, Defines {
    public let id = "combo"

    private var observations: [ClassObservation] = []
    private var whoRows: [WhoRow] = []
    private var levels: [LevelPoint] = []
    private var corrections: [ComboCorrection] = []
    /// `epochDetector.ts LAUNCH_MS` — a correction older than the launch describes the wiped beta
    /// character that shares this log file. A correction is the one combo state outliving a replay.
    private let launchMs: Int64
    /// The spell → class table, built once from the parser's own DB (see `ComboTypes.swift`).
    private let spellClasses: SpellClassIndex
    /// The revision — see the header. Never a LogEvent seq.
    private var rev: Int64 = 0

    public init(spellClasses: SpellClassIndex, launchMs: Int64) {
        self.spellClasses = spellClasses
        self.launchMs = launchMs
    }

    /// Anything that can change what the intervals will be goes through here: an observation, a
    /// level ding, a reset, a correction written or withdrawn. It advances the revision the transport
    /// dedupes on, so no state change can go untold.
    ///
    /// The TS's memo of the built intervals is deliberately not ported: `buildIntervals` is a pure
    /// total function of the four inputs, so a cache would be a second place for the answer to live.
    private func markStale() { rev += 1 }

    public func reset() {
        observations.removeAll()
        whoRows.removeAll()
        levels.removeAll()
        markStale()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        if ev.kind == "epoch" {
            // Character rebirth: observations before the boundary belong to a dead character. Note
            // what is deliberately absent — a level-regression epoch trigger. A level drop is a
            // loadout swap, which is the whole point of this module.
            let launch = launchMs
            reset()
            corrections = corrections.filter { $0.startTs >= launch }
            return
        }
        if ev.kind == "level" {
            levels.append(LevelPoint(ts: ev.ts, level: ev.int(.level) ?? 0))
            markStale()
            return
        }
        if ev.kind == "selfWho" {
            let classes = whoClasses(ev)
            if !classes.isEmpty {
                whoRows.append(WhoRow(ts: ev.ts, seq: ev.seq, classes: classes, level: ev.int(.level) ?? 0))
            }
        }
        guard let observation = classObservation(spellClasses, ev) else { return }
        observations.append(observation)
        markStale()
    }

    /// The same cursor `snapshot` publishes, without building the state to read it.
    public var publishedSeq: Int64? { rev }

    public func snapshot() -> JSONValue {
        let intervals = buildIntervals(IntervalInput(observations: observations, whoRows: whoRows,
                                                     levels: levels, corrections: corrections))
        // `current` is the last interval, or null — the same object, never a second reading.
        let current = intervals.last
        return ["seq": .int(rev),
                "state": ["intervals": .array(intervals.map(\.json)),
                          "current": current?.json ?? .null,
                          // Data availability, not health: an empty stance table would silently turn
                          // every inference into an unknown slot, so the UI says "not ready".
                          "ready": .bool(comboTablesReady())]]
    }

    public var asDefines: Defines? { self }

    // MARK: - Defines

    public var family: String { "combo" }

    /// `comboModule.setCorrectionsProvider(…)`'s answer, pushed.
    ///
    /// It must mark stale: a correction re-labels an arbitrary span and advances no log seq, so a
    /// reader deduping on `seq` would drop the very push that carries it.
    ///
    /// A correction is refused whole, never filtered: one to three distinct class codes out of the
    /// closed set, a start at or after the launch epoch, and an end that is either absent or not
    /// before the start. The engine is a second door onto state `ipc/combo.ts` validates too.
    public func define(_ payload: JSONValue) {
        guard let list = payload.array else { return }
        corrections = list.compactMap { ComboModule.readCorrection($0, launchMs) }
        markStale()
    }

    /// One pushed `ComboCorrection`, validated. See `define` above for the rule.
    static func readCorrection(_ v: JSONValue, _ launchMs: Int64) -> ComboCorrection? {
        guard let startTs = v["startTs"].int64 else { return nil }
        if startTs < launchMs { return nil }
        var endTs: Int64? = nil
        if !v["endTs"].isNull {
            guard let end = v["endTs"].int64 else { return nil }
            if end < startTs { return nil }
            endTs = end
        }
        guard let raw = v["classes"].array else { return nil }
        if raw.isEmpty || raw.count > maxComboSlots { return nil }
        var classes: [ClassAbbr] = []
        for c in raw {
            guard let s = c.string, let abbr = asClassAbbr(s) else { return nil }
            // Deduped by refusal, not by filtering: `[ENC, ENC]` is not a one-class loadout, it is a
            // payload the app's own validator would have rejected.
            if classes.contains(abbr) { return nil }
            classes.append(abbr)
        }
        guard let setAt = v["setAt"].int64 else { return nil }
        return ComboCorrection(startTs: startTs, endTs: endTs, classes: classes, setAt: setAt)
    }
}

// MARK: - Checkpoint

extension ComboModule: FoldCheckpointable {
    /// `corrections` are app-pushed defines and, like the roster\'s edits, survive `reset()` — the
    /// blob still carries and reassigns them, because the blob is the truth. `rev` is the published
    /// seq and is carried. `launchMs`/`spellClasses` are constructor deps and are not.
    public func checkpointState() -> JSONValue {
        .object([
            "observations": .array(observations.map { o in
                .object(["ts": .int(o.ts), "seq": .int(o.seq), "source": .string(o.source),
                         "label": .string(o.label),
                         "candidates": .array(o.candidates.map { .string($0) }),
                         "weight": .double(o.weight)])
            }),
            "whoRows": .array(whoRows.map { w in
                .object(["ts": .int(w.ts), "seq": .int(w.seq),
                         "classes": .array(w.classes.map { .string($0) }), "level": .int(w.level)])
            }),
            "levels": .array(levels.map { .object(["ts": .int($0.ts), "level": .int($0.level)]) }),
            "corrections": .array(corrections.map { c in
                var o: [String: JSONValue] = ["startTs": .int(c.startTs),
                                              "classes": .array(c.classes.map { .string($0) }),
                                              "setAt": .int(c.setAt)]
                if let e = c.endTs { o["endTs"] = .int(e) }
                return .object(o)
            }),
            "rev": .int(rev),
        ])
    }

    public func restoreCheckpoint(_ state: JSONValue) -> Bool {
        reset()
        guard let obs = state["observations"].array, let who = state["whoRows"].array,
              let lvl = state["levels"].array, let corr = state["corrections"].array,
              let savedRev = state["rev"].int64 else { return false }
        var decodedObs: [ClassObservation] = []
        for v in obs {
            guard let ts = v["ts"].int64, let seq = v["seq"].int64, let source = v["source"].string,
                  let label = v["label"].string, let cands = v["candidates"].array,
                  let weight = v["weight"].double else { return false }
            decodedObs.append(ClassObservation(ts: ts, seq: seq, source: source, label: label,
                                               candidates: cands.compactMap(\.string), weight: weight))
        }
        var decodedWho: [WhoRow] = []
        for v in who {
            guard let ts = v["ts"].int64, let seq = v["seq"].int64,
                  let classes = v["classes"].array, let level = v["level"].int64 else { return false }
            decodedWho.append(WhoRow(ts: ts, seq: seq, classes: classes.compactMap(\.string), level: level))
        }
        var decodedLvl: [LevelPoint] = []
        for v in lvl {
            guard let ts = v["ts"].int64, let level = v["level"].int64 else { return false }
            decodedLvl.append(LevelPoint(ts: ts, level: level))
        }
        var decodedCorr: [ComboCorrection] = []
        for v in corr {
            guard let start = v["startTs"].int64, let classes = v["classes"].array,
                  let setAt = v["setAt"].int64 else { return false }
            decodedCorr.append(ComboCorrection(startTs: start, endTs: v["endTs"].int64,
                                               classes: classes.compactMap(\.string), setAt: setAt))
        }
        observations = decodedObs
        whoRows = decodedWho
        levels = decodedLvl
        corrections = decodedCorr
        rev = savedRev
        return true
    }
}
