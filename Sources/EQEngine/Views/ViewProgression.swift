// `progression.recent` — the things that advanced, newest first: the progression module's level
// dings and AA gains read as one list (engined/src/views/progression.rs). Both columns are uncapped
// in the module because the chart needs every ding, so this is the one source whose underlying
// collection grows without bound.
//
// Its cells are the only ones in this registry not read off a component: the Leveling surfaces draw
// these columns as charts and stat panels, and the AA ledger is a different aggregation again. The
// cells are argued from the module's vocabulary instead — an instant, which of the two things
// happened, and the number that changed — which is a weaker source of truth and is stated as such.
//
// The instant is rendered here, unlike `kills.recent`'s: a kill is read against now, but a level
// ding is a dated event you scroll back through, so its cell is the same fixed en-US pattern
// `loot.ledger` renders, through the parser's own clock and never a host locale. The comparable
// instant is the `at` field.
import Foundation
import EQLog
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Progression {
        /// The registry entry. See `SourceDef`.
        public static let recent = SourceDef(
            id: "progression.recent",
            fields: ["at", "seq", "kind", "value"],
            defaultSort: [("at", .desc), ("seq", .desc)],
            tiebreak: ("seq", .asc),
            defaultLimit: Views.defaultLimit)

        /// One entry, before it is a row.
        struct Advance {
            var ts: Int64
            /// `"level"` or `"aa"`.
            var kind: String
            /// The level reached, or the AA points gained.
            var value: Int64
        }

        /// Build every advance the fold has recorded, in `(kind, fold order)` order.
        ///
        /// The key is `<kind>:<position>`, keyed per column: the two columns are appended
        /// independently, so one interleaved counter would renumber every AA gain the next time a level
        /// landed between two of them, and the diff would report every row changed when nothing did.
        public static func rows(_ module: ProgressionModule, _ clock: Clock) -> [SourceRow] {
            var out: [SourceRow] = []
            var seq: Int64 = 0
            for (index, l) in module.levels().enumerated() {
                out.append(row(Advance(ts: l.0, kind: "level", value: l.1), index, seq, clock))
                seq += 1
            }
            for (index, a) in module.aaGains().enumerated() {
                out.append(row(Advance(ts: a.0, kind: "aa", value: a.1), index, seq, clock))
                seq += 1
            }
            return out
        }

        static func row(_ advance: Advance, _ index: Int, _ seq: Int64, _ clock: Clock) -> SourceRow {
            SourceRow(
                key: "\(advance.kind):\(index)",
                cells: [
                    "at": .string(Views.Loot.displayTime(clock, advance.ts)),
                    "kind": .string(advance.kind),
                    "value": .int(advance.value),
                    // The composed line, composed here rather than left to the client because no shared
                    // app-side derivation exists for it to disagree with. The number is beside it as its
                    // own cell.
                    "label": .string(advance.kind == "level" ? "Level \(advance.value)" : "+\(advance.value) AA")
                ],
                fields: [
                    ("at", .int(advance.ts)),
                    ("seq", .int(seq)),
                    ("kind", .text(advance.kind)),
                    ("value", .int(advance.value))
                ])
        }
    }
}
