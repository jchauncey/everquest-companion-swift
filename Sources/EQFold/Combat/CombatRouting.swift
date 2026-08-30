// Attribution + routing — where a parsed combat line lands (`fold/src/combat/routing.rs`, the port of
// `routing.ts` plus `otherRouting.ts` and `allyRouting.ts`, the two doors it offers a line it drops).
//
// `classify()` is the pure attribution decision (you / your pet / a group-mate / incoming / not our
// fight); the `route*` functions fold the line into the current encounter and the zone aggregate
// under that verdict, refresh the presence axis, and engage what needs engaging. Nothing here
// decides when a fight opens or closes — that is `CombatLifecycle`.
//
// The three doors are asked in a fixed order and each sees only what the one before it declined:
// `classify` decides YOUR rows, `routeOther*` records every other combatant the log names, and
// `routeAllyPet*` credits somebody else's charm pet.
//
// `classify` is pure and is asked three times per line (the damage, miss and resist probes), so it
// never also asks "…and if not, whose is it?" — an `ignore` verdict is an OFFER to the two models
// below, not a disposal.
//
// An `other` or ally-pet row is AGGREGATE-ONLY: it opens no encounter, extends none, engages no
// hostile, refreshes no presence, resolves no world instance and bumps no target ledger.
import Foundation
import EQLog
import EQCompanionCore

/// How a damage event `A → B` is attributed given the pet-name set.
public enum Attribution: Equatable {
    case outYou
    case outPet(petKey: String, petName: String, ambiguous: Bool)
    case outMember
    case incoming
    case ignore
}

/// The three outgoing row kinds, as the damage / miss / resist paths name them.
enum OutKind {
    case you, pet, member
}

extension Attribution {
    var outKind: OutKind {
        switch self {
        case .outYou: return .you
        case .outMember: return .member
        default: return .pet
        }
    }
}

/// The attribution decision. Everything the combat model books passes through here.
///
///   You → pet-name : always outgoing to a hostile twin, never dropped as friendly fire.
///   pet-name → You : always incoming.
///   pet-name → same-name (A == B) : pet outgoing, but AMBIGUOUS.
///   pet-name → a known player or a group-mate : IGNORE.
///   member → other : outgoing, as that member's own row.
///   member → You : IGNORED, not incoming — the incoming meter answers "what is hitting me".
///   any mob → member : IGNORED. Incoming-on-members is a real feature and out of scope.
public func classify(_ st: EngineState, _ attacker: String, _ target: String) -> Attribution {
    let aKey = Names.idKey(attacker)
    let bKey = Names.idKey(target)
    if aKey == "you" {
        // You → anything (including a pet name, which is then a hostile twin) is outgoing.
        return bKey == "you" ? .ignore : .outYou
    }
    let bYou = bKey == "you"
    if st.petNames.contains(aKey) {
        if bYou { return .incoming } // pet-name → You is always incoming
        if st.knownPlayers.contains(bKey) || st.roster.admitted.contains(bKey) {
            return .ignore // …but never AT a player, nor at a group-mate
        }
        let ambiguous = aKey == bKey // same-name twin: cannot tell pet from twin
        return .outPet(petKey: aKey, petName: attacker, ambiguous: ambiguous)
    }
    // A group member is the attacker. Checked before the incoming rule so a member's hit on you is
    // dropped rather than filed as an enemy's; checked after the pet rules so a charmed mob that
    // shares a member's name still attributes as your pet.
    if st.roster.admitted.contains(aKey) {
        if bYou || st.petNames.contains(bKey) { return .ignore }
        if st.knownPlayers.contains(bKey) || st.roster.admitted.contains(bKey) { return .ignore }
        return .outMember
    }
    if bYou { return .incoming }
    // Attacker not one of ours, target not you — offered to the two models below, not disposed of.
    return .ignore
}

/// The meter row for a combatant other than you — a group member or anyone else the log named.
///
/// One id namespace for both: the person you fought beside for ten minutes and then invited into
/// your group must be ONE bar. `Agg.reid` upgrades the stored kind when the roster catches up.
///
/// Keyed by NAME, not by instance — the pet rule deliberately inverted: resolving mints a world
/// instance, and a player-shaped instance can be engaged, retired and counted as hostile presence.
///
/// The name prefers the roster's spelling, then the recorded spelling, then the line's own.
func otherSource(_ st: EngineState, _ attacker: String, _ key: String, _ member: Bool) -> SourceRef {
    let name = st.roster.names[key] ?? st.others.nameOf(key) ?? attacker
    return SourceRef(id: "member:\(key)", name: name, kind: member ? .member : .other)
}

