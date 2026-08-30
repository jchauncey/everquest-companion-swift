// `respawn.watches` — one row per watched mob per zone: when it comes back, and where that number
// came from (engined/src/views/respawn.rs).
//
// The order is a function of `now` (recently seen first, then unstale, then by remaining time), so
// no sort over a column can express it. The source publishes the module's own position as the
// integer field `order` instead, as `timers.rows` does: the decision stays engine-side and what
// crosses the wire is its answer.
//
// The instant behind that order is the module's own (`RespawnModule.nowMs`), never a fresh clock
// read. A second clock would order the rows against an instant the model has never seen, and would
// put a wall-clock read in the serve path.
//
// `gapsMs` — the recent measured gaps behind `observedMs` — is not a cell: a cell is a scalar, and
// joining the list into a string would only make the client split it back apart. The row carries
// the two numbers the provenance line reads (`observedMs`, `samples`); the gap list stays in
// `module.snapshot("respawn")`, where the drill-down already reads it.
import Foundation
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Respawn {
        /// The registry entry. See `SourceDef`.
        public static let watches = SourceDef(
            id: "respawn.watches",
            fields: ["order", "key", "display", "zone", "baseTs", "basis", "source", "samples",
                     "kills", "seenTs", "estimateMs"],
            defaultSort: [("order", .asc)],
            tiebreak: ("order", .asc),
            defaultLimit: Views.defaultLimit)

        /// Build the watch rows, in the module's own order.
        ///
        /// The key is the row's own id (`<zone key>::<mob key>`), which the module builds to be stable
        /// across ticks and files its history under. A mob watched in two zones is two rows and two
        /// clocks, which the compound id says and a bare mob key would not.
        public static func rows(_ module: RespawnModule) -> [SourceRow] {
            module.watchRows(module.nowMs()).enumerated().map { index, row in
                let order = Int64(index)
                return SourceRow(key: row.id, cells: cells(row, order), fields: [
                    ("order", .int(order)),
                    ("key", .text(row.key)),
                    ("display", .text(row.display)),
                    ("zone", .text(row.zone)),
                    ("baseTs", .int(row.baseTs)),
                    ("basis", .text(row.basis)),
                    ("source", .text(row.source)),
                    ("samples", .int(row.samples)),
                    ("kills", .int(row.kills)),
                    ("seenTs", row.seenTs.map { Field.int($0) } ?? .missing),
                    ("estimateMs", row.estimateMs.map { Field.int($0) } ?? .missing)
                ])
            }
        }

        static func cells(_ row: RespawnRow, _ order: Int64) -> [String: JSONValue] {
            [
                "display": .string(row.display),
                "key": .string(row.key),
                "zone": .string(row.zone),
                "baseTs": .int(row.baseTs),
                "basis": .string(row.basis),
                "source": .string(row.source),
                // `overridden` is the answer rather than the comparison: a client re-deriving it from
                // the `source` word beside it would hold a second copy of a rule that lives here.
                "overridden": .bool(row.source == "custom"),
                "samples": .int(row.samples),
                "kills": .int(row.kills),
                "seenTs": row.seenTs.map { .int($0) } ?? .null,
                "seenVia": optionalCell(row.seenVia),
                "estimateMs": row.estimateMs.map { .int($0) } ?? .null,
                "observedMs": row.observedMs.map { .int($0) } ?? .null,
                "customMs": row.customMs.map { .int($0) } ?? .null,
                "wikiText": optionalCell(row.wikiText),
                "wikiMs": row.wikiMs.map { .int($0) } ?? .null,
                "wikiPage": optionalCell(row.wikiPage),
                "order": .int(order)
            ]
        }
    }
}
