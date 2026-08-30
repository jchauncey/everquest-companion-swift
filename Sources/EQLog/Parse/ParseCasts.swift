// Port of eqlog/src/parse/casts.rs — the cast lifecycle, charm and crowd control, buff fades, pet
// ownership, stances, gems, the illusion click-off, rogue poisons, the DB-gated buff events, and —
// matched last of all — spell-landing emotes.
import Foundation

/// The six exact sentences a pet speaks out loud, in order.
private let petSayLines: [(String, String)] = [
    ("follow", "Following you, Master."),
    ("regroup", "Now regrouping, master."),
    ("calm", "Sorry, Master... calming down."),
    ("hold", "Now holding, Master.  I will not start new attacks until ordered."),
    ("comply", "As you wish, oh great one."),
    ("illegalTarget", "I beg forgiveness, Master.  That is not a legal target."),
]

private let castResumedLine = "You regain your concentration and continue your casting."

// The poison roster (eqlog/src/parse/data.rs), matched by equality rather than by pattern. Source
// order is semantic: a proc's first strike is the name the event carries.

/// The exact `You coat your blades …` line to (poison name, group).
private let poisonByCoatMsg: [(String, String, String)] = [
    ("You coat your blades in a weak paralytic.", "Weakening Poison", "utility"),
    ("You coat your blades in a thick venom.", "Hobbling Poison", "utility"),
    ("You coat your blades with a potent venom.", "Concussive Poison", "utility"),
    ("You coat your blades in a mind numbing poison.", "Befuddling Poison", "utility"),
    ("You coat your blades in a tar-like poison.", "Grounding Poison", "utility"),
    ("You coat your blades in a numbing poison.", "Clumsiness Poison", "utility"),
    ("You coat your blades with a magical poison.", "Banishing Poison", "utility"),
    ("You coat your blades in a fettering poison.", "Fettering Poison", "utility"),
    ("You coat your blades in a binding poison.", "Binding Poison", "utility"),
    ("You coat your blades in a neurotoxic poison.", "Neurotoxic Poison", "utility"),
    ("You coat your blades in a mind wracking poison.", "Mind Wrack Poison", "utility"),
    ("You coat your blades in a thought draining poison.", "Thought Drain Poison", "utility"),
    ("You coat your blades in antimagic poison.", "Antimagic Poison", "utility"),
    ("You coat your blades in mage bane poison.", "Mage Bane Poison", "utility"),
    ("You coat your blades in a paralytic poison.", "Paralytic Poison", "utility"),
    ("You coat your blades in a siphoning poison.", "Blood Siphon Venom", "combat"),
    ("You coat your blades in asp venom.", "Asp Venom", "combat"),
    ("You coat your blades with a stunning agent.", "Stunning Venom", "combat"),
    ("You coat your blades in a drawing poison.", "Blood Draw Venom", "combat"),
    ("You coat your blades in cobra venom.", "Cobra Venom", "combat"),
]

/// The two wears-off lines, split by group.
private let poisonDryMsg: [(String, String)] = [
    ("The poison dries from the blade.", "utility"),
    ("The venom drips away.", "combat"),
]

private struct PoisonProc {
    let suffix: String
    let strikes: [String]
    let effect: String
}

/// A Strike's landing emote, by the suffix that identifies it.
private let poisonProcs: [PoisonProc] = [
    PoisonProc(suffix: "'s limbs move slower!", strikes: ["Weakening Strike"], effect: "slow"),
    PoisonProc(suffix: "'s fingers slow down.", strikes: ["Clumsiness Strike"], effect: "spellSlow"),
    PoisonProc(suffix: "'s blessings wither!", strikes: ["Banishing Strike"], effect: "dispel"),
    PoisonProc(suffix: "'s feet won't budge!", strikes: ["Grounding Strike"], effect: "root"),
    PoisonProc(suffix: "stumbles, clutching their head!", strikes: ["Befuddling Strike"], effect: "manaDrain"),
    PoisonProc(suffix: "begins to sway!", strikes: ["Stunning Strike"], effect: "stun"),
    PoisonProc(suffix: "blinks, looking confused!", strikes: ["Concussive Strike"], effect: "interrupt"),
    PoisonProc(suffix: "starts limping!", strikes: ["Hobbling Strike"], effect: "snare"),
    PoisonProc(suffix: "begins to bleed profusely!", strikes: ["Blood Siphon Strike", "Blood Draw Strike"], effect: "dot"),
    PoisonProc(suffix: "screams as poison burns their veins!", strikes: ["Asp Venom Strike", "Cobra Venom Strike"], effect: "damage"),
]