/// The outgoing meter row for an attributed you/pet/member action. A pet resolves to its pet
/// INSTANCE so twin pets stay distinct.
func outSource(_ st: EngineState, _ attacker: String, _ kind: OutKind, _ ts: Int64) -> SourceRef {
    switch kind {
    case .you:
        return SourceRef(id: "you", name: "You", kind: .you)
    case .member:
        return otherSource(st, attacker, Names.idKey(attacker), true)
    case .pet:
        let inst = st.world.petInstance(attacker) ?? st.resolve(attacker, ts, true)
        return SourceRef(id: "pet:\(inst.instanceId)", name: inst.label, kind: .pet)
    }
}

/// Engage an instance as a hostile of this encounter — the one door into `engaged`, and therefore
/// the one thing that can veto closure.
///
/// Neither a known player nor a group member walks through it: a friendly does not die on our
/// schedule and would hold a pull open indefinitely. Members reach this on the ordinary outgoing
/// path via `You → <member>`: a member's TARGET engages, the member never does.
func engageHostile(_ st: EngineState, _ inst: Resolved, _ ts: Int64) {
    if st.isKnownPlayer(inst.nameKey) || st.isMember(inst.nameKey) { return }
    guard let enc = st.current else { return }
    enc.engaged.insert(inst.instanceId)
    enc.engagedSeen.insert(inst.instanceId, ts)
}

/// Resolve the defender's label. The CALL is not optional even where nothing reads the result:
/// `defenderLabel` resolves through the world model, which retires stale instances and adopts the
/// sighting's casing as the instance display — and that display is what the next `bumpTarget`
/// freezes into a fight's name.
func noteDefender(_ st: EngineState, _ target: String, _ ts: Int64) -> String {
    st.freshEncounterId(ts) ? st.defenderLabel(target, ts) : target
}

/// Push one instant onto the FRESH encounter's ring, or nothing at all when no fight is open.
func pushFreshTimeline(_ st: EngineState, _ ts: Int64, _ rec: TimelineRaw) {
    if let enc = st.freshEncounter(ts) { EngineState.pushTimeline(enc, rec) }
}

/// Fold into the open encounter's aggregate and the zone aggregate alike — the pair every routing
/// path writes, and never one without the other.
func both(_ st: EngineState, _ ts: Int64, _ freshOnly: Bool, _ f: (Agg) -> Void) {
    if freshOnly {
        if let enc = st.freshEncounter(ts) { f(enc.agg) }
    } else if let enc = st.current {
        f(enc.agg)
    }
    f(st.zoneAgg)
}

/// Fold one landed damage line and report the verdict it reached. `nil` means the line was ignored
/// before any verdict was needed, which is where the analytics fold returns early.
@discardableResult
public func route(_ st: EngineState, _ ev: DamageEvent) -> Attribution? {
    if ev.amount <= 0 { return nil }
    let at = classify(st, ev.attacker, ev.target)
    // "You hit it", filed once, off the verdict `classify` just reached — here rather than inside
    // `classify`, which is pure and asked by the miss and resist probes too.
    if at == .outYou { st.noteStruck(Names.idKey(ev.target)) }
    // Before the ignore gate and the outgoing/incoming split: a bound ally pet swinging at YOU
    // classifies as `incoming` rather than `ignore`, and that line is the strongest soft-hostile
    // proof there is.
    noteAllyPetEvidence(st, ev.attacker, ev.target, ev.ts)
    // …and the same line for the other model: something that landed damage on you is a hostile.
    if at == .incoming { noteOtherHostile(st, ev.attacker) }
    if at == .ignore {
        // Offered to the two models that read it — the record-everything ladder first, then a third
        // party's charm pet. Both book aggregate-only; what neither claims stays dropped.
        if !routeOtherDamage(st, ev) { routeAllyPetDamage(st, ev) }
        return at
    }

    // Twin evidence: You→pet-name, or same-name→same-name, proves a hostile twin co-exists with the
    // pet; ensure the world model has a second instance so the two resolve to distinct identities.
    if at == .outYou && st.petNames.contains(Names.idKey(ev.target)) {
        st.world.noteTwinEvidence(ev.target, ev.ts)
        st.drainRetirements()
    }
    if case .outPet(_, _, let amb) = at, amb {
        st.world.noteTwinEvidence(ev.target, ev.ts)
        st.drainRetirements()
    }

    ensureEncounter(st, ev.ts)
    if let enc = st.current {
        // Active-time accrual: the gap since the previous attributed hit, capped at `ACTIVE_MS`, so
        // a long lull counts as at most one active tick. The first hit adds 0.
        if let prev = enc.prevDamageTs {
            enc.activeMs += Swift.min(Swift.max(ev.ts - prev, 0), ACTIVE_MS)
        }
        enc.prevDamageTs = ev.ts
        enc.lastTs = ev.ts
    }
    st.lastActivityTs = ev.ts
    // Zone-session timing: first/last attributed damage in this stay.
    if st.zoneStartTs == 0 { st.zoneStartTs = ev.ts }
    st.zoneLastTs = ev.ts

    if at == .incoming {
        routeIncomingDamage(st, ev)
    } else {
        routeOutgoingDamage(st, ev, at)
    }
    return at
}

