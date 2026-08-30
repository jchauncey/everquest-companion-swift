// Port of eqlog/src/parse/combat.rs — misses, mitigation, resists, the damage battery and heals.
//
// Every regex below is its app twin with three mechanical substitutions and no others: `\d` →
// `[0-9]`, `\w` → `[0-9A-Za-z_]` and `\s` → the ECMA class (see JSStr.swift). Those three are
// ASCII-only in JavaScript and Unicode-aware in the `regex` crate, and a mob name with a
// non-ASCII letter is exactly the line that would part company.
import Foundation

/// Every verb must match both first-person ("You slash") and third-person ("A mob slashes").
private let MELEE_VERBS = "hit(?:s)?|slash(?:es)?|pierce(?:s)?|crush(?:es)?|bash(?:es)?|kick(?:s)?|bite(?:s)?|claw(?:s)?|gore(?:s)?|maul(?:s)?|punch(?:es)?|strike(?:s)?|slice(?:s)?|backstab(?:s)?|slam(?:s)?|sting(?:s)?|rend(?:s)?|smash(?:es)?|gnaw(?:s)?|lash(?:es)?|smite(?:s)?|cleave(?:s)?|reave(?:s)?|shoot(?:s)?|frenzies on|frenzy on|flurries|flurry"

final class CombatRes {
    let melee: Re
    let meleeVerb: Re
    let spell: Re
    let ds: Re
    let dsInc: Re
    let dot: Re
    let dotNocaster: Re
    let heal: Re
    let mend: Re
    let runeGain: Re
    let skinAbsorbBlow: Re
    let skinAbsorbDs: Re
    let miss: Re
    let missVerb: Re
    let missMod: Re
    let resistYours: Re
    let resistCaster: Re
    let resistIncoming: Re
    let yourPrefix: Re
    let dotBy: Re
    let critical: Re
    let reflexive: Re
    let dsOwnerPoss: Re

    init() {
        melee = Re("^(.+?) (?:\(MELEE_VERBS)) (.+?) for ([0-9]+) points? of damage\\.(?: \\((.+?)\\))?$")
        meleeVerb = Re(" (\(MELEE_VERBS)) ")
        spell = Re("^(.+?) (?:hits?) (.+?) for ([0-9]+) points of ([0-9A-Za-z_-]+) damage by (.+?)\\.(?: \\((.+?)\\))?$")
        ds = Re("^(.+?) is [0-9A-Za-z_]+ by (YOUR|.+?'s) (.+?) for ([0-9]+) points? of non-melee damage\\.$")
        dsInc = Re("^YOU are [0-9A-Za-z_]+ by (.+?)'s (.+?) for ([0-9]+) points? of non-melee damage!$")
        dot = Re("^(.+?) has taken ([0-9]+) damage from (.+?)\\.(?: \\((.+?)\\))?$")
        dotNocaster = Re("^(.+?) has taken ([0-9]+) damage by (.+?)\\.(?: \\((.+?)\\))?$")
        heal = Re("^(.+?) healed (.+?)( over time)? for ([0-9]+)(?: \\(([0-9]+)\\))? hit points?(?: by (.+?))?\\.(?: \\(([A-Za-z][A-Za-z ]*)\\))?$")
        mend = Re("^You mend your wounds and heal some damage\\.$")
        runeGain = Re("^You gain a rune for ([0-9]+) points? of absorption\\.$")
        skinAbsorbBlow = Re("^(.+?) tr(?:y|ies) to [0-9A-Za-z_]+ (?:on )?YOU, but YOUR magical skin absorbs the blow!(?: \\([A-Za-z ]+\\))?$")
        skinAbsorbDs = Re("^YOUR magical skin absorbs the damage of (.+?)'s .+\\.$")
        miss = Re(
            "^(.+?) tr(?:y|ies) to [0-9A-Za-z_]+ (?:on )?(.+?), but "
                + "(?:(miss|misses)"
                + "|(.+?) (parries|dodges|ripostes|blocks)"
                + "|(YOU) (parry|dodge|riposte|block)"
                + "|.+?'s magical skin (absorbs) the blow"
                + "|(YOUR) magical skin absorbs the blow)"
                + "!(?: \\([A-Za-z]+\\))?$")
        missVerb = Re(" tr(?:y|ies) to ([0-9A-Za-z_]+)")
        missMod = Re(" \\(([A-Za-z]+)\\)$")
        resistYours = Re("^(.+?) resisted your (.+?)!$")
        resistCaster = Re("^(.+?) resisted (.+?)'s (.+?)!$")
        resistIncoming = Re("^You resist(?:ed)? (.+?)'s (.+?)!$")
        yourPrefix = Re("(?i)^your ")
        dotBy = Re(" by (.+)$")
        critical = Re("(?i)critical")
        reflexive = Re("(?i)^(itself|himself|herself|themselves)$")
        dsOwnerPoss = Re("'s$")
    }
}

