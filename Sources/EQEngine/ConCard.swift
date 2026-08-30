// The con card, resolved in this process: the engine emits a fully resolved card and the app only
// opens the window. Port of engined/src/concard.rs. This file takes the facts the consider module
// saw and produces the card payload field for field.
//
// The header is whole; the resist chips are the empty five and `spellData` is false. That is not a
// stub — it is the branch the app itself takes when the client's `spells_us.txt` has not been read,
// and the flag beside them is what tells the card why.
//
// Three refusals in three places. A historical line is refused one layer down: the consider module
// only pushes when live, so a startup replay emits nothing. The re-open suppression stays with the
// window that owns it — it is a fact about the PERSON, measured on the wall clock they live on, and
// its only input is a window event the fold never sees. The player refusal is here:
// `isPlayerShapedName(name) && !knownMob(name)`, because EQ gives players one capitalized word and
// mobs an article plus a noun phrase, and the committed mob catalog is what rescues the
// proper-named NPCs that shape alone would condemn.
//
// It asks `knownMob` and not `mob`: a lookup writes the name to the miss ledger and announces it,
// and this question is asked about names that are very often people.
//
// The residual is deliberate: a proper-named NPC the catalog has never heard of gets no card. A
// card that fails to appear costs a keystroke; a card over another player's head must never happen.
//
// The spell table is parsed inside this process for its own joins and never served as a bulk frame:
// measured at 48,252 entries and 6.13 MiB of JSON against an 8 MiB frame ceiling, on a table that
// grows with every client patch. App consumers ask per-spell `knowledge.spell` queries instead.
import Foundation
import EQCompanionCore
import EQFold

public enum ConCard {
    /// How long a mob name this engine will put on a card.
    ///
    /// A rendering guarantee rather than taste: a 40 kB mob name cannot push a card off the screen.
    /// Characters, not bytes — the app counts UTF-16 code units and this counts scalar values,
    /// which agree for every name EQ prints.
    static let maxNameChars = 96

    /// The five axes, in display order, which is part of the contract: every surface shows all
    /// five, because "we have not seen fire cast on this" and "fire is fine" are different
    /// statements and a missing chip says neither.
    public static let axes = ["magic", "fire", "cold", "poison", "disease"]

    /// The display name: whitespace-collapsed, trimmed, capped.
    public static func cappedName(_ name: String) -> String {
        let collapsed = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(String.UnicodeScalarView(collapsed.unicodeScalars.prefix(maxNameChars)))
    }

    /// The empty chip for one axis.
    ///
    /// Every number is a real zero and the three optional members are absent: nothing has been
    /// observed on this axis, so a chip carrying a tag would be the model inventing an answer.
    static func blankChip(_ axis: String) -> JSONValue {
        .object([
            "axis": .string(axis),
            "pinned": .bool(false),
            "empirical": .object(["total": .int(0), "resisted": .int(0)]),
            "npcOnly": .bool(false),
            "n": .int(0),
            "nTotal": .int(0)
        ])
    }

    /// The five chips this engine can honestly state. See the file header for why they are empty.
    public static func chips() -> [JSONValue] { axes.map(blankChip) }

    /// Is the thing the player just conned a person?
    ///
    /// The `knownMob` half is handed in so the rule can be driven from a test without a corpus, and
    /// so the one line that knows where the catalog lives stays at the call site.
    /// `isPlayerShapedName` is the fold's existing port rather than a second spelling of the two
    /// regexes.
    public static func isPlayer(_ name: String, knownMob: (String) -> Bool) -> Bool {
        isPlayerShapedName(name) && !knownMob(name)
    }

    /// Build the card one live `/con` deserves, or nil when the line names nothing — or names
    /// somebody.
    ///
    /// Two refusals: a creature name that folds to an empty mob key has no queue identity, so there
    /// is no card to refresh and none to open; and a person never gets one.
    public static func card(_ ev: ConEvent, _ knowledge: Knowledge) -> JSONValue? {
        let id = mobKey(ev.mob)
        if id.isEmpty { return nil }
        if isPlayer(ev.mob, knownMob: { knowledge.knownMob($0) }) { return nil }
        var o: [String: JSONValue] = [
            "kind": .string("conCard"),
            "at": .int(ev.ts),
            "id": .string(id),
            "name": .string(cappedName(ev.mob)),
            "chips": .array(chips()),
            "spellData": .bool(false)
        ]
        if let level = ev.level { o["level"] = .int(level) }
        if let zone = ev.zone { o["zone"] = .string(zone) }
        // Absent rather than false, which is the app payload's own shape.
        if ev.rare { o["rare"] = .bool(true) }
        return .object(o)
    }
}