/// A hostile (or the pet) hit YOU. Resolve the attacker to an instance so twins are distinct in the
/// incoming list.
func routeIncomingDamage(_ st: EngineState, _ ev: DamageEvent) {
    let att = st.resolve(ev.attacker, ev.ts, false)
    let id = att.instanceId, name = att.label
    both(st, ev.ts, false) { agg in agg.addInc(id, name, ev) }
    engageHostile(st, att, ev.ts)
    // An incoming instant lanes under the attacker's skill, so it gets its own row.
    if let enc = st.current {
        EngineState.pushTimeline(enc, TimelineRaw(
            ts: ev.ts, lane: ev.skill, category: ev.category, amount: ev.amount, crit: ev.crit,
            modifiers: ownMods(ev.modifiers), kind: "enemy", outcome: nil, detail: nil, target: nil))
    }
    st.log(ev.ts, ev.dtype, "enemy",
           "\(name) → You  \(ev.amount)\(ev.crit ? "*" : "")  \(ev.skill)")
}

/// You, your pet or a group member landed a hit.
func routeOutgoingDamage(_ st: EngineState, _ ev: DamageEvent, _ at: Attribution) {
    let src = outSource(st, ev.attacker, at.outKind, ev.ts)
    var ambiguous = false
    if case .outPet(let petKey, _, let amb) = at {
        ambiguous = amb
        // The pet is trading blows with its target — record that engagement for death case (b).
        st.world.notePetEngagement(ev.attacker, Names.idKey(ev.target))
        // A pet LANDING a hit is pet-shaped evidence (see the miss and resist twins).
        st.charm.notePetEvidence(petKey)
    }
    // A member's hit records no pet engagement and no charm evidence: a member is not a pet. The one
    // thing it does beyond its own row is engage its TARGET.

    // The game states the damage type on every typed spell line, so a poison lane is a fact the log
    // printed. Outgoing only, and additive — a second index over damage already counted.
    if ev.dclass == "poison" {
        // The ledger is about the venom, not the meter row: a cast-less firing's meter lane carries
        // the origin marker and this counter must not inherit it.
        let venom = baseLaneName(ev.skill)
        both(st, ev.ts, false) { agg in agg.procs.addPoisonDamage(venom, ev.amount) }
    }
    // Resolve the target to an instance. For a same-name ambiguous pet hit the target is the hostile
    // twin (`preferCharmed = false` picks it).
    let tgt = st.resolve(ev.target, ev.ts, false)
    let tid = tgt.instanceId, tname = tgt.label
    both(st, ev.ts, false) { agg in
        agg.addOut(src, ev, ambiguous)
        agg.bumpTarget(tid, tname, ev.amount)
    }
    engageHostile(st, tgt, ev.ts)
    // The live fight is named after whatever you are presently swinging at.
    if let enc = st.current {
        enc.lastOutTarget = tname
        // An outgoing instant lanes under the skill/spell name, and `target` carries the
        // instance-resolved defender label — the same value `bumpTarget` aggregates under.
        EngineState.pushTimeline(enc, TimelineRaw(
            ts: ev.ts, lane: ev.skill, category: ev.category, amount: ev.amount, crit: ev.crit,
            modifiers: ownMods(ev.modifiers), kind: src.kind.asStr, outcome: nil, detail: nil,
            target: tname))
    }
    // The ambiguous mark `~` replaces the crit star rather than joining it: "could not attribute
    // cleanly" outranks "it crit".
    let cat = ambiguous ? "ambiguous" : ev.dtype
    let mark = ambiguous ? "~" : (ev.crit ? "*" : "")
    st.log(ev.ts, cat, src.kind.asStr,
           "\(src.name) → \(tname)  \(ev.amount)\(mark)  \(ev.skill)")
}