/// `regex::escape` — the crate's meta set, so an escaped sentence is a literal alternative.
private func regexEscape(_ s: String) -> String {
    var out = ""
    for ch in s {
        switch ch {
        case "\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$", "#", "&", "-", "~":
            out.append("\\")
            out.append(ch)
        default:
            out.append(ch)
        }
    }
    return out
}

final class CastRes {
    let charm: Re
    let uncharm: Re
    let ccApply: Re
    let ccWake: Re
    let petClaim: Re
    let petSay: Re
    let petLeader: Re
    let castBegin: Re
    let otherCastBegin: Re
    let castFizzle: Re
    let castInterrupt: Re
    let buffFadePet: Re
    let buffFadeSelf: Re
    let aaActivate: Re
    let stance: Re
    let invocation: Re
    let memorizeBegin: Re
    let memorizeDone: Re
    let forget: Re
    let spellSet: Re
    let emoteSelf: Re
    let emotePet: Re
    let coatOtherNamed: Re
    let coatOtherGeneric: Re
    let article: Re
    let singleWordName: Re
    /// Last word of every proc emote to the emotes that end with it.
    let procByLastWord: [String: [Int]]
    let sayKindByText: [String: String]

    init() {
        let s = JS.S
        let six = petSayLines.map { regexEscape($0.1) }.joined(separator: "|")
        var byLastWord: [String: [Int]] = [:]
        for (i, p) in poisonProcs.enumerated() {
            let w: String
            if let at = p.suffix.lastIndex(of: " ") {
                w = String(p.suffix[p.suffix.index(after: at)...])
            } else {
                w = p.suffix
            }
            byLastWord[w, default: []].append(i)
        }
        procByLastWord = byLastWord
        var sayKinds: [String: String] = [:]
        for (k, sentence) in petSayLines { sayKinds[sentence] = k }
        sayKindByText = sayKinds

        charm = Re("^(.+?) has been charmed\\.$")
        uncharm = Re("^Your (.+?) spell has worn off of (.+?)\\.$")
        ccApply = Re("^(.+?) has been (mesmerized|enthralled|entranced|ensnared)\\.$")
        ccWake = Re("^(.+?) has been awakened by (.+?)\\.$")
        petClaim = Re("^(.+?) told you, '(?:Attacking .+ Master|I am unable to wake .+?, Master)\\.'$")
        petSay = Re("^(.+?) says, '(\(six))'$")
        petLeader = Re("^(.+?) says, 'My leader is (.+?)\\.'$")
        castBegin = Re("^You begin (casting|singing) (.+?)\\.$")
        otherCastBegin = Re("^(.+?) begins (?:casting|singing) (.+?)\\.$")
        castFizzle = Re("^Your (.+?) spell fizzles!$")
        castInterrupt = Re("^Your (.+?) spell is interrupted\\.$")
        buffFadePet = Re("^Your pet's (.+?) spell has worn off\\.$")
        buffFadeSelf = Re("^Your (.+?) spell has worn off\\.$")
        aaActivate = Re("^You activate (.+?)\\.$")
        stance = Re("^You assume an? (.+?) stance\\.$")
        invocation = Re("^You begin reciting the (.+?) invocation\\.$")
        memorizeBegin = Re("^Beginning to memorize (.+?)\\.\\.\\.$")
        memorizeDone = Re("^You have finished memorizing (.+?)\\.$")
        forget = Re("^You forget (.+?)\\.$")
        spellSet = Re("^Spell set (.+?) (saved|loaded|deleted)\\.$")
        emoteSelf = Re("^You (?:feel|look|sense|seem)(?-u:\\b)[^.]*\\.$")
        emotePet = Re("^([A-Z][A-Za-z'`]*(?: [A-Za-z'`]+)*) (?:feels|looks|seems)(?-u:\\b)[^.]*\\.$")
        coatOtherNamed = Re("^(.+?) coats their blades in (.+?)!$")
        coatOtherGeneric = Re("^(.+?)\(s)?coats their blades in poison\\.$")
        article = Re("(?i)^(?:a|an|the)\(s)")
        singleWordName = Re("^[A-Z][A-Za-z`']*$")
    }
}

