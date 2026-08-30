// `buffs.active` — the buffs tab's list (engined/src/views/buffs.rs).
//
// A second source rather than a filter over `timers.rows`: the bars draw a clock, the tab draws
// what the model knows about a buff (estimate, quartiles, observation count, provenance). One
// source would serve every reader the union.
//
// Cells are the row's own numbers and the model's enum words, never the sentences a buff row prints
// (`~4m 30s`, `n=12`, `at least`) — those are built by derivations the tab, the bars and the hover
// card share, and a wire carrying them would be a second copy of that vocabulary.
//
// `candidates` is not a cell because a cell is a scalar; `ambiguous` is the flag the `~` chip reads
// and `spell` is already the joined family.
import Foundation
import EQFold
import EQCompanionCore

public extension Views {
    /// See the file header.
    enum Buffs {
        /// The registry entry. See `SourceDef`.
        public static let active = SourceDef(
            id: "buffs.active",
            fields: ["key", "spell", "cls", "self", "target", "startedTs", "n", "permanent", "caster"],
            // Oldest first: the order the module publishes and the order the tab lists.
            defaultSort: [("startedTs", .asc)],
            tiebreak: ("key", .asc),
            defaultLimit: 100)

        /// Build a row per live instance.
        ///
        /// The key is the model's own instance key (`<spellKey>|<entityKey>`), handed over by
        /// `activeInstances()` rather than rebuilt from the projected fields.
        public static func rows(_ module: BuffsModule) -> [SourceRow] {
            module.activeInstances().map { key, b in
                SourceRow(key: key, cells: cells(b), fields: [
                    ("key", .text(key)),
                    ("spell", .text(b.spell)),
                    ("cls", .text(b.cls.rawValue)),
                    // A boolean is not a field, so `self` is filtered as a word: a numeric 0/1 would
                    // make `{"self":true}` a refusal and `{"self":1}` a query nobody would guess.
                    ("self", .text(yesNo(b.isSelf))),
                    ("target", textOrMissing(b.target)),
                    ("startedTs", .int(b.startedTs)),
                    ("n", .int(b.n)),
                    ("permanent", .text(yesNo(b.permanent == true))),
                    ("caster", textOrMissing(b.caster))
                ])
            }
        }

        static func cells(_ b: ActiveBuff) -> [String: JSONValue] {
            [
                "spell": .string(b.spell),
                "castName": optionalCell(b.castName),
                "cls": .string(b.cls.rawValue),
                "self": .bool(b.isSelf),
                "disposition": b.disposition.map { .string($0.rawValue) } ?? .null,
                "target": optionalCell(b.target),
                "inferredTarget": .bool(b.inferredTarget == true),
                "startedTs": .int(b.startedTs),
                "estimatedMs": b.estimatedMs.map { .int($0) } ?? .null,
                "p25": b.p25.map { .double($0) } ?? .null,
                "p75": b.p75.map { .double($0) } ?? .null,
                "n": .int(b.n),
                "durationSource": b.durationSource.map { .string($0.rawValue) } ?? .null,
                "permanent": .bool(b.permanent == true),
                "permanentSource": optionalCell(b.permanentSource),
                "messageDriven": .bool(b.messageDriven == true),
                "ambiguous": .bool(b.candidates != nil),
                "count": b.count.map { .int($0) } ?? .null,
                "caster": optionalCell(b.caster),
                "calmsTarget": .bool(b.calmsTarget == true)
            ]
        }

        /// A boolean as a queryable word — see the `self` field above.
        public static func yesNo(_ value: Bool) -> String { value ? "true" : "false" }
    }
}