/// The avoided swing as the aggregates fold it. `skill` stays `Melee` for every miss — that is the
/// accuracy lane — while `verb`/`laneSkill`/`modifiers`/`target` are the amount-free inputs to the
/// round grouper and the modifier tallies.
public struct MissLine {
    public var ts: Int64
    public var attacker: String
    public var target: String
    public var mtype: MissType
    public var verb: String?
    /// The parser's own `meleeSkill(verb)` answer, carried on the event.
    public var verbSkill: String?
    public var modifiers: [String]

    public init(ts: Int64, attacker: String, target: String, mtype: MissType, verb: String?,
                verbSkill: String?, modifiers: [String]) {
        self.ts = ts; self.attacker = attacker; self.target = target; self.mtype = mtype
        self.verb = verb; self.verbSkill = verbSkill; self.modifiers = modifiers
    }
}

func missFold(_ st: EngineState, _ ev: MissLine, _ isYou: Bool) -> MissFold {
    var laneSkill: String?
    if let verb = ev.verb {
        let special = isYou ? st.specials.laneSkill(verb) : nil
        laneSkill = special ?? ev.verbSkill
    }
    return MissFold(mtype: ev.mtype, skill: "Melee", verb: ev.verb, laneSkill: laneSkill,
                    modifiers: ev.modifiers, target: ev.target, ts: ev.ts)
}

/// Consume a miss (avoided swing) with the same attribution rules as damage. A melee skill name is
/// not in the miss line, so avoided swings bucket under `Melee`.
public func routeMiss(_ st: EngineState, _ ev: MissLine) {
    let at = classify(st, ev.attacker, ev.target)
    // An ally pet's swing at a friendly proves the break whether or not it connected.
    noteAllyPetEvidence(st, ev.attacker, ev.target, ev.ts)
    if at == .ignore {
        // The same two offers the damage path makes, in the same order. No hostile-evidence read on
        // the incoming side: that rung was measured on landed damage.
        let fold = missFold(st, ev, false)
        if !routeOtherMiss(st, ev, fold) { routeAllyPetMiss(st, ev, fold) }
        return
    }
    let fold = missFold(st, ev, at == .outYou)
    // Presence: a swing exchanged with an already-engaged mob proves it is still in the fight even
    // though nothing landed. Liveness only; no damage timing moves.
    let who = at == .incoming ? ev.attacker : ev.target
    st.notePresence(who, ev.ts)

    if at == .incoming {
        let att = st.resolve(ev.attacker, ev.ts, false)
        let id = att.instanceId, name = att.label
        both(st, ev.ts, true) { agg in agg.addIncMiss(id, name, fold) }
        // An incoming swing absorbed by YOUR rune is a mitigation instant and belongs to the healing
        // ledger. `incoming` means the defender is you, so this can never pick up a pet's or a mob's
        // own rune.
        if ev.mtype == .absorb {
            both(st, ev.ts, true) { agg in agg.heal.addAbsorbedSwing() }
        }
        st.log(ev.ts, "miss", "enemy", "\(name) ✕ You (\(ev.mtype.asStr))")
        return
    }
    routeOutgoingMiss(st, ev, fold, at.outKind)
}

/// A miss YOU, your pet or a group member swung.
func routeOutgoingMiss(_ st: EngineState, _ ev: MissLine, _ fold: MissFold, _ kind: OutKind) {
    let src = outSource(st, ev.attacker, kind, ev.ts)
    // A pet whiffing is as much proof it is fighting for us as a landed hit. A member's whiff proves
    // nothing about charm: they are bound by a group line, not by evidence.
    if kind == .pet { st.charm.notePetEvidence(Names.idKey(ev.attacker)) }
    both(st, ev.ts, true) { agg in agg.addOutMiss(src, fold) }
    // A miss tick lanes under `Melee`. The defender goes through `defenderLabel` so it matches the
    // instance label the damage path writes.
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, TimelineRaw(
        ts: ev.ts, lane: "Melee", category: "melee", amount: 0, crit: false, modifiers: [],
        kind: src.kind.asStr, outcome: "miss", detail: ev.mtype.asStr, target: tgtName))
    st.log(ev.ts, "miss", src.kind.asStr, "\(src.name) ✕ \(tgtName) (\(ev.mtype.asStr))")
}

public struct ResistLine {
    public var ts: Int64
    public var caster: String
    public var target: String
    public var spell: String
    public var incoming: Bool

