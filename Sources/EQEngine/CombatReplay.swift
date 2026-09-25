// A finished fight's full timeline, rebuilt from the log file on demand. NOT A PORT: the engine
// keeps a fight's event ring only for the last TIMELINE_HISTORY_CAP fights, but the log keeps every
// line, and a fight's start and end instants are enough to find its lines again (`LogWindow.scan`
// bisects the file on timestamps).
//
// The fight's stretch is folded through a throwaway fold — the same `FoldSink` an attach builds,
// with no state directory, so nothing is read from or written to disk but the log — starting
// `leadInMs` early so the context a fight depends on (your pet, a charm, the group) is established
// before its first swing. The replayed fight is the one whose start and end lie nearest the ones
// asked for; its timeline is returned in the snapshot's own shape.
//
// Nothing is kept: the fold is dropped with the answer.
import Foundation
import EQCompanionCore
import EQLog

enum CombatReplay {
    /// How much log before the fight is folded first, for context — an hour, so a pet inferred from
    /// your heals (PetInference.windowMs) is bound by the time the fight starts.
    static let leadInMs: Int64 = 60 * 60_000
    /// How far past the fight's last instant to read, so its closure is seen.
    static let tailMs: Int64 = 10_000
    /// The replayed fight must start within this of the asked start to be taken as the same fight.
    static let matchWithinMs: Int64 = 15_000

    static func timeline(log: URL, startTs: Int64, endTs: Int64, clock: Clock,
                         character: String?) -> JSONValue? {
        let sink = FoldSink(SinkInputs(log: log, character: character, db: SpellDb.shared(), clock: clock,
                                       attachedAtMs: 0, stateDir: nil))
        let parser = Parser(clock: clock, db: SpellDb.shared(), character: character)
        let ev = Ev(json: false)
        var seq: Int64 = 0
        let read = LogWindow.scan(log: log, from: startTs - leadInMs, to: endTs + tailMs, clock: clock) { line, _ in
            if parser.parseEvent(line, seq: seq, into: ev) {
                sink.event(IngestEvent(json: "", payload: ev.payload, seq: seq, live: false))
                seq += 1
            }
            return true
        }
        guard read, let all = sink.combatSnapshot(CombatOpts(maxSegments: 1_000_000)) else { return nil }
        let fights = (all.state["segments"].array ?? []).filter {
            let k = $0["kind"].string
            return k == "fight" || k == "current"
        }
        // Start AND end: two fights can open in the same second (a one-hit pull beside the real one),
        // so the start alone does not say which fight was asked for.
        func distance(_ s: JSONValue) -> Int64 {
            let st = s["startTs"].int64 ?? 0
            let en = st + Int64((s["durationSec"].double ?? 0) * 1000)
            return abs(st - startTs) + abs(en - endTs)
        }
        guard let best = fights.min(by: { distance($0) < distance($1) }),
              abs((best["startTs"].int64 ?? 0) - startTs) <= matchWithinMs,
              let id = best["id"].string,
              let snap = sink.combatSnapshot(CombatOpts(selectedId: id, maxSegments: 1, timeline: true)) else { return nil }
        let tl = snap.state["timeline"]
        return tl.isNull ? nil : tl
    }
}
