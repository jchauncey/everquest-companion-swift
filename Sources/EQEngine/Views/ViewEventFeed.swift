// `eventFeed.recent` — the events overlay's ring (engined/src/views/event_feed.rs).
//
// The row is the module's own feed entry, read field by field rather than through `snapshot()`'s
// JSON. Unlike the app's feed event there is no `reward` block: the quest source is not on the bus
// at all, and a cell for a block nothing fills would be a column that is null forever.
//
// A feed entry's `con` is an object, so it becomes prefixed cells (`conFaction`, `conLevel`, …)
// rather than a JSON string a client would have to parse. A nested cell is also not a thing the
// diff protocol can update — an update op carries changed cells, so a nested object would be re-sent
// whole every time one number inside it moved.
import Foundation
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum EventFeed {
        /// The registry entry. See `SourceDef`.
        public static let recent = SourceDef(
            id: "eventFeed.recent",
            fields: ["at", "seq", "kind", "title"],
            // Newest first — the overlay stores the ring oldest-last and reverses it to draw.
            defaultSort: [("at", .desc), ("seq", .desc)],
            tiebreak: ("seq", .asc),
            defaultLimit: Views.defaultLimit)

        /// Build a row per feed entry, in the ring's own order.
        public static func rows(_ module: EventFeedModule) -> [SourceRow] { rowsOf(module.ring()) }

        /// The projection itself, over a ring rather than over a module, so it can be tested directly.
        ///
        /// The key is the entry's own minted id (`f1`, `f2`, …), so two identical lines a second apart
        /// are two rows. A ring position would not do: the feed drops from the front at a hundred, so a
        /// position names a different event after the hundred-and-first.
        public static func rowsOf(_ ring: [FeedEvent]) -> [SourceRow] {
            ring.enumerated().map { index, entry in
                SourceRow(key: entry.id, cells: cells(entry), fields: [
                    ("at", .int(entry.ts)),
                    ("seq", .int(Int64(index))),
                    ("kind", .text(entry.kind)),
                    ("title", .text(entry.title))
                ])
            }
        }

        static func cells(_ entry: FeedEvent) -> [String: JSONValue] {
            let con = entry.con
            return [
                "at": .int(entry.ts),
                "kind": .string(entry.kind),
                "title": .string(entry.title),
                "detail": optionalCell(entry.detail),
                "page": optionalCell(entry.page),
                "conFaction": optionalCell(con?.faction),
                "conDifficulty": optionalCell(con?.difficulty),
                "conLevel": con?.level.map { .int($0) } ?? .null,
                // Absent and false are the same answer for `rare`, and only for `rare`: the parser
                // writes the flag only when the infix was on the line, so no con block and a con block
                // without it both mean not rare.
                "conRare": .bool(con?.rare == true)
            ]
        }
    }
}