    public init(ts: Int64, caster: String, target: String, spell: String, incoming: Bool) {
        self.ts = ts; self.caster = caster; self.target = target
        self.spell = spell; self.incoming = incoming
    }
}

/// Whose resisted cast this was, or `nil` when it is none of ours. Separate from `classify` because
/// a resist names a CASTER and a TARGET, not an attacker and a defender.
func resistCaster(_ st: EngineState, _ casterKey: String) -> OutKind? {
    if casterKey == "you" { return .you }
    if st.petNames.contains(casterKey) { return .pet }
    return st.isAdmittedMember(casterKey) ? .member : nil
}

/// Consume a spell RESIST — the caster-side analogue of a miss.
///
/// Resisted detrimental spells are direct spells in the taxonomy, so every resist categorizes as
/// `spell`. They carry no amount, so category totals are unaffected; the lane is the display spell
/// name, so a resist tick lands beside landed casts of that spell.
public func routeResist(_ st: EngineState, _ ev: ResistLine) {
    let CATEGORY = "spell"
    // Presence: refresh whichever side is a hostile we are already engaged with. `notePresence`
    // ignores anything not engaged, so the you/pet side is a no-op.
    let who = ev.incoming ? ev.caster : ev.target
    st.notePresence(who, ev.ts)

    if ev.incoming {
        // You resisted a mob's spell — attribute to the mob (the incoming caster).
        let att = st.resolve(ev.caster, ev.ts, false)
        let id = att.instanceId, name = att.label
        let spell = ev.spell
        both(st, ev.ts, true) { agg in agg.addIncResist(id, name, spell, CATEGORY) }
        pushFreshTimeline(st, ev.ts, TimelineRaw(
            ts: ev.ts, lane: ev.spell, category: CATEGORY, amount: 0, crit: false, modifiers: [],
            kind: "enemy", outcome: "resist", detail: "resisted", target: "You"))
        st.log(ev.ts, "resist", "info", "You resisted \(name)'s \(ev.spell)")
        return
    }

    guard let kind = resistCaster(st, Names.idKey(ev.caster)) else {
        // A resisted cast by a combatant the log named — the record-everything ladder, asked of the
        // CASTER because a resist has no attacker/defender pair to classify.
        if routeOtherResist(st, ev, CATEGORY) { return }
        // A hostile mob's spell resisted by another mob is out of scope, and said so.
        st.log(ev.ts, "resist", "dropped",
               "\(ev.caster)'s \(ev.spell) resisted by \(ev.target)")
        return
    }
    let src = outSource(st, ev.caster, kind, ev.ts)
    // A pet whose spell got resisted was casting for us. A member's resisted cast is not charm
    // evidence.
    if kind == .pet { st.charm.notePetEvidence(Names.idKey(ev.caster)) }
    let spell = ev.spell
    both(st, ev.ts, true) { agg in agg.addOutResist(src, spell, CATEGORY) }
    // Same instance resolution as the miss and damage paths.
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, TimelineRaw(
        ts: ev.ts, lane: ev.spell, category: CATEGORY, amount: 0, crit: false, modifiers: [],
        kind: src.kind.asStr, outcome: "resist", detail: "resisted", target: tgtName))
    st.log(ev.ts, "resist", src.kind.asStr,
           "\(src.name)'s \(ev.spell) resisted by \(tgtName)")
}

public struct HealLine {
    public var ts: Int64
    public var target: String
    public var healer: String?
    public var amount: Int64
    /// Raw/pre-overheal amount, present only on the `for N (M) hit points` lines.
    public var rawAmount: Int64?
    public var spell: String?
    public var crit: Bool

    public init(ts: Int64, target: String, healer: String?, amount: Int64, rawAmount: Int64?,
                spell: String?, crit: Bool) {
        self.ts = ts; self.target = target; self.healer = healer; self.amount = amount
        self.rawAmount = rawAmount; self.spell = spell; self.crit = crit
    }

    func input() -> HealInput {
        HealInput(amount: amount, rawAmount: rawAmount, spell: spell, crit: crit)
    }
}

