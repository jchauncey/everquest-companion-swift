// Port of fold/src/modules/turnins.rs — completed NPC trades / quest turn-ins.
//
// Offers accumulate per NPC until the matching "complete the trade" line closes the group. A trade
// with a DIFFERENT npc than the open offer group records nothing and still drops the group, which
// is the TS's exact shape (its `pendingOffer = null` sits outside the `if`).
import Foundation
import EQLog
import EQCompanionCore

public final class TurnInsModule: EqModule {
    public let id = "turnins"

    private struct TurnInRow {
        var ts: Int64
        var npc: String
        var items: [String]
        var json: JSONValue { ["ts": .int(ts), "npc": .string(npc), "items": .array(items.map { .string($0) })] }
    }

    private struct PendingOffer {
        var npc: String
        var items: [String]
    }

    private var turnIns: [TurnInRow] = []
    private var pendingOffer: PendingOffer?
    private var seq: Int64 = 0
    /// The announce cursor. `pendingOffer` is not published state: a handed-over item is a
    /// half-formed group nobody can read until the trade closes it.
    private var announce = Announce()

    public init() {}

    public func reset() {
        turnIns.removeAll()
        pendingOffer = nil
        seq = 0
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kind {
        // Character rebirth. A half-formed offer group goes with it.
        case "epoch":
            turnIns.removeAll()
            pendingOffer = nil
            announce.changed(seq)
        // An offer publishes nothing: it opens or extends the pending group, which is not in
        // `snapshot()`. Handing items to an NPC and walking away leaves the ledger as it was.
        case "offer":
            let npc = ev.str(.npc) ?? ""
            let item = ev.str(.item) ?? ""
            if pendingOffer?.npc == npc {
                pendingOffer?.items.append(item)
            } else {
                pendingOffer = PendingOffer(npc: npc, items: [item])
            }
        case "trade":
            let npc = ev.str(.npc) ?? ""
            if let open = pendingOffer {
                pendingOffer = nil
                if open.npc == npc {
                    turnIns.append(TurnInRow(ts: ev.ts, npc: open.npc, items: open.items))
                    announce.changed(seq)
                }
            }
        default: break
        }
    }

    /// Moves on the trade that CLOSED a group, not on every line that passed by. See `announce`.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": .array(turnIns.map(\.json))] }
}