/// The base (first-person) form of every verb `MELEE_VERBS` spells out.
private let MELEE_VERB_BASES: Set<String> = [
    "hit", "slash", "pierce", "crush", "bash", "kick", "bite", "claw", "gore", "maul", "punch",
    "strike", "slice", "backstab", "slam", "sting", "rend", "smash", "gnaw", "lash", "smite",
    "cleave", "reave", "shoot", "frenzy", "flurry",
]

/// Un-conjugate: longest suffix rule first, each confirmed against the base set.
private func meleeVerbBase(_ verb: String) -> String {
    let v = verb.lowercased()
    if v.hasPrefix("frenz") { return "frenzy" }
    if v.hasPrefix("flurr") { return "flurry" }
    if MELEE_VERB_BASES.contains(v) { return v }
    if v.hasSuffix("es") {
        let stem = String(v.dropLast(2))
        if MELEE_VERB_BASES.contains(stem) { return stem }
    }
    if v.hasSuffix("s") {
        let stem = String(v.dropLast(1))
        if MELEE_VERB_BASES.contains(stem) { return stem }
    }
    return v
}

/// A named class skill gets its own lane; a weapon-in-a-hand verb shares one.
public func meleeSkill(_ verb: String) -> String {
    let v = verb.lowercased()
    if v.hasPrefix("backstab") { return "Backstab" }
    if v.hasPrefix("bash") { return "Bash" }
    if v.hasPrefix("kick") { return "Kick" }
    if v.hasPrefix("cleav") { return "Cleave" }
    if v.hasPrefix("smite") { return "Smite" }
    if v.hasPrefix("shoot") { return "Ranged" }
    if v.hasPrefix("strike") { return "Strike" }
    if v.hasPrefix("frenz") { return "Frenzy" }
    if v.hasPrefix("flurr") { return "Flurry" }
    return "Melee"
}

/// The damage-shield reading of a line: six fields that travel together.
private struct Dmg {
    let attacker: String
    let target: String
    let amount: Int64
    let dtype: String
    let skill: String
    let crit: Bool
}

/// The damage-shield shape, which carries no paren modifier and maps its category 1:1.
private func dmg(_ c: Ctx, _ out: Ev, _ spec: Dmg) {
    out.begin(.damage)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.attacker, spec.attacker)
    out.s(.target, spec.target)
    out.i(.amount, spec.amount)
    out.s(.dtype, spec.dtype)
    out.s(.skill, spec.skill)
    out.b(.crit, spec.crit)
    out.s(.category, Taxonomy.damageCategory(spec.dtype, []))
}

/// Misses / avoided swings (by far the most common combat line).
func classifyMiss(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !(c.text.contains(", but ")
        && (c.text.hasPrefix("You try to ") || c.text.contains(" tries to "))) {
        return false
    }
    if let m = r.miss.captures(c.text) {
        let attacker = Names.norm(m.s(1))
        // Group map: 3=miss|misses 4=defender 5=3rd-verb 6=YOU 7=base-verb 8=absorbs(possessive)
        // 9=YOUR(self)
        let mtype: String
        let target: String
        if m[3] != nil {
            mtype = "miss"
            target = Names.norm(m.s(2))
        } else if let v = m[5] {
            switch v {
            case "parries": mtype = "parry"
            case "dodges": mtype = "dodge"
            case "ripostes": mtype = "riposte"
            default: mtype = "block"
            }
            target = Names.norm(m.s(4))
        } else if let v = m[7] {
            // The base form is the miss type.
            switch v {
            case "parry": mtype = "parry"
            case "dodge": mtype = "dodge"
            case "riposte": mtype = "riposte"
            default: mtype = "block"
            }
            target = "You"
        } else if m[9] != nil {
            // Self rune absorb: YOUR skin means the swing was aimed at you.
            mtype = "absorb"
            target = "You"
        } else {
            mtype = "absorb"
            target = Names.norm(m.s(2))
        }
        out.begin(.miss)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.attacker, attacker)
        out.s(.target, target)
        out.s(.mtype, mtype)
        // Verb then modifiers, each written only when present.
        if let v = r.missVerb.captures(c.text) {
            out.s(.verb, meleeVerbBase(v.s(1)))
        }
        if let md = r.missMod.captures(c.text) {
            out.strs(.modifiers, Taxonomy.parseModifiers(md.s(1)))
        }
        return true
    }
    // The miss pattern declined: the safety net for a compound trailing modifier its single-word
    // tail rejects.
    if let a = r.skinAbsorbBlow.captures(c.text) {
        out.begin(.mitigation)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.mtype, "absorbSwing")
        out.s(.source, Names.norm(a.s(1)))
        return true
    }
    return false
}