/// Consume a heal. A heal on an engaged HOSTILE is enemy healing (it undoes our damage); a heal on
/// You or one of your pets is incoming healing; both also fold into the healing ledger. Other heals
/// are ignored for aggregation: the log gives no faction for an arbitrary name.
///
/// Zero-effective heals are the overheal evidence and belong to the ledger; the `enemyHeal` /
/// `incHeal` maps keep their `amount <= 0` gate.
public func routeHeal(_ st: EngineState, _ ev: HealLine) {
    if ev.amount < 0 { return }
    let tKey = Names.idKey(ev.target)
    let healerKey = ev.healer.map { Names.idKey($0) }
    let isYouTgt = tKey == "you"
    let isPetTgt = !isYouTgt && st.petNames.contains(tKey)

    st.learnPlayerKey(healerKey, tKey, isYouTgt, isPetTgt)
    let isPlayerTgt = st.playerKey == tKey

    // Known-player evidence, ONE direction only: a heal landing on the owner names its healer as a
    // friendly player. The other direction is false in this log, because a player heals their own
    // PETS by name, and a "player" is never a hostile and never a pet's target.
    if (isYouTgt || isPlayerTgt) && healerKey != nil { st.notePlayer(healerKey) }
    // Pet evidence, the other way round: the owner healing something already treated as a pet
    // corroborates a charm bind that is still provisional.
    if healerKey == "you" && isPetTgt { st.charm.notePetEvidence(tKey) }

    if isYouTgt || isPetTgt || isPlayerTgt {
        addFriendlyHeal(st, ev, healerKey)
        return
    }
    addHostileHeal(st, ev, healerKey)
}

/// Incoming heal to You (or the player by name) / your pet. The `incHeal` map keeps its
/// `amount <= 0` gate; the ledger takes the zero-effective lines too.
func addFriendlyHeal(_ st: EngineState, _ ev: HealLine, _ healerKey: String?) {
    let hk = healerKey ?? "unknown"
    let healerName = ev.healer ?? "Unknown"
    if ev.amount > 0 {
        both(st, ev.ts, true) { agg in agg.addIncHeal(hk, healerName, ev.amount) }
    }
    // Healing ledger: ranked by HEALER. Row id `you` for self-heals keys the healing meter's primary
    // row the same way the damage meter's is.
    let kind: HealSourceKind = hk == "you" ? .you : (st.petNames.contains(hk) ? .pet : .other)
    let id = hk == "you" ? "you" : "heal:\(hk)"
    let input = ev.input()
    both(st, ev.ts, true) { agg in agg.heal.addFriendly(id, healerName, kind, input) }
}

/// Consume an announced-but-unvalued heal — `You mend your wounds and heal some damage.`
///
/// It reaches the healing ledger as a COUNT on its own lane and nothing else. Everything the valued
/// path does with an amount is skipped rather than done with a zero.
public func routeHealUnstated(_ st: EngineState, _ ts: Int64, _ skill: String) {
    both(st, ts, true) { agg in agg.heal.addUnstated(skill) }
}

/// One absorption / mitigation line.
public struct MitigationLine {
    public var ts: Int64
    /// `rune` · `absorbSwing` · `absorbDamageShield`.
    public var mtype: String
    public var amount: Int64?

    public init(ts: Int64, mtype: String, amount: Int64?) {
        self.ts = ts; self.mtype = mtype; self.amount = amount
    }
}

/// Consume an absorption / mitigation line — damage PREVENTED, not hit points restored, so it never
/// touches a damage total. It does reach the healing total: rune counters fold in as a row
/// classified `absorbed`, while the two count-only families carry no amount and reach no total.
public func routeMitigation(_ st: EngineState, _ ev: MitigationLine) {
    let mtype = ev.mtype
    // The amount is required by the regex; a rune with no amount is a count we cannot value.
    let amount = ev.amount ?? 0
    both(st, ev.ts, true) { agg in
        switch mtype {
        case "rune": if amount > 0 { agg.heal.addRune(amount) }
        case "absorbSwing": agg.heal.addAbsorbedSwing()
        default: agg.heal.addAbsorbedDamageShield()
        }
    }
}

/// Heal on a hostile instance we are currently engaged with → enemy healing.
func addHostileHeal(_ st: EngineState, _ ev: HealLine, _ healerKey: String?) {
    let tKey = Names.idKey(ev.target)
    // A known player is never a hostile, so their heals are never enemy healing.
    if st.isKnownPlayer(tKey) { return }
    // …and neither is a group member. Stated here rather than left to `engageHostile`'s refusal
    // because the next line RESOLVES the target, and resolving mints a world instance.
    if st.isMember(tKey) { return }
    let inst = st.resolve(ev.target, ev.ts, false)
    let engaged = st.current?.engaged.contains(inst.instanceId) ?? false
    if !engaged { return }
    if ev.amount > 0 {
        let id = inst.instanceId, name = inst.label
        both(st, ev.ts, false) { agg in agg.addEnemyHeal(id, name, ev.amount) }
    }
    // Counter-healing ledger, ranked by the HEALER (a mob healing itself is its own row). It takes
    // the zero-effective lines the map above refuses.
    let hk = healerKey ?? "unknown"
    let healerName = ev.healer ?? "Unknown"
    let input = ev.input()
    both(st, ev.ts, false) { agg in agg.heal.addHostile("heal:\(hk)", healerName, input) }
    // A heal on an engaged hostile proves BOTH ends are still in the fight. Liveness only.
    st.notePresenceId(inst.instanceId, ev.ts)
    if let name = ev.healer { st.notePresence(name, ev.ts) }
}

