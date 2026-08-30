// Port of fold/src/modules/kills.rs — the KillMap, plus the pure core it reuses (`isCountedKill`,
// `recordKill`, `killTotals`).
//
// The four scalars are derived, never incremented: `tiers` is the record and `killTotals` folds it
// after every write, so `bestTier` and `lastTs` cannot describe two different kills.
//
// The credit join carries progression's exact semantics: an experience line claims BACKWARD inside
// `killExpJoinMs`, a claim CONSUMES the line, and every death line consumes — including the ones
// this module does not count. An unclaimed older line is replaced rather than kept: a stale line
// handed to a later kill is a fabricated attribution.
//
// The tier is the zone you were standing in. `zone ?? ""` is a real answer rather than a fallback:
// a kill folded before the first `You have entered` may not claim d0, and `zoneTier("")` is
// `tierUnknown` for exactly that.
//
// A bare zone name is not always the open world — a base-difficulty raid or personal instance
// prints the same bare line the open world does. So this module remembers the creating-instance
// notice. Four properties keep the memory honest: it is EVIDENCE, not proximity (a later bare
// re-entry with no fresh notice still stamps d0); it overrides `tierOpenWorld` and nothing else; it
// expires, checked at use so nothing has to sweep; and it is character-scoped, cleared by the epoch
// alongside the KillMap.
import Foundation
import EQLog
import EQCompanionCore

/// `shared/kills.ts KILLS_SHAPE_VERSION`.
private let killsShapeVersion: Int64 = 5

/// `shared/kills.ts KILL_EXP_JOIN_MS` — how far back a kill line may reach for the exp line that
/// credits it. Measured at 0–1 s; 2.5 s is slack over the observed spread, not a hunt.
private let killExpJoinMs: Int64 = 2500

/// How long a remembered creating-instance notice keeps answering for its zone. Seven days is the
/// weekly lockout period — a bound on a memory, not a measurement.
private let instanceNoticeTtlMs: Int64 = 7 * 24 * 60 * 60 * 1000

public final class KillsModule: EqModule {
    public let id = "kills"

    private struct KillTierRun {
        var count: Int64
        var firstTs: Int64
        var lastTs: Int64
        var credited: Int64
        var lastCreditedTs: Int64
        var json: JSONValue {
            ["count": .int(count), "firstTs": .int(firstTs), "lastTs": .int(lastTs),
             "credited": .int(credited), "lastCreditedTs": .int(lastCreditedTs)]
        }
    }

    private struct KillInfo {
        var count: Int64
        var bestTier: Int64
        var firstTs: Int64
        var lastTs: Int64
        var credited: Int64
        var display: String
        var tiers: JSMap<KillTierRun>
        var json: JSONValue {
            ["count": .int(count), "bestTier": .int(bestTier), "firstTs": .int(firstTs),
             "lastTs": .int(lastTs), "credited": .int(credited), "display": .string(display),
             "tiers": tiers.json(\.json)]
        }
    }

    private var kills = JSMap<KillInfo>()
    private var zone: String?
    private var seq: Int64 = 0
    /// The experience line the next kill line may claim — the timestamp is all this module needs.
    private var pendingExpTs: Int64?
    /// The instance memory — `zoneIdKey` of a zone seen to have an instance created, against the
    /// timestamp of the most recent such notice. A plain dictionary: nothing publishes it, so no
    /// iteration order of it is observable.
    private var instances: [String: Int64] = [:]
    /// The announce cursor. Only a recorded kill and a rebirth change the KillMap, which is the
    /// whole of `snapshot()`; the other four arms mutate state nobody reads.
    private var announce = Announce()

    public init() {}

    /// The experience line this kill line claims, if any. Claiming CONSUMES it.
    private func takeExp(_ ts: Int64) -> Bool {
        guard let at = pendingExpTs else { return false }
        pendingExpTs = nil
        return ts >= at && ts - at <= killExpJoinMs
    }

    /// Is there a live creating-instance notice for this zone at `ts`?
    ///
    /// Reading rather than consuming, unlike `takeExp` beside it: an experience line credits exactly
    /// one kill, while one instance holds a whole evening's clear.
    private func insideARememberedInstance(_ zone: String, _ ts: Int64) -> Bool {
        guard let at = instances[JSFn.zoneIdKey(zone)] else { return false }
        return ts >= at && ts - at <= instanceNoticeTtlMs
    }