/// `You begin casting|singing <Spell>.` — the player's own cast, with the verb kept.
private func ownCastBegin(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    guard let m = r.castBegin.captures(c.text) else { return false }
    out.begin(.castBegin)
    out.envelope(c)
    out.s(.spell, JS.trim(m.s(2)))
    // Absent rather than false for a cast.
    if m.s(1) == "singing" { out.b(.sung, true) }
    return true
}

func classifyCastLifecycle(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text.hasPrefix("You begin "), ownCastBegin(r, c, out) { return true }
    if text.contains(" begins casting ") || text.contains(" begins singing ") {
        if let m = r.otherCastBegin.captures(text) {
            if Names.idKey(m.s(1)) != "you" {
                out.begin(.otherCastBegin)
                out.envelope(c)
                out.s(.caster, Names.norm(m.s(1)))
                out.s(.spell, JS.trim(m.s(2)))
                return true
            }
        }
    }
    if text.contains("spell fizzles!") {
        if let m = r.castFizzle.captures(text) {
            out.begin(.castFizzle)
            out.envelope(c)
            out.s(.spell, JS.trim(m.s(1)))
            return true
        }
    }
    if text.contains("spell is interrupted.") {
        if let m = r.castInterrupt.captures(text) {
            out.begin(.castInterrupted)
            out.envelope(c)
            out.s(.spell, JS.trim(m.s(1)))
            return true
        }
    }
    if text == castResumedLine {
        out.begin(.castResumed)
        out.envelope(c)
        return true
    }
    return false
}

/// A DB hit's candidate list: name + duration, in index order.
private func candNameDuration(_ db: SpellDb, _ idx: [Int]) -> [(String, Int64?)] {
    idx.compactMap { i in db.entry(i).map { ($0.name, $0.durationMs) } }
}

/// Charm application, with the DB-gated candidate list.
func classifyCharm(_ r: CastRes, _ db: SpellDb?, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.contains("has been charmed") {
        guard let m = r.charm.captures(c.text) else { return false }
        let cands = db.flatMap { $0.matchCastOnOther(c.text) }
        out.begin(.charm)
        out.envelope(c)
        out.s(.mob, Names.norm(m.s(1)))
        if let (entry, _) = cands, let db {
            out.candsND(.candidates, candNameDuration(db, entry.indices))
        }
        return true
    }
    return classifyNonEnchanterCharm(db, c, out)
}

/// `<mob> blinks.` / `<mob> moans.` — admitted only when the DB's candidate list is entirely
/// charm-family, so a future scrape shrinks the rule rather than misfiling.
private func classifyNonEnchanterCharm(_ db: SpellDb?, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasSuffix(" blinks.") && !c.text.hasSuffix(" moans.") { return false }
    guard let db else { return false }
    guard let (entry, target) = db.matchCastOnOther(c.text) else { return false }
    if entry.indices.isEmpty
        || !entry.indices.allSatisfy({ i in db.entry(i).map { db.isCharmSpell($0.name) } ?? false })
    {
        return false
    }
    out.begin(.charm)
    out.envelope(c)
    out.s(.mob, Names.norm(target))
    out.candsND(.candidates, candNameDuration(db, entry.indices))
    return true
}

