// Port of fold/src/modules/loot.rs — the self-loot history: a `LootEvent` tagged with the zone it
// happened in, append-only.
//
// A destroy rides the same row shape as every other disposition, which is why it was given a
// disposition rather than an event kind. This module takes no position on what any of them mean.
//
// Every optional field is omitted when absent, never written as `null`: the published shape came
// through `JSON.stringify`, which drops a key whose value is `undefined`. `zone` is the module's
// own state (the last zone line seen) and is absent for rows folded before the scan reached one.
import Foundation
import EQLog
import EQCompanionCore

public final class LootModule: EqModule {
    public let id = "loot"

    /// The ledger, oldest first — each row already in the JSON `snapshot()` publishes, so the view
    /// layer's `rows()` costs nothing to serve.
    private var loot: [JSONValue] = []
    private var zone: String?
    private var seq: Int64 = 0
    /// How a reader knows the ledger moved, without reading it. Bumped on every push and clear, and
    /// absent from `snapshot()`, so nothing published can see it.
    ///
    /// A length would nearly do — this vector only grows or empties — but a rebirth that clears 500
    /// rows and folds 500 more between two services would leave the length where it was.
    private var rev: UInt64 = 0
    /// The announce cursor. It follows the same two arms `revision` does, which are the only ones
    /// that touch `loot`.
    private var announce = Announce()

    public init() {}

    /// The rows in append order — the view layer's pull seam.
    public func rows() -> [JSONValue] { loot }

    /// A monotonic signal that moves whenever the ledger could have changed. See the field.
    public func revision() -> UInt64 { rev }

    public func reset() {
        loot.removeAll()
        zone = nil
        seq = 0
        rev += 1
        announce.reset()
    }

    public func onEvent(_ ev: Event, live: Bool) {
        seq = ev.seq
        switch ev.kind {
        // Character rebirth: loot before the boundary is a dead same-name character's. `zone`
        // is kept — it is world state, not character-scoped.
        case "epoch":
            loot.removeAll()
            rev += 1
            announce.changed(seq)
        // Not a change to published state: `zone` is the label the NEXT row will carry, and
        // `snapshot()` publishes `loot` alone.
        case "zone":
            zone = ev.str(.zone)
        case "loot":
            var row: [String: JSONValue] = ["ts": .int(ev.ts), "item": .string(ev.str(.item) ?? "")]
            if let source = ev.str(.source) { row["source"] = .string(source) }
            if let zone { row["zone"] = .string(zone) }
            if let disposition = ev.str(.disposition) { row["disposition"] = .string(disposition) }
            if let count = ev.int(.count) { row["count"] = .int(count) }
            if let created = ev.str(.created) { row["created"] = .string(created) }
            loot.append(.object(row))
            rev += 1
            announce.changed(seq)
        default: break
        }
    }

    /// The view layer's door onto this module.
    public var asLoot: LootModule? { self }

    /// Moves when the LEDGER moved, not when the log did. See the `announce` field.
    public var publishedSeq: Int64? { announce.cursor }

    public func snapshot() -> JSONValue { ["seq": .int(seq), "state": .array(loot)] }
}