/// May this name be recorded as a combatant of its own? The refusal ladder in evaluation order,
/// cheapest and most authoritative first.
///
/// `target` matters for exactly one thing: A == B. EQ prints self-damage (a lifetap resolving on its
/// own caster), and a same-name line is the pet model's twin-ambiguity case, not a fight.
func recordsOther(_ st: EngineState, _ attacker: String, _ target: String) -> String? {
    let key = Names.idKey(attacker)
    let targetKey = Names.idKey(target)
    if key == targetKey { return nil }
    if !recordableAttacker(st, attacker, key) { return nil }
    // The other half, asked of the DEFENDER. A recorded combatant swinging at you, at your pet, at a
    // group-mate, at anyone the heal stream proved a player, or at another recorded combatant is not
    // a fight this meter models.
    if st.allyFriendly(targetKey) || st.others.isRecorded(targetKey) { return nil }
    return key
}

func recordableAttacker(_ st: EngineState, _ attacker: String, _ key: String) -> Bool {
    if key.isEmpty || key == "you" || key == st.playerKey { return false }
    if st.petNames.contains(key) || st.everPet.contains(key) { return false }
    if st.others.isPet(key) || st.others.isHostile(key) { return false }
    if st.everStruck.contains(key) || st.charm.everCharmed(key) { return false }
    // Somebody else's charm pet already has a row, under the person who charmed it. Two rows for one
    // entity is the "aggregates lie" failure with two names on it.
    if st.ally.bindOf(key) != nil { return false }
    return st.others.shaped(attacker, key)
}

/// What one incoming line proves about the thing that threw it — read off damage already attributed
/// to `incoming`, i.e. a line whose target is YOU. It writes its own set and never touches
/// `knownPlayers`. The worst it can do is hide a row.
func noteOtherHostile(_ st: EngineState, _ attacker: String) {
    let key = Names.idKey(attacker)
    if key.isEmpty || key == "you" || st.isKnownPlayer(key) { return }
    if st.petNames.contains(key) || st.everPet.contains(key) { return }
    if !st.others.shaped(attacker, key) { return }
    st.others.noteHostile(key)
}

@discardableResult
func routeOtherDamage(_ st: EngineState, _ ev: DamageEvent) -> Bool {
    guard let key = recordsOther(st, ev.attacker, ev.target) else { return false }
    st.others.note(key, ev.attacker)
    let src = otherSource(st, ev.attacker, key, false)
    both(st, ev.ts, true) { agg in agg.addOut(src, ev, false) }
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, damageInstant(ev, "other", tgtName))
    st.log(ev.ts, ev.dtype, "other",
           "\(src.name) → \(tgtName)  \(ev.amount)\(ev.crit ? "*" : "")  \(ev.skill)")
    return true
}

@discardableResult
func routeOtherMiss(_ st: EngineState, _ ev: MissLine, _ fold: MissFold) -> Bool {
    guard let key = recordsOther(st, ev.attacker, ev.target) else { return false }
    st.others.note(key, ev.attacker)
    let src = otherSource(st, ev.attacker, key, false)
    both(st, ev.ts, true) { agg in agg.addOutMiss(src, fold) }
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, missInstant(ev, "other", tgtName))
    st.log(ev.ts, "miss", "other", "\(src.name) ✕ \(tgtName) (\(ev.mtype.asStr))")
    return true
}

@discardableResult
func routeOtherResist(_ st: EngineState, _ ev: ResistLine, _ category: String) -> Bool {
    guard let key = recordsOther(st, ev.caster, ev.target) else { return false }
    st.others.note(key, ev.caster)
    let src = otherSource(st, ev.caster, key, false)
    let spell = ev.spell
    both(st, ev.ts, true) { agg in agg.addOutResist(src, spell, category) }
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, TimelineRaw(
        ts: ev.ts, lane: ev.spell, category: category, amount: 0, crit: false, modifiers: [],
        kind: "other", outcome: "resist", detail: "resisted", target: tgtName))
    st.log(ev.ts, "resist", "other", "\(src.name)'s \(ev.spell) resisted by \(tgtName)")
    return true
}

