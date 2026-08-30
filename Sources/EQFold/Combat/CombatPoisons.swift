// The rogue poison roster, the half of it the FOLD needs (fold/src/combat/poisons.rs).
//
// The parser's own tables carry the MESSAGES (coat lines, dry lines, Strike emotes). What they do
// not carry is the roster's MECHANICS — which Strikes a poison grants, and which venoms replace
// which — and the engine needs both: the coat stack is keyed on the replacement line, the rolling
// time-to-slow sample is gated on the coat granting the slow Strike, and a poison lane's source
// window is the union of the coat spans of every poison granting one of its Strikes.
//
// FOUR CONCURRENT COATS is not a slot count the game enforces — it falls out of the roster. The
// five combat venoms form exactly three mutually-exclusive lines (asp, blood, stunning) plus the one
// utility slot. `line` is that grouping; keying the stack on the NAME would let Cobra sit beside Asp
// for a fourth venom.
//
// A Strike emote names no caster (law 6). `<mob>'s limbs move slower!` is Weakening Strike's landing
// message and nothing else's, but four poisons grant Weakening Strike, so a slow landing proves "a
// rogue slow proc" and never which poison.
import Foundation

/// One coatable poison, reduced to the two fields the fold reads.
public struct PoisonDef: Sendable {
    /// DB spell name — the display name and the catalog key.
    public let name: String
    /// Strike names this poison grants (wiki Rogue page). Drives `isSlowCapable` and the poison
    /// lane's source window.
    public let strikes: [String]
    /// Combat venoms only: the mutually-exclusive line this venom belongs to. Two venoms sharing a
    /// line replace one another; venoms on different lines stack. Utility poisons leave it empty.
    public let line: String
}

private func p(_ name: String, _ strikes: [String]) -> PoisonDef {
    PoisonDef(name: name, strikes: strikes, line: "")
}

private func v(_ name: String, _ strikes: [String], _ line: String) -> PoisonDef {
    PoisonDef(name: name, strikes: strikes, line: line)
}

/// The roster — 15 utility + 5 combat, exactly the two lists on the wiki's Rogue page.
public let POISONS: [PoisonDef] = [
    // utility: one at a time, a new utility coat replaces the old.
    p("Weakening Poison", ["Weakening Strike"]),
    p("Hobbling Poison", ["Hobbling Strike"]),
    p("Concussive Poison", ["Concussive Strike"]),
    p("Befuddling Poison", ["Befuddling Strike"]),
    p("Grounding Poison", ["Grounding Strike"]),
    p("Clumsiness Poison", ["Clumsiness Strike"]),
    p("Banishing Poison", ["Banishing Strike"]),
    p("Fettering Poison", ["Grounding Strike", "Hobbling Strike"]),
    p("Binding Poison", ["Weakening Strike", "Hobbling Strike"]),
    p("Neurotoxic Poison", ["Befuddling Strike", "Weakening Strike"]),
    p("Mind Wrack Poison", ["Concussive Strike", "Clumsiness Strike"]),
    p("Thought Drain Poison", ["Befuddling Strike", "Clumsiness Strike"]),
    p("Antimagic Poison", ["Concussive Strike", "Banishing Strike"]),
    p("Mage Bane Poison", ["Befuddling Strike", "Banishing Strike"]),
    p("Paralytic Poison", ["Weakening Strike", "Clumsiness Strike"]),
    // combat: stack across lines, and a line's two members replace each other.
    v("Blood Siphon Venom", ["Blood Siphon Strike"], "blood"),
    v("Asp Venom", ["Asp Venom Strike"], "asp"),
    v("Stunning Venom", ["Stunning Strike"], "stunning"),
    v("Blood Draw Venom", ["Blood Draw Strike"], "blood"),
    v("Cobra Venom", ["Cobra Venom Strike"], "asp"),
]

/// The Strike that prints `<mob>'s limbs move slower!` — the ONE proc this feature measures a
/// time-to-land for. Named once so the parser, the engine and the UI cannot drift.
public let SLOW_STRIKE = "Weakening Strike"

/// The dispel family — the one non-poison effect the Procs tab counts. The complete set in the
/// committed spell DB whose landing message contains "dispelled", across three message tiers each
/// shared by several spells (law 3), so a lane is labeled with every candidate and flagged
/// ambiguous: the count is exact, the name is not.
///
/// NOT a rogue proc: the rogue's own dispel proc (Banishing Strike) prints a different line and
/// lives in the Strike ledger.
public let DISPEL_FAMILY: [String] = [
    "Cancel Magic",
    "Phobocancel",
    "Neutralize Magic",
    "Nullify Magic",
    "Beholder Dispel",
    "Pillage Enchantment",
    "Strip Enchantment",
]

public func isDispelFamily(_ name: String) -> Bool { DISPEL_FAMILY.contains(name) }

private func poisonByName(_ poison: String) -> PoisonDef? {
    POISONS.first { $0.name == poison }
}

/// The exclusivity key for a coated poison — what the combat stack and the state timeline's
/// `coat:combat:<line>` group are keyed on. Falls back to the lowercased NAME for anything not in
/// the roster, so a future venom without a line becomes its own line rather than joining somebody
/// else's.
public func coatLineKey(_ poison: String) -> String {
    if let d = poisonByName(poison), !d.line.isEmpty { return d.line }
    return poison.lowercased()
}

/// True when coating this poison gives you a chance at the slow proc.
public func isSlowCapable(_ poison: String) -> Bool {
    poisonByName(poison)?.strikes.contains(SLOW_STRIKE) ?? false
}