    /// `shared/kills.ts killTotals` — the five scalars, folded from the per-tier runs.
    ///
    /// `bestTier` seeds at the floor of the key ordering, not at 0: a record whose only runs are
    /// open-world has no difficulty to report. Iteration order cannot move any of these.
    private func killTotals(_ tiers: JSMap<KillTierRun>) -> (Int64, Int64, Int64, Int64, Int64) {
        var count: Int64 = 0
        var bestTier = JSFn.tierUnknown
        var firstTs: Int64 = 0
        var lastTs: Int64 = 0
        var credited: Int64 = 0
        for (key, run) in tiers.pairs {
            if run.count <= 0 { continue }
            count += run.count
            bestTier = max(bestTier, Int64(key) ?? 0)
            firstTs = firstTs != 0 ? min(firstTs, run.firstTs) : run.firstTs
            lastTs = max(lastTs, run.lastTs)
            credited += run.credited
        }
        return (count, bestTier, firstTs, lastTs, credited)
    }

    /// `main/log/reducers.ts recordKill`, in place.
    private func recordKill(key: String, display: String, tier: Int64, ts: Int64, credited: Bool) {
        var k = kills[key] ?? KillInfo(count: 0, bestTier: 0, firstTs: 0, lastTs: 0, credited: 0,
                                       display: display, tiers: JSMap<KillTierRun>())
        let tierKey = String(tier)
        var run = k.tiers[tierKey] ?? KillTierRun(count: 0, firstTs: ts, lastTs: ts, credited: 0, lastCreditedTs: 0)
        run.count += 1
        run.firstTs = min(run.firstTs, ts)
        run.lastTs = max(run.lastTs, ts)
        if credited {
            run.credited += 1
            // A max, not an assignment: a replay is chronological, but a fold must not depend on it.
            run.lastCreditedTs = max(run.lastCreditedTs, ts)
        }
        k.tiers.insert(tierKey, run)
        let (count, bestTier, firstTs, lastTs, cred) = killTotals(k.tiers)
        k.count = count
        k.bestTier = bestTier
        k.firstTs = firstTs
        k.lastTs = lastTs
        k.credited = cred
        kills.insert(key, k)
    }

    public func reset() {
        kills.clear()
        zone = nil
        seq = 0
        pendingExpTs = nil
        instances.removeAll()
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kind {
        case "epoch":
            // Character rebirth: the KillMap belongs to the dead character, and so do the instances
            // it stood in — a notice names a player, and that player is gone.
            kills.clear()
            pendingExpTs = nil
            instances.removeAll()
            announce.changed(seq)
            return
        case "zone":
            zone = ev.str(.zone)
            return
        case "instanceCreate":
            if let z = ev.str(.zone) {
                // A max, not an assignment: a late older notice must not un-refresh the entry.
                let key = JSFn.zoneIdKey(z)
                instances[key] = max(instances[key] ?? ev.ts, ev.ts)
            }
            return
        case "expGain":
            pendingExpTs = ev.ts
            return
        case "death": break
        default: return
        }
        // Consumed BEFORE the counted filter, as progression does: the line belongs to the kill it
        // precedes whoever landed the blow, and leaving it pending would hand your experience to
        // the next mob that dies near you.
        let credited = takeExp(ev.ts)
        if !isCountedKill(ev) { return }
        let z = zone ?? ""
        var tier = JSFn.zoneTier(z).1
        // The narrow override — see the header. Only this one answer moves.
        if tier == JSFn.tierOpenWorld && insideARememberedInstance(z, ev.ts) { tier = 0 }
        // Key by the canonical lowercase name so the two casings EQ emits for one mob fold into a
        // single entry; keep the raw name for display.
        let name = ev.str(.name) ?? ""
        recordKill(key: Names.idKey(name), display: name, tier: tier, ts: ev.ts, credited: credited)
        announce.changed(seq)
    }

    /// Moves on a counted kill, or a rebirth. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue {
        ["seq": .int(seq), "state": ["v": .int(killsShapeVersion), "mobs": kills.json(\.json)]]
    }
}

/// `main/log/reducers.ts isCountedKill` — self-slain always counts; slain-by counts only when the
/// killer isn't you.
private func isCountedKill(_ ev: Event) -> Bool {
    if ev.bool(.bySelf) { return true }
    // An empty killer string is falsy in the TS and does not disqualify.
    if let killer = ev.str(.killer), !killer.isEmpty { return !JSFn.startsWithYouWord(killer) }
    return true
}