/// "worn off" — uncharm, CC refresh or named-target fade, else the targetless self/pet fade.
func classifyWornOff(_ r: CastRes, _ db: SpellDb?, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text.contains("worn off of") {
        guard let m = r.uncharm.captures(text) else { return false }
        let isCharm: Bool
        if let db {
            isCharm = db.isCharmSpell(m.s(1))
        } else {
            // With no DB installed, the charm test is the stem roster itself.
            isCharm = Stems.charmStemsTest(m.s(1))
        }
        if isCharm {
            out.begin(.uncharm)
            out.envelope(c)
            out.s(.mob, Names.norm(m.s(2)))
            out.s(.spell, JS.trim(m.s(1)))
            return true
        }
        if Stems.ccStemsTest(m.s(1)) {
            out.begin(.cc)
            out.envelope(c)
            out.s(.mob, Names.norm(m.s(2)))
            out.s(.spell, JS.trim(m.s(1)))
            out.b(.refresh, true)
            return true
        }
        out.begin(.buffFade)
        out.envelope(c)
        out.s(.spell, JS.trim(m.s(1)))
        out.s(.target, Names.norm(m.s(2)))
        return true
    } else if text.contains("worn off.") {
        if let m = r.buffFadePet.captures(text) {
            out.begin(.buffFade)
            out.envelope(c)
            out.s(.spell, JS.trim(m.s(1)))
            out.s(.target, "pet")
            return true
        }
        if let m = r.buffFadeSelf.captures(text) {
            out.begin(.buffFade)
            out.envelope(c)
            out.s(.spell, JS.trim(m.s(1)))
            return true
        }
    }
    return false
}

/// Crowd-control application (mez/root, not charm), with the DB-gated candidate list.
func classifyCcApply(_ r: CastRes, _ db: SpellDb?, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains("has been ") { return false }
    guard let m = r.ccApply.captures(c.text) else { return false }
    let hit = db.flatMap { $0.matchCastOnOther(c.text) }
    out.begin(.cc)
    out.envelope(c)
    out.s(.mob, Names.norm(m.s(1)))
    out.s(.verb, m.s(2))
    if let (entry, _) = hit, let db {
        out.candsND(.candidates, candNameDuration(db, entry.indices))
    }
    return true
}

func classifyCcWake(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains(" has been awakened by ") { return false }
    guard let m = r.ccWake.captures(c.text) else { return false }
    out.begin(.ccWake)
    out.envelope(c)
    out.s(.mob, Names.norm(m.s(1)))
    out.s(.by, Names.norm(m.s(2)))
    return true
}

func classifyPetClaim(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains(" told you, '") { return false }
    guard let m = r.petClaim.captures(c.text) else { return false }
    out.begin(.petClaim)
    out.envelope(c)
    out.s(.name, Names.norm(m.s(1)))
    out.s(.via, "tell")
    return true
}

func classifyPetSay(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.contains(" says, '") { return false }
    guard let m = r.petSay.captures(c.text) else { return false }
    guard let say = r.sayKindByText[m.s(2)] else { return false }
    out.begin(.petSay)
    out.envelope(c)
    out.s(.name, Names.norm(m.s(1)))
    out.s(.say, say)
    return true
}

/// `<Name> says, 'My leader is <You>.'` — the `/pet who leader` answer, which binds.
func classifyPetLeader(_ r: CastRes, _ character: String?, _ c: Ctx, _ out: Ev) -> Bool {
    guard let selfName = character, !selfName.isEmpty else { return false }
    if !c.text.contains(" says, 'My leader is ") { return false }
    guard let m = r.petLeader.captures(c.text) else { return false }
    if m.s(2).lowercased() != JS.trim(selfName).lowercased() { return false }
    out.begin(.petClaim)
    out.envelope(c)
    out.s(.name, Names.norm(m.s(1)))
    out.s(.via, "leader")
    return true
}

