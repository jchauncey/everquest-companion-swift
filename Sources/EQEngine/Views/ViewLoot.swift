// `loot.ledger` — the chronological loot ledger, newest first, as the flat table draws it
// (engined/src/views/loot.rs). Rows come through the loot module's pull seam (`asLoot`), never
// through `snapshot()`.
//
// The cells are `at`, `item`, `count`, `from`, `zone`, `disposition`, `created` — one per thing the
// reader can see.
//
// The count is its own cell rather than composed into `item`. `2 × Bone Chips` is what the pixel
// says, but the composed string is lossy: every other reader of this row wants the name and the
// stack size separately, and splitting it back apart client-side is the munging the layer exists to
// prevent.
//
// An absent value is null, never `"-"`. The renderer's dash is a display decision about absence; a
// cell of `"-"` could not be told apart from an item genuinely called `-`, and it would cost this
// source the diff protocol's explicit-null clear.
//
// The timestamp is a fixed en-US pattern (`Aug 19, 04:21 PM`) rather than a locale call: a host
// locale anywhere in the serve path makes the answer a property of the machine, and determinism is
// cacheability — the same rule that forbids `localeCompare` in the sort. The time ZONE is not a
// locale and is honoured, through the parser's own clock, so the string says the wall clock the
// player's machine would show.
//
// One divergence from the Rust, in the seam and not in the answer: the Swift `LootModule.rows()`
// hands back the published JSON rows rather than a typed struct, so the fields are read by key.
import Foundation
import EQLog
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Loot {
        /// The registry entry. See `SourceDef`.
        public static let ledger = SourceDef(
            id: "loot.ledger",
            // `seq` is a field with no cell: the row's position in the append-only ledger, which is
            // what makes the order total. The `at` field is the instant in millis, not the string drawn
            // from it.
            fields: ["at", "seq", "item", "count", "from", "zone", "disposition"],
            // Newest first, which is what the flat ledger shows. The second term is what makes that
            // exact: EQ stamps to the second, so a corpse yielding three items writes three rows at one
            // instant, and reversing the ledger puts the last-folded of them first.
            defaultSort: [("at", .desc), ("seq", .desc)],
            tiebreak: ("seq", .asc),
            defaultLimit: Views.defaultLimit)

        /// Build every row of the ledger, in the module's own append order.
        ///
        /// The key is the row's position (`loot:<n>`), the only identity this ledger has: the module
        /// appends and never edits, so a position names one loot for as long as the ledger holds it. A
        /// rebirth boundary clears the ledger and positions start again — the module's revision counter
        /// is what handles that, by re-cutting the view and diffing.
        public static func rows(_ module: LootModule, _ clock: Clock) -> [SourceRow] {
            module.rows().enumerated().map { index, row in
                let at = row["ts"].int64 ?? 0
                let item = row["item"].string ?? ""
                let count = row["count"].int64
                let from = row["source"].string
                let zone = row["zone"].string
                let disposition = row["disposition"].string
                let created = row["created"].string
                return SourceRow(
                    key: "loot:\(index)",
                    cells: [
                        "at": .string(displayTime(clock, at)),
                        "item": .string(item),
                        "count": count.map { .int($0) } ?? .null,
                        "from": optionalCell(from),
                        "zone": optionalCell(zone),
                        "disposition": optionalCell(disposition),
                        "created": optionalCell(created)
                    ],
                    fields: [
                        ("at", .int(at)),
                        ("seq", .int(Int64(index))),
                        ("item", .text(item)),
                        ("count", count.map { Field.int($0) } ?? .missing),
                        ("from", textOrMissing(from)),
                        ("zone", textOrMissing(zone)),
                        ("disposition", textOrMissing(disposition))
                    ])
            }
        }

        /// The three-letter month names the en-US short form uses. ASCII and fixed, never a locale call.
        static let MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                             "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

        /// `Aug 19, 04:21 PM` — the en-US rendering of the app's time options, through the parser's zone.
        ///
        /// A ts of 0 renders empty, matching the app's `formatDate`: a falsy ts is an unknown timestamp,
        /// and a stamp the parser could not read is 0.
        public static func displayTime(_ clock: Clock, _ ms: Int64) -> String {
            if ms == 0 { return "" }
            guard let t = clock.civil(ms) else { return "" }
            let month = (t.month >= 1 && t.month <= 12) ? MONTHS[t.month - 1] : "???"
            // 12-hour with a leading zero, as `hour: '2-digit'` renders for en-US: midnight and noon
            // are 12, not 00.
            let meridiem = t.hour < 12 ? "AM" : "PM"
            let hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12
            return String(format: "%@ %02d, %02d:%02d %@", month, t.day, hour12, t.minute, meridiem)
        }
    }
}