/// Absorption / mitigation — rune grants + absorbed damage-shield ticks.
func classifyMitigation(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.hasPrefix("You gain a rune for ") {
        if let m = r.runeGain.captures(c.text) {
            out.begin(.mitigation)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.mtype, "rune")
            out.i(.amount, Int64(m.s(1)) ?? 0)
            return true
        }
    }
    if c.text.hasPrefix("YOUR magical skin absorbs the damage of ") {
        if let m = r.skinAbsorbDs.captures(c.text) {
            out.begin(.mitigation)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.mtype, "absorbDamageShield")
            out.s(.source, Names.norm(m.s(1)))
            return true
        }
    }
    return false
}

/// Spell resists — the caster-side "miss".
func classifyResist(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if !(text.contains("resist") && !text.contains("points of") && text.hasSuffix("!")) {
        return false
    }
    if text.hasPrefix("You resist") {
        if let m = r.resistIncoming.captures(text) {
            out.begin(.resist)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.caster, Names.norm(m.s(1)))
            out.s(.target, "You")
            out.s(.spell, JS.trim(m.s(2)))
            out.b(.incoming, true)
            return true
        }
        return false
    }
    // The possessive-YOUR form first: 712 spell names contain `'s`.
    if let m = r.resistYours.captures(text) {
        out.begin(.resist)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.caster, "you")
        out.s(.target, Names.norm(m.s(1)))
        out.s(.spell, JS.trim(m.s(2)))
        out.b(.incoming, false)
        return true
    }
    if let m = r.resistCaster.captures(text) {
        out.begin(.resist)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.caster, Names.norm(m.s(2)))
        out.s(.target, Names.norm(m.s(1)))
        out.s(.spell, JS.trim(m.s(3)))
        out.b(.incoming, false)
        return true
    }
    return false
}

/// The "points of damage" half of the battery: damage shield, spell nuke, melee.
private func pointsDamage(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    // Literal gates in front of each regex: every family requires its literal, and the three are
    // mutually exclusive, so the gates change no answer — only how often ICU runs.
    let nonMelee = text.contains("non-melee damage")
    if nonMelee, let m = r.ds.captures(text) {
        let owner = m.s(2) == "YOUR" ? "You" : Names.norm(r.dsOwnerPoss.replaceFirst(m.s(2), with: ""))
        dmg(c, out, Dmg(
            attacker: owner,
            target: Names.norm(m.s(1)),
            amount: Int64(m.s(4)) ?? 0,
            dtype: "ds",
            skill: JS.trim(m.s(3)),
            crit: false))
        return true
    }
    if nonMelee, let m = r.dsInc.captures(text) {
        dmg(c, out, Dmg(
            attacker: Names.norm(m.s(1)),
            target: "You",
            amount: Int64(m.s(3)) ?? 0,
            dtype: "ds",
            skill: JS.trim(m.s(2)),
            crit: false))
        return true
    }
    if text.contains(" damage by "), let m = r.spell.captures(text) {
        let modifier = m[6].map(String.init)
        let mods = Taxonomy.parseModifiers(modifier)
        out.begin(.damage)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.attacker, Names.norm(m.s(1)))
        out.s(.target, Names.norm(m.s(2)))
        out.i(.amount, Int64(m.s(3)) ?? 0)
        out.s(.dtype, "spell")
        out.s(.dclass, m.s(4))
        out.s(.skill, JS.trim(m.s(5)))
        out.b(.crit, Taxonomy.hasCritical(mods))
        out.sOpt(.modifier, modifier)
        out.strs(.modifiers, mods)
        out.s(.category, Taxonomy.damageCategory("spell", mods))
        return true
    }
    if text.contains("of damage"), let m = r.melee.captures(text) {
        let modifier = m[4].map(String.init)
        let mods = Taxonomy.parseModifiers(modifier)
        let verb = meleeVerbBase(r.meleeVerb.captures(text).map { $0.s(1) } ?? "hit")
        out.begin(.damage)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.attacker, Names.norm(m.s(1)))
        out.s(.target, Names.norm(m.s(2)))
        out.i(.amount, Int64(m.s(3)) ?? 0)
        out.s(.dtype, "melee")
        out.s(.skill, meleeSkill(verb))
        out.s(.verb, verb)
        out.b(.crit, Taxonomy.hasCritical(mods))
        out.sOpt(.modifier, modifier)
        out.strs(.modifiers, mods)
        out.s(.category, Taxonomy.damageCategory("melee", mods))
        return true
    }
    return false
}