/// The same answer about somebody else; must run after `classifyPetLeader`.
func classifyAllyPetLeader(_ r: CastRes, _ character: String?, _ c: Ctx, _ out: Ev) -> Bool {
    guard let selfName = character, !selfName.isEmpty else { return false }
    if !c.text.contains(" says, 'My leader is ") { return false }
    guard let m = r.petLeader.captures(c.text) else { return false }
    let owner = m.s(2)
    if owner.lowercased() == JS.trim(selfName).lowercased() { return false }
    if !isPlayerShapedName(r, owner) { return false }
    out.begin(.allyPetLeader)
    out.envelope(c)
    out.s(.pet, Names.norm(m.s(1)))
    out.s(.owner, Names.norm(owner))
    return true
}

/// A leading article is the mob marker; a player is one capitalized word.
private func isPlayerShapedName(_ r: CastRes, _ name: String) -> Bool {
    let n = JS.trim(name)
    if n.isEmpty { return false }
    if r.article.isMatch(n) { return false }
    return r.singleWordName.isMatch(n)
}

func classifyAAActivate(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    if !c.text.hasPrefix("You activate ") { return false }
    guard let m = r.aaActivate.captures(c.text) else { return false }
    out.begin(.aaActivate)
    out.envelope(c)
    out.s(.name, JS.trim(m.s(1)))
    return true
}

func classifyStance(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.hasPrefix("You assume ") {
        if let m = r.stance.captures(c.text) {
            out.begin(.stanceChange)
            out.envelope(c)
            out.s(.stance, JS.trim(m.s(1)).lowercased())
            return true
        }
    }
    if c.text.hasPrefix("You begin reciting ") {
        if let m = r.invocation.captures(c.text) {
            out.begin(.invocationChange)
            out.envelope(c)
            out.s(.invocation, JS.trim(m.s(1)).lowercased())
            return true
        }
    }
    return false
}

/// The memorize / forget / spell-set family. Each of the four prefixes returns, match or not.
func classifySpellGems(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text.hasPrefix("You forget ") {
        guard let m = r.forget.captures(text) else { return false }
        out.begin(.spellForget)
        out.envelope(c)
        out.s(.spell, JS.trim(m.s(1)))
        return true
    }
    if text.hasPrefix("You have finished memorizing ") {
        guard let m = r.memorizeDone.captures(text) else { return false }
        out.begin(.spellMemorize)
        out.envelope(c)
        out.s(.spell, JS.trim(m.s(1)))
        out.b(.done, true)
        return true
    }
    if text.hasPrefix("Beginning to memorize ") {
        guard let m = r.memorizeBegin.captures(text) else { return false }
        out.begin(.spellMemorize)
        out.envelope(c)
        out.s(.spell, JS.trim(m.s(1)))
        out.b(.done, false)
        return true
    }
    if text.hasPrefix("Spell set ") {
        if let m = r.spellSet.captures(text) {
            out.begin(.spellSet)
            out.envelope(c)
            out.s(.set, JS.trim(m.s(1)))
            out.s(.action, m.s(2))
            return true
        }
    }
    return false
}

func classifyIllusionFade(_ c: Ctx, _ out: Ev) -> Bool {
    if c.text != "Your illusion fades." { return false }
    out.begin(.illusionFade)
    out.envelope(c)
    out.s(.target, "self")
    return true
}

/// Rogue poisons, coat half: first- and third-person.
func classifyPoisonCoat(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if text.hasPrefix("You coat your blades ") && text.hasSuffix(".") {
        // An unknown coat line is still a coat — say so, decline to name the poison.
        let p = poisonByCoatMsg.first { $0.0 == text }
        out.begin(.poisonCoat)
        out.envelope(c)
        if let p {
            out.s(.poison, p.1)
            out.s(.group, p.2)
        } else {
            out.s(.poison, "unknown")
            out.s(.group, "unknown")
        }
        out.s(.who, "you")
        return true
    }
    if text.contains("coats their blades in ") {
        if let m = r.coatOtherNamed.captures(text) {
            let probe = "You coat your blades in \(JS.trim(m.s(2)))."
            let p = poisonByCoatMsg.first { $0.0 == probe }
            out.begin(.poisonCoat)
            out.envelope(c)
            out.s(.poison, p.map { $0.1 } ?? "unknown")
            out.s(.group, p.map { $0.2 } ?? "unknown")
            out.s(.who, Names.norm(m.s(1)))
            return true
        }
        if let m = r.coatOtherGeneric.captures(text) {
            out.begin(.poisonCoat)
            out.envelope(c)
            out.s(.poison, "unknown")
            out.s(.group, "unknown")
            out.s(.who, Names.norm(m.s(1)))
            return true
        }
    }
    return false
}