/// The retention point for a damage line's modifier tokens.
func ownMods(_ mods: [String]) -> [String] { mods }

/// The timeline instant a RECORDED combatant's (or an ally pet's) landed hit leaves.
func damageInstant(_ ev: DamageEvent, _ kind: String, _ target: String) -> TimelineRaw {
    TimelineRaw(ts: ev.ts, lane: ev.skill, category: ev.category, amount: ev.amount, crit: ev.crit,
                modifiers: ownMods(ev.modifiers), kind: kind, outcome: nil, detail: nil,
                target: target)
}

/// …and the avoided-swing twin, which lanes under `Melee` like every other whiff.
func missInstant(_ ev: MissLine, _ kind: String, _ target: String) -> TimelineRaw {
    TimelineRaw(ts: ev.ts, lane: "Melee", category: "melee", amount: 0, crit: false, modifiers: [],
                kind: kind, outcome: "miss", detail: ev.mtype.asStr, target: target)
}

/// The ally pet's own meter row. The row id carries the CHARMER — `allypet:<charmer>:<pet>` — because
/// the same mob re-charmed by a different enchanter is a different person's contribution.
func allyPetSource(_ bind: AllyBind) -> SourceRef {
    SourceRef(id: "allypet:\(bind.charmerKey):\(bind.nameKey)",
              // The broadcast's spelling, not the damage line's: EQ sentence-cases a leading article.
              name: "Pet (\(bind.display)) - \(bind.charmer)",
              kind: .allyPet)
}

/// What one swing by a third party's charm pet proves — read off every attributed and every ignored
/// line, before the meter decides what to do with it.
///
/// Two judgements, both ENDINGS rather than admissions: the soft-hostile proof and twin ambiguity.
/// And a third that is not a judgement: the pet is still here, so its hold slides.
func noteAllyPetEvidence(_ st: EngineState, _ attacker: String, _ target: String, _ ts: Int64) {
    if st.ally.idle() { return }
    let aKey = Names.idKey(attacker)
    if st.ally.bindOf(aKey) == nil { return }
    st.ally.noteActivity(aKey, ts)
    // The bind is read again for its display name and charmer at each ending.
    if aKey == Names.idKey(target) {
        let said = st.ally.markAmbiguous(aKey)
        if said, let b = st.ally.bindOf(aKey) {
            st.log(ts, "charm", "dropped",
                   "~ \(b.display): a second one is active - \(b.charmer)'s pet is unreadable")
        }
        return
    }
    if !st.allyFriendly(Names.idKey(target)) { return }
    // `softHostile` hands back the bind it retired, which is what the line needs to name.
    if let gone = st.ally.softHostile(aKey) {
        st.log(ts, "charm", "dropped",
               "✕ \(gone.display) turned on \(target) - \(gone.charmer)'s charm broke")
    }
}

/// Book one mob-vs-mob damage line to the ally who owns the attacker. Called only for lines
/// `classify` ignored, and only while the bind is live and unambiguous.
func routeAllyPetDamage(_ st: EngineState, _ ev: DamageEvent) {
    if st.ally.idle() { return }
    guard let bind = st.ally.creditable(Names.idKey(ev.attacker)) else { return }
    let src = allyPetSource(bind)
    both(st, ev.ts, true) { agg in agg.addOut(src, ev, false) }
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, damageInstant(ev, "allyPet", tgtName))
    st.log(ev.ts, ev.dtype, "allyPet",
           "\(src.name) → \(tgtName)  \(ev.amount)\(ev.crit ? "*" : "")  \(ev.skill)")
}

/// The avoided-swing twin, on the same aggregate-only terms. A miss carries no amount, so it can
/// move no total anywhere.
func routeAllyPetMiss(_ st: EngineState, _ ev: MissLine, _ fold: MissFold) {
    if st.ally.idle() { return }
    guard let bind = st.ally.creditable(Names.idKey(ev.attacker)) else { return }
    let src = allyPetSource(bind)
    both(st, ev.ts, true) { agg in agg.addOutMiss(src, fold) }
    let tgtName = noteDefender(st, ev.target, ev.ts)
    pushFreshTimeline(st, ev.ts, missInstant(ev, "allyPet", tgtName))
    st.log(ev.ts, "miss", "allyPet", "\(src.name) ✕ \(tgtName) (\(ev.mtype.asStr))")
}
