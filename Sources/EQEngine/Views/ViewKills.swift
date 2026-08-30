// `kills.recent` — the rows the Overview's recent-kills card draws: what you killed, when, where,
// and what the experience line beside it said (engined/src/views/kills.rs).
//
// Named for the surface rather than for the module, which is this registry's one exception. It
// reads `progression`, not `kills`: the `kills` module is a lifetime tally keyed by mob with no
// recent list at all, while the recent-kills ring lives beside `progression`'s columns because a
// kill and the experience line that follows it are joined at fold time and only that module sees
// both.
//
// `ProgressionKill.expFlag` is a bitfield (`1` no percentage stated, `2` party experience) and
// absent is a third state — no experience line at all. The row decomposes it into three booleans
// and a number so the card draws without arithmetic.
import Foundation
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Kills {
        /// `expFlag & 1` — the experience line stated no percentage.
        static let EXP_UNSTATED: Int64 = 1
        /// `expFlag & 2` — it was party experience.
        static let EXP_PARTY: Int64 = 2

        /// The registry entry. See `SourceDef`.
        public static let recent = SourceDef(
            id: "kills.recent",
            fields: ["at", "seq", "name", "zone", "pet", "expPct"],
            // Newest first, which is what the card draws.
            defaultSort: [("at", .desc), ("seq", .desc)],
            tiebreak: ("seq", .asc),
            // The card's own cap rather than the house default: the ring holds fifty and the card draws
            // twenty-five, so the house default would be payload nobody asked for.
            defaultLimit: 25)

        /// Build every row of the ring, in the module's own append order.
        ///
        /// The key is the ring position (`kill:<n>`). The ring drops from the front at fifty, so a
        /// position names a different kill after the fifty-first — the module's revision counter is what
        /// handles that, by re-cutting the view and diffing. The kill's `ts` cannot be the key: it is
        /// second-resolution and routinely repeats.
        public static func rows(_ module: ProgressionModule) -> [SourceRow] {
            module.recentKills().enumerated().map { index, kill in
                SourceRow(key: "kill:\(index)", cells: cells(kill), fields: [
                    ("at", .int(kill.ts)),
                    ("seq", .int(Int64(index))),
                    ("name", .text(kill.name)),
                    // A zone the fold never learned is missing, not an empty string: the module writes
                    // `''` before the first zone line, and unknown has to be a place in the order rather
                    // than a name that sorts before every real zone.
                    ("zone", kill.zone.isEmpty ? .missing : .text(kill.zone)),
                    ("pet", .text(Views.Buffs.yesNo(kill.credit == 1))),
                    ("expPct", kill.expPct.map(expField) ?? .missing)
                ])
            }
        }

        /// A percentage as a comparable value, in milli-percent: a field compares integers, and rounding
        /// to whole percent would put `0.9` and `0.1` in the same place in a column that is all
        /// fractions.
        static func expField(_ pct: Double) -> Field { .int(Int64(pct * 1000.0)) }

        static func cells(_ kill: ProgressionKill) -> [String: JSONValue] {
            // The three states of the experience line, kept apart: `expLine` false means there was none
            // at all, which is a different sentence from a line that stated no number.
            let flag = kill.expFlag
            return [
                "at": .int(kill.ts),
                "name": .string(kill.name),
                // An unknown zone is null, never `''`: the module writes an empty string into its
                // column, but on the wire an absent value has a spelling.
                "zone": kill.zone.isEmpty ? .null : .string(kill.zone),
                // `credit` is 0 for your killing blow and 1 for a bound pet's; the boolean is the
                // question the card's pet chip asks.
                "pet": .bool(kill.credit == 1),
                "expLine": .bool(flag != nil),
                "expStated": .bool(flag.map { $0 & EXP_UNSTATED == 0 } ?? false),
                "expParty": .bool(flag.map { $0 & EXP_PARTY != 0 } ?? false),
                "expPct": kill.expPct.map { .double($0) } ?? .null
            ]
        }
    }
}