/// The "has taken N damage" half: DoTs, with and without a caster.
private func takenDamage(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if let m = r.dot.captures(text) {
        let target = Names.norm(m.s(1))
        let amount = Int64(m.s(2)) ?? 0
        let rest = m.s(3)
        let modifier = m[4].map(String.init)
        let crit = r.critical.isMatch(modifier ?? "")
        var attacker: String?
        var skill: String = rest
        if r.yourPrefix.isMatch(rest) {
            attacker = "You"
            skill = r.yourPrefix.replaceFirst(rest, with: "")
        } else if let by = r.dotBy.captures(rest) {
            attacker = Names.norm(by.s(1))
            // The match runs to the end of `rest`; the skill is everything before it.
            skill = String(rest.dropLast(by.whole.count))
        }
        // "from <Spell>" with no "by <caster>" and not "your" falls through to the caster-less form.
        if let attacker {
            let mods = Taxonomy.parseModifiers(modifier)
            out.begin(.damage)
            out.envelope(c.seq, c.ts, c.raw)
            out.s(.attacker, attacker)
            out.s(.target, target)
            out.i(.amount, amount)
            out.s(.dtype, "dot")
            out.s(.skill, JS.trim(skill))
            out.b(.crit, crit)
            out.sOpt(.modifier, modifier)
            out.strs(.modifiers, mods)
            out.s(.category, "dot")
            return true
        }
    }
    if let m = r.dotNocaster.captures(text) {
        let modifier = m[4].map(String.init)
        let crit = r.critical.isMatch(modifier ?? "")
        let mods = Taxonomy.parseModifiers(modifier)
        out.begin(.damage)
        out.envelope(c.seq, c.ts, c.raw)
        out.sOrNull(.attacker, nil)
        out.s(.target, Names.norm(m.s(1)))
        out.i(.amount, Int64(m.s(2)) ?? 0)
        out.s(.dtype, "dot")
        out.s(.skill, JS.trim(m.s(3)))
        out.b(.crit, crit)
        out.sOpt(.modifier, modifier)
        out.strs(.modifiers, mods)
        out.s(.category, "dot")
        return true
    }
    return false
}

/// Damage: melee / spell / dot / damage-shield, behind the shared substring gates.
func classifyDamage(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    let hasPoints = c.text.contains("points of") || c.text.contains("point of")
    let hasTaken = c.text.contains("has taken")
    if hasPoints && pointsDamage(r, c, out) { return true }
    if hasTaken && takenDamage(r, c, out) { return true }
    return false
}

/// Heals, plus the one heal family that states no amount.
func classifyHeal(_ r: CombatRes, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.hasPrefix("You mend") && r.mend.isMatch(c.text) {
        out.begin(.healUnstated)
        out.envelope(c.seq, c.ts, c.raw)
        out.s(.skill, "Mend")
        out.s(.target, "You")
        return true
    }
    if !c.text.contains(" healed ") { return false }
    guard let m = r.heal.captures(c.text) else { return false }
    let healer = Names.norm(m.s(1))
    let tRaw = JS.trim(m.s(2))
    let reflexive = r.reflexive.isMatch(tRaw)
    let target = reflexive ? healer : Names.norm(tRaw)
    out.begin(.heal)
    out.envelope(c.seq, c.ts, c.raw)
    out.s(.target, target)
    out.i(.amount, Int64(m.s(4)) ?? 0)
    // Absent, not zero, when the group did not participate.
    out.iOpt(.rawAmount, m[5].flatMap { Int64(String($0)) })
    // An empty trim is absent, not "".
    let spell = m[6].map { JS.trim(String($0)) }
    out.sOpt(.spell, spell.flatMap { $0.isEmpty ? nil : $0 })
    out.s(.healer, healer)
    out.b(.crit, r.critical.isMatch(m[7].map(String.init) ?? ""))
    if m[3] != nil {
        out.b(.overTime, true)
    }
    return true
}
