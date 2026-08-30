// Port of fold/src/modules/leveling.rs — level-ups, AA gains, AA spends and AA-potion quaffs, all
// four append-only and in log order (the unspent/net-spent math the view does depends on that
// order).
//
// The potion is deliberately not persisted: the quaff is a log line, so a relaunch replays it and
// re-derives the charge state exactly.
import Foundation
import EQLog
import EQCompanionCore

public final class LevelingModule: EqModule {
    public let id = "leveling"

    private var levels: [JSONValue] = []
    private var aaGains: [JSONValue] = []
    private var aaSpends: [JSONValue] = []
    private var aaPotions: [JSONValue] = []
    private var seq: Int64 = 0
    /// The announce cursor. Four arms append and a fifth clears; that is the whole of what this
    /// module publishes, and every other log line leaves it untouched.
    private var announce = Announce()

    public init() {}

    public func reset() {
        levels.removeAll()
        aaGains.removeAll()
        aaSpends.removeAll()
        aaPotions.removeAll()
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        // One bump for five arms, ahead of the match rather than inside each, because the arms are
        // exactly the mutations: four appends and a clear.
        switch ev.kind {
        case "epoch", "level", "aaGain", "aaSpend", "aaPotion": announce.changed(seq)
        default: break
        }
        switch ev.kind {
        // Character rebirth: the prior epoch's levels and AA belong to a dead same-name character,
        // and the AA identity (allocated/unspent/earned) holds only without them.
        case "epoch":
            levels.removeAll()
            aaGains.removeAll()
            aaSpends.removeAll()
            aaPotions.removeAll()
        case "level":
            levels.append(["ts": .int(ev.ts), "level": .int(ev.int(.level) ?? 0)])
        case "aaGain":
            aaGains.append(["ts": .int(ev.ts), "amount": .int(ev.int(.amount) ?? 0), "nowHave": .int(ev.int(.nowHave) ?? 0)])
        case "aaSpend":
            var row: [String: JSONValue] = ["ts": .int(ev.ts), "ability": .string(ev.str(.ability) ?? ""),
                                            "cost": .int(ev.int(.cost) ?? 0)]
            // Only the `You have improved X <rank>` shape states one; omitted otherwise.
            if let rank = ev.int(.rank) { row["rank"] = .int(rank) }
            aaSpends.append(.object(row))
        case "aaPotion":
            aaPotions.append(["ts": .int(ev.ts)])
        default: break
        }
    }

    /// Moves on a ding, an AA line or a rebirth. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue {
        ["seq": .int(seq),
         "state": ["levels": .array(levels), "aaGains": .array(aaGains),
                   "aaSpends": .array(aaSpends), "aaPotions": .array(aaPotions)]]
    }
}