/// The proc emote's target (the text before the suffix), or nil when this proc doesn't match.
private func poisonProcTarget(_ text: String, _ suffix: String) -> String? {
    let tail = suffix.hasPrefix("'s") ? suffix : " " + suffix
    if !text.hasSuffix(tail) || text.utf8.count <= tail.utf8.count { return nil }
    let t = JS.trim(String(text.dropLast(tail.count)))
    return t.isEmpty ? nil : t
}

/// Rogue poisons, dry + Strike-proc half.
func classifyPoisonProc(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    let text = c.text
    if let dry = poisonDryMsg.first(where: { $0.0 == text }) {
        out.begin(.poisonDry)
        out.envelope(c)
        out.s(.group, dry.1)
        return true
    }
    if !(text.hasSuffix("!") || text.hasSuffix(".")) { return false }
    let lastWord: String
    if let at = text.lastIndex(of: " ") {
        lastWord = String(text[text.index(after: at)...])
    } else {
        lastWord = text
    }
    guard let cands = r.procByLastWord[lastWord] else { return false }
    for i in cands {
        let p = poisonProcs[i]
        if let target = poisonProcTarget(text, p.suffix) {
            out.begin(.poisonProc)
            out.envelope(c)
            out.s(.strike, p.strikes[0])
            out.strs(.candidates, p.strikes)
            out.s(.effect, p.effect)
            out.s(.target, Names.norm(target))
            return true
        }
    }
    return false
}

/// `spell`, `illusion` and `durationMs` come from the first candidate.
private func buffApplyEvent(_ db: SpellDb, _ c: Ctx, _ out: Ev, _ target: String, _ cands: [Int]) -> Bool {
    guard let i0 = cands.first, let first = db.entry(i0) else { return false }
    out.begin(.buffApply)
    out.envelope(c)
    out.s(.target, target)
    out.s(.spell, first.name)
    out.b(.illusion, first.illusion)
    out.iOrNull(.durationMs, first.durationMs)
    out.candsNDI(.candidates, cands.compactMap { i in
        db.entry(i).map { ($0.name, $0.durationMs, $0.illusion) }
    })
    return true
}

/// Message-driven buff events — DB-gated, additive. With no DB these never fire.
func classifyDbBuff(_ db: SpellDb?, _ c: Ctx, _ out: Ev) -> Bool {
    guard let db else { return false }
    if let cands = db.castOnYou(c.text), !cands.isEmpty {
        return buffApplyEvent(db, c, out, "self", cands)
    }
    if let worn = db.wearsOff(c.text), !worn.isEmpty {
        out.begin(.buffWearOff)
        out.envelope(c)
        out.s(.spell, db.entry(worn[0])?.name ?? "")
        out.strs(.candidates, worn.compactMap { db.entry($0)?.name })
        out.s(.target, "self")
        return true
    }
    if let (entry, target) = db.matchCastOnOther(c.text) {
        return buffApplyEvent(db, c, out, Names.norm(target), entry.indices)
    }
    return false
}

/// Spell-landing emotes — matched last so they never shadow a real family.
func classifySpellEmote(_ r: CastRes, _ c: Ctx, _ out: Ev) -> Bool {
    if c.text.hasPrefix("You ") {
        if r.emoteSelf.isMatch(c.text) {
            out.begin(.spellEmote)
            out.envelope(c)
            out.s(.subject, "self")
            out.s(.text, c.text)
            return true
        }
        return false
    }
    guard let m = r.emotePet.captures(c.text) else { return false }
    if Names.idKey(m.s(1)) == "you" { return false }
    out.begin(.spellEmote)
    out.envelope(c)
    out.s(.subject, Names.norm(m.s(1)))
    out.s(.text, c.text)
    return true
}
