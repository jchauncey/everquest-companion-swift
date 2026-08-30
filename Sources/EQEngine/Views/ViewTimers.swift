// `timers.rows` — one source for both floating timer windows, as there is one projection for both:
// two windows placed and enabled separately, not two models (engined/src/views/timers.rs). Which
// window a row belongs to is the `surface` cell and field, so a subscription filters
// `{"surface":"debuffs"}` for that window's rows.
//
// The rows come from the fold's timer-row projection; everything here is the cell layer over it.
//
// The renderer draws these rows in one of two orders and neither is a sort by a column — the
// grouped order blocks by target, the flat order ranks countdowns ahead of count-ups ahead of
// permanents before comparing any instant. So the source publishes both as integer fields (`order`,
// `flat`), each the row's index in that order, computed once per serve pass by the projection that
// owns the rule. Both are unique within the view, so either makes the sort total on its own;
// `order` is the tiebreak because it is the projection's.
//
// There is no `remaining` cell. A countdown reads a different number every frame, so serving it as
// text would mean a diff per visible row per serve beat and would still be stale between two
// frames. What crosses is `startedTs`, `durationMs` and `mode` — the three numbers the reading is a
// pure function of, and what the overlay already ticks against.
//
// `endsAt` is served: it is a fact about the row (`startedTs + durationMs`) rather than about now,
// it is what the early-warning offset is computed from, and it is what a client sorts by for "what
// breaks next" without knowing this file's ranking rules.
import Foundation
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Timers {
        /// The registry entry. See `SourceDef`.
        public static let rowsSource = SourceDef(
            id: "timers.rows",
            fields: ["order", "flat", "surface", "kind", "group", "mode", "name", "target",
                     "targetKey", "startedTs", "endsAt", "caster"],
            // The projection's own order — self rows, then target blocks.
            defaultSort: [("order", .asc)],
            tiebreak: ("order", .asc),
            // The surface's own number rather than the house default: these are floating windows over a
            // running game and nobody has fifty buffs. A client that wants more asks, up to `maxLimit`.
            defaultLimit: 100)

        /// Build every timer row, in the projection's grouped order.
        ///
        /// The key is the projection's own id (`self|self|clarity`), already built to be stable across
        /// ticks. Inventing a second identity here would be a second thing that can disagree about
        /// whether two frames describe the same bar.
        public static func rows(_ buffs: BuffsModule, _ timers: BuffTimersModule) -> [SourceRow] {
            let built = buildTimerRows(active: buffs.activeBuffs(), holds: timers.holds(), ends: timers.ends())

            // The flat order as a lookup from row id to position, computed once for the whole source: it
            // is one more sort of a list already in memory.
            var flat: [String: Int64] = [:]
            for (i, r) in orderTimerRows(built, groupByTarget: false).enumerated() { flat[r.id] = Int64(i) }

            return built.enumerated().map { index, row in
                let order = Int64(index)
                let flatAt = flat[row.id] ?? order
                return SourceRow(key: row.id, cells: cells(row, order, flatAt),
                                 fields: fields(row, order, flatAt))
            }
        }

        /// What the bar draws.
        static func cells(_ row: BuffTimerRow, _ order: Int64, _ flat: Int64) -> [String: JSONValue] {
            [
                "name": .string(row.name),
                // The rank chip, not the raw cast name: `castName` is only ever shown as the difference
                // between the two spellings, and `rowRankLabel` is the function that decides whether
                // there is one.
                "rank": rowRankLabel(row.name, row.castName).map { .string($0) } ?? .null,
                "kind": .string(row.kind.rawValue),
                "surface": .string(timerRowSurface(row).rawValue),
                "group": .string(row.group.rawValue),
                "mode": .string(row.mode.rawValue),
                "ambiguous": .bool(row.ambiguous),
                "calmsTarget": .bool(row.calmsTarget),
                "inferredTarget": .bool(row.inferredTarget),
                "startedTs": .int(row.startedTs),
                "durationMs": row.durationMs.map { .int($0) } ?? .null,
                "endsAt": timerEndsAt(row).map { .int($0) } ?? .null,
                "target": optionalCell(row.target),
                "targetKey": optionalCell(row.targetKey),
                "count": row.count.map { .int($0) } ?? .null,
                "caster": optionalCell(row.caster),
                "order": .int(order),
                "flat": .int(flat)
            ]
        }

        /// What a descriptor may name. `candidates` is absent from both the cells and the fields by
        /// decision: a cell is a scalar, and the row's `name` is already those names joined the way the
        /// bar draws them while `ambiguous` is the flag the `~` chip reads. The per-candidate list is
        /// what the allow-list filter asks about, and that is a window preference rather than a query.
        static func fields(_ row: BuffTimerRow, _ order: Int64, _ flat: Int64) -> [(String, Field)] {
            [
                ("order", .int(order)),
                ("flat", .int(flat)),
                ("surface", .text(timerRowSurface(row).rawValue)),
                ("kind", .text(row.kind.rawValue)),
                ("group", .text(row.group.rawValue)),
                ("mode", .text(row.mode.rawValue)),
                ("name", .text(row.name)),
                ("target", textOrMissing(row.target)),
                ("targetKey", textOrMissing(row.targetKey)),
                ("startedTs", .int(row.startedTs)),
                ("endsAt", timerEndsAt(row).map { Field.int($0) } ?? .missing),
                ("caster", textOrMissing(row.caster))
            ]
        }
    }
}
