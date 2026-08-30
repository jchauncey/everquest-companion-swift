// Port of fold/src/modules/combo/evidence.rs — evidence intake.
//
// Pure: one event in, at most one `ClassObservation` out, looked up in the committed tables of
// `ComboTypes.swift`. No state; the module shell owns the ring.
//
// There is no clicky suppression, and its absence is deliberate. `Your <item> shimmers briefly.`
// does NOT mean an item cast the next line's spell: every item measured that prints it is a FOCUS
// item, worn, announcing itself when it modifies a spell YOU are casting. Reading it the other way
// discarded 44% of the player's own casts in a whole-log sweep. A genuine stray item cast is
// rejected by the admission ranking in `ComboScore.swift`, not by an intake rule.
//
// Measured coverage is a hard "say what the log cannot say" boundary: BER, MNK and WAR have
// literally zero spells and ROG has nine, so three of sixteen classes are invisible to cast
// evidence. Skill-ups, stances and poison coats are the only way to see them.
import Foundation
import EQLog
import EQCompanionCore

/// Source weights (§ 4.2). `who` is zero on purpose: a `/who` row is not scored, it OVERRIDES.
///
/// The ordering encodes how much each family can lie — a poison coat is ROG by game design, a
/// stance or skill is class-gated by the client, an invocation is class-gated but several span a
/// dozen classes, and a cast is weakest of all (items cast, charmed pets cast, volume overwhelms
/// truth).
func sourceWeight(_ source: String) -> Double {
    switch source {
    case "who": return 0.0
    case "poisonCoat": return 3.0
    case "stance": return 2.5
    case "skillUp": return 2.5
    case "invocation": return 1.5
    default: return 1.0 // 'cast'
    }
}

/// One atomic piece of evidence, before it is folded into a slot.
public struct ClassObservation {
    public var ts: Int64
    public var seq: Int64
    public var source: String
    /// display key: `Frenzy`, `berserker`, `Mesmerization`.
    public var label: String
    /// Classes consistent with this observation. Exactly one ⇒ exclusive ⇒ decisive.
    public var candidates: [ClassAbbr]
    /// Source weight, precomputed so scoring is a pure sum.
    public var weight: Double

    public init(ts: Int64, seq: Int64, source: String, label: String, candidates: [ClassAbbr], weight: Double) {
        self.ts = ts
        self.seq = seq
        self.source = source
        self.label = label
        self.candidates = candidates
        self.weight = weight
    }
}

/// The classes that can cast `spell`. spells.json first — it is the authority on anything with a
/// spell page — then the ability table. Never a union: where the two disagree, the spell page wins.
func castCandidates(_ index: SpellClassIndex, _ spell: String) -> [ClassAbbr] {
    let key = Names.spellCanonKey(spell)
    if let fromDb = index[key], !fromDb.isEmpty { return fromDb }
    return comboTables.abilities[key] ?? []
}

/// One observation, or `nil` when the event says nothing about class.
private func make(_ ev: Event, _ source: String, _ label: String, _ candidates: [ClassAbbr]) -> ClassObservation? {
    if candidates.isEmpty { return nil }
    // `[...new Set(candidates)].sort()` — dedupe in first-seen order, then sort.
    var deduped: [ClassAbbr] = []
    for c in candidates where !deduped.contains(c) { deduped.append(c) }
    deduped.sort()
    return ClassObservation(ts: ev.ts, seq: ev.seq, source: source, label: label,
                            candidates: deduped, weight: sourceWeight(source))
}

/// `ev.classes.filter(isClassAbbr)` — the `/who` row's own three-letter codes.
public func whoClasses(_ ev: Event) -> [ClassAbbr] {
    ev.arrStr(.classes).compactMap(asClassAbbr)
}

/// Turn one event into class evidence. Context-free — every input it needs is on the event, which is
/// what keeps it pure.
public func classObservation(_ index: SpellClassIndex, _ ev: Event) -> ClassObservation? {
    switch ev.kind {
    case "selfWho":
        return make(ev, "who", "who", whoClasses(ev))
    case "stanceChange":
        let stance = ev.str(.stance) ?? ""
        return make(ev, "stance", stance, comboTables.stances[stance] ?? [])
    case "invocationChange":
        let inv = ev.str(.invocation) ?? ""
        return make(ev, "invocation", inv, comboTables.invocations[inv] ?? [])
    case "skillUp":
        // `skills` only — see the header. An unlisted skill (every `Specialize <school>`, which the
        // wiki carries as one "Specialization" row) yields nothing rather than a guess.
        let skill = ev.str(.skill) ?? ""
        return make(ev, "skillUp", skill, comboTables.skills[skill] ?? [])
    case "poisonCoat":
        // Only rogue poison disciplines exist on Legends. Somebody else's blades — the third-person
        // shapes — say nothing about this character.
        if ev.str(.who) != "you" { return nil }
        return make(ev, "poisonCoat", ev.str(.poison) ?? "", ["ROG"])
    case "castBegin":
        let spell = ev.str(.spell) ?? ""
        // The display label strips the Roman rank and trims; `spellCanonKey` does the same and
        // lowercases, which is why the two are separate calls.
        let label = JS.trim(Names.stripRankTail(spell))
        return make(ev, "cast", label, castCandidates(index, spell))
    default:
        return nil
    }
}
