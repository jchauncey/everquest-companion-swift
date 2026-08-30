// The proc-ledger serialization (fold/src/combat/procviews.rs): one segment's `Agg` plus the session
// state timeline, turned into the procs view the renderer draws.
//
// Additive only — every number here is a count or an index over damage the meter already counted.
//
// Four counting rules, because collapsing any of them makes a proc meter lie:
//
//   1. A poison lane counts emotes and reports tick damage and healing separately; the three are
//      each correct for their own question and are never summed.
//   2. A poison lane suppresses the spell-proc lane of the same name — one proc can print both an
//      emote and a typed poison-damage line, and emitting both lanes counts it twice.
//   3. A slay lane's `directDamage` is damage on swings that procced slay, not damage slay added;
//      the excess over an ordinary swing rides in `marginalDamage` with its assumption stated.
//   4. A spell lane's `count` is the larger of its damage-line and heal-line firings, never the sum.
//
// A lane's `linked` rows come from the per-state firing split against the per-state swing exposure,
// both folded on ingest. Spell lanes only: a poison lane's link to its own coat is tautological, and
// a slay lane's `directDamage` is not damage the proc added. Both keep an empty list rather than a
// zero-filled one.
import Foundation
import EQLog
import EQCompanionCore

/// `(Finishing Blow)` — the modifier name the parser recombines by hand.
public let FINISHING_BLOW = "Finishing Blow"

/// A lane's effect-landing graft entry: the ledger's raw label plus how many emotes it counted.
public struct EffectLanding {
    public var name: String
    public var count: Int64
}

/// One lane of the counting ledger (Strikes, poison damage, dispels).
public struct ProcLane {
    public var name: String
    public var count: Int64
    public var total: Int64?
    public var ambiguous: Bool?

    public var json: JSONValue {
        var o: [String: JSONValue] = ["name": .string(name), "count": .int(count)]
        if let t = total { o["total"] = .int(t) }
        if let a = ambiguous { o["ambiguous"] = .bool(a) }
        return .object(o)
    }
}

/// A coat applied inside this fight, stamped relative to the fight's opening instant. Not a
/// `CoatSlot`: that shape carries an absolute `sinceTs` and answers "when did this go on", while
/// this one answers "how far into the pull".
public struct CoatMarkView {
    public var poison: String
    public var tMs: Int64

    public var json: JSONValue { ["poison": .string(poison), "tMs": .int(tMs)] }
}

public struct ProcLaneView {
    public var name: String
    public var count: Int64
    public var origin: String
    public var rate: ProcRateView
    public var directDamage: Int64
    public var directHeal: Int64
    public var pctOfOut: Double
    public var dpsContribution: Double
    public var resisted: Int64?
    public var resistPct: Double?
    public var linked: [ProcLink]
    public var ambiguous: Bool?
    public var marginalDamage: Double?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name), "count": .int(count), "origin": .string(origin),
            "rate": rate.json, "directDamage": .int(directDamage), "directHeal": .int(directHeal),
            "pctOfOut": .double(pctOfOut), "dpsContribution": .double(dpsContribution),
            "linked": .array(linked.map(\.json)),
        ]
        if let v = resisted { o["resisted"] = .int(v) }
        if let v = resistPct { o["resistPct"] = .double(v) }
        if let v = ambiguous { o["ambiguous"] = .bool(v) }
        if let v = marginalDamage { o["marginalDamage"] = .double(v) }
        return .object(o)
    }
}

public struct ProcSkillTag {
    public var skill: String
    public var lane: String
    public var origin: String
    public var rate: ProcRateView
    public var activeSec: Double

    public var json: JSONValue {
        [
            "skill": .string(skill), "lane": .string(lane), "origin": .string(origin),
            "rate": rate.json, "activeSec": .double(activeSec),
        ]
    }
}

public struct ProcsView {
    public var coatAtEngage: CoatSlot?
    public var combatAtEngage: [CoatSlot]
    public var slowExpected: Bool
    public var coats: [CoatMarkView]
    public var strikes: [ProcLane]
    public var strikeCount: Int64
    public var slowLands: Int64
    public var slowLandMs: Int64?
    public var poisonDamage: [ProcLane]
    public var poisonDamageTotal: Int64
    public var dispels: [ProcLane]
    public var dispelCount: Int64
    public var stanceSwitches: Int64
    public var invocationSwitches: Int64
    public var lanes: [ProcLaneView]
    public var overall: ProcRateView
    public var procSkills: [ProcSkillTag]
    public var states: [StateSpan]
    public var attribution: AttributionReport?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "combatAtEngage": .array(combatAtEngage.map(\.json)),
            "slowExpected": .bool(slowExpected),
            "coats": .array(coats.map(\.json)),
            "strikes": .array(strikes.map(\.json)),
            "strikeCount": .int(strikeCount),
            "slowLands": .int(slowLands),
            "poisonDamage": .array(poisonDamage.map(\.json)),
            "poisonDamageTotal": .int(poisonDamageTotal),
            "dispels": .array(dispels.map(\.json)),
            "dispelCount": .int(dispelCount),
            "stanceSwitches": .int(stanceSwitches),
            "invocationSwitches": .int(invocationSwitches),
            "lanes": .array(lanes.map(\.json)),
            "overall": overall.json,
            "procSkills": .array(procSkills.map(\.json)),
            "states": .array(states.map(\.json)),
        ]
        if let c = coatAtEngage { o["coatAtEngage"] = c.json }
        if let m = slowLandMs { o["slowLandMs"] = .int(m) }
        if let a = attribution { o["attribution"] = a.json }
        return .object(o)
    }
}

/// Everything one procs view needs. A fight, the live zone aggregate and a frozen zone session
/// differ only in these fields.
public struct ProcsViewSpec {
    public var st: EngineState
    public var agg: Agg
    public var id: String
    /// `fight` or `zone`.
    public var kind: String
    public var durationSec: Double
    public var activeSec: Double
    /// Segment span in absolute ms — the window the state spans are clipped to.
    public var startTs: Int64
    public var endTs: Int64
    /// Present only for a fight.
    public var enc: Encounter?
}

/// The denominators every lane in a segment shares. Resolved once.
private struct RateBase {
    var activeSec: Double
    var durationSec: Double
    var swings: Int64
    var outTotal: Int64
    var sources: SourceWindows
}

/// Every state span this segment saw, with the active seconds it was open for. `unknown` is not an
/// error state — it is the answer for every item proc and any buff that predates the window.
private struct SourceWindows {
    var activeSecByState = JSMap<Double>()
    var nameByState = JSMap<String>()
}

private func sourceWindows(_ spec: ProcsViewSpec, _ states: [StateSpan]) -> SourceWindows {
    var w = SourceWindows()
    for (key, ms) in spec.agg.procs.activeMsByState.pairs {
        w.activeSecByState.insert(key, Double(ms) / 1000.0)
    }
    for s in states { w.nameByState.insert(stateKeyOf(s.kind, s.key), s.name) }
    return w
}

/// The source window for a poison lane: the coat spans of every poison whose roster grants one of
/// the lane's Strikes.
///
/// Summing those spans is a union, not a double count: poisons that grant the same Strike are
/// mutually exclusive. Every multi-granting poison is utility, and only one utility coat can be on;
/// every combat Strike is granted by exactly one venom.
///
/// `nil` when no granting coat has an observed span here — a coat applied before the window opened.
private func poisonSource(_ label: String, _ w: SourceWindows) -> ProcSourceWindow? {
    let strikes = Set(label.components(separatedBy: " / ")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    var sec = 0.0
    var names: [String] = []
    for p in POISONS {
        if !p.strikes.contains(where: { strikes.contains($0) }) { continue }
        let key = stateKeyOf(.coat, Names.idKey(p.name))
        guard let s = w.activeSecByState[key] else { continue }
        if s <= 0.0 { continue }
        sec += s
        names.append(w.nameByState[key] ?? p.name)
    }
    if names.isEmpty { return nil }
    return ProcSourceWindow(activeSec: sec, name: names.joined(separator: " + "))
}

/// The source window for a spell lane: the tracked proc buff that grants it, when the catalog names
/// one and its span was observed here (`Instrument of Nife` grants `Condemnation of Nife`).
private func spellSource(_ name: String, _ w: SourceWindows) -> ProcSourceWindow? {
    let key = Names.spellCanonKey(name)
    for b in PROC_BUFF_CATALOG {
        guard let grants = b.grantsProc else { continue }
        if Names.spellCanonKey(grants) != key { continue }
        let stateKey = stateKeyOf(.buff, Names.idKey(b.name))
        if let sec = w.activeSecByState[stateKey], sec > 0.0 {
            return ProcSourceWindow(activeSec: sec, name: w.nameByState[stateKey] ?? b.name)
        }
    }
    return nil
}

/// The source-window half of a lane's rate input. Three outcomes:
///   known   — a coat span or a tracked proc-buff span; the rate is over it exactly.
///   unknown — a spell or poison lane whose granting span this segment never saw; the segment is
///             assumed and `sourceAmbiguous` says so.
///   n/a     — a slay, aa or click lane. There is no span that could have been off.
private func sourceInput(_ origin: String, _ label: String,
                         _ w: SourceWindows) -> (ProcSourceWindow?, Bool) {
    if origin == "slay" || origin == "aa" || origin == "click" { return (nil, false) }
    let source = origin == "poison" ? poisonSource(label, w) : spellSource(label, w)
    return source == nil ? (nil, true) : (source, false)
}

private func rateBase(_ spec: ProcsViewSpec, _ states: [StateSpan]) -> RateBase {
    RateBase(activeSec: spec.activeSec, durationSec: spec.durationSec,
             swings: spec.agg.procs.swings, outTotal: Agg.sum(spec.agg.out),
             sources: sourceWindows(spec, states))
}

/// One lane's rates: divided by its source window when the model knows one, flagged when it does
/// not.
private func laneRate(_ count: Int64, _ b: RateBase, _ origin: String, _ label: String) -> ProcRateView {
    let (source, sourceUnknown) = sourceInput(origin, label, b.sources)
    return procRate(RateInput(count: count, activeSec: b.activeSec, durationSec: b.durationSec,
                              swings: b.swings, source: source, sourceUnknown: sourceUnknown))
}

/// An emote label may name several Strikes — one emote sentence is shared by two venoms — and the
/// ledger keeps both in one ` / `-joined label. Every candidate is joined against the damage lanes
/// and every candidate suppresses its spell-proc twin.
private func candidateKeys(_ label: String) -> [String] {
    label.components(separatedBy: " / ")
        .map { Names.spellCanonKey($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

/// Your damage rows recorded under any of `keys` — the one place a proc lane is matched against the
/// meter's own skill lanes, so "which rows is this lane" cannot come to mean two things.
///
/// Names are matched rank-normalized and proc-marker-stripped, so both halves of a split spell match,
/// and returned raw because the raw string is what the drill row is labelled with.
private func skillsMatching(_ you: SourceStat?, _ keys: [String]) -> [(String, Int64, Int64)] {
    guard let you = you else { return [] }
    var out: [(String, Int64, Int64)] = []
    for s in you.bySkill.values where keys.contains(laneCanonKey(s.name)) {
        out.append((s.name, s.total, s.hits))
    }
    return out
}

/// Damage delivered under a given skill name by you, read back out of the same aggregate the bars
/// come from. An index, never a second accumulation.
private func deliveredBy(_ you: SourceStat?, _ keys: [String]) -> Int64 {
    skillsMatching(you, keys).map(\.1).reduce(0, +)
}

/// Your resists on the rows a lane covers. Same join and same aggregate as `deliveredBy`, so a lane
/// and the drill row beneath it read one counter and not two.
private func resistedBy(_ you: SourceStat?, _ keys: [String]) -> Int64 {
    guard let you = you else { return 0 }
    return you.bySkill.values.filter { keys.contains(laneCanonKey($0.name)) }
        .map(\.resists).reduce(0, +)
}

/// Healing recorded under a given skill name by the cast-less detector. Kept separate from damage: a
/// tap can return more than it deals, so neither can be derived from the other.
private func healedBy(_ agg: Agg, _ keys: [String]) -> Int64 {
    agg.procs.spellProcs.pairs.filter { keys.contains($0.0) }.map { $0.1.heal }.reduce(0, +)
}

/// Effect landings with no damage line. Some Strikes print only an emote when they land (`<mob>'s
/// limbs move slower!`) while their resists print the spell name like any other spell, so without
/// this join the drill builds a lane for them out of resists alone.
///
/// A strike lane contributes only when no meter row has landed a hit under its name: where a lane
/// does land damage its firings are already represented, and adding the emotes would double-count.
/// The gate is `hits > 0` and not "a row exists", because a resist is exactly what creates the row.
public func effectLandings(_ agg: Agg) -> JSMap<EffectLanding> {
    let you = agg.out["you"]
    var out = JSMap<EffectLanding>()
    for s in agg.procs.strikes.values {
        let keys = candidateKeys(s.name)
        if skillsMatching(you, keys).contains(where: { $0.2 > 0 }) { continue }
        out.insert(keys[0], EffectLanding(name: s.name, count: s.count))
    }
    return out
}

/// One lane, with its rates and its Tier-A numbers. `damage` and `heal` are kept apart all the way
/// down, for the reason `healedBy` states.
private struct LaneSpec {
    var name: String
    var origin: String
    var count: Int64
    var damage: Int64
    var heal: Int64
    var resisted: Int64
    var linked: [ProcLink]
}

private func lane(_ s: LaneSpec, _ b: RateBase) -> ProcLaneView {
    let attempts = s.count + s.resisted
    return ProcLaneView(
        name: s.name,
        count: s.count,
        origin: s.origin,
        rate: laneRate(s.count, b, s.origin, s.name),
        directDamage: s.damage,
        directHeal: s.heal,
        pctOfOut: b.outTotal > 0 ? (Double(s.damage) / Double(b.outTotal)) * 100.0 : 0.0,
        dpsContribution: b.activeSec > 0.0 ? Double(s.damage) / b.activeSec : 0.0,
        // The other half of the lane's record: `count` is what landed, this is what did not.
        resisted: s.resisted > 0 ? s.resisted : nil,
        resistPct: s.resisted > 0 ? (Double(s.resisted) / Double(attempts)) * 100.0 : nil,
        linked: s.linked,
        ambiguous: nil,
        marginalDamage: nil)
}

/// Rogue-poison lanes. `count` is the emote count and nothing else (rule 1).
private func poisonLanes(_ spec: ProcsViewSpec, _ you: SourceStat?, _ b: RateBase) -> [ProcLaneView] {
    var out: [ProcLaneView] = []
    for s in spec.agg.procs.strikes.values {
        let keys = candidateKeys(s.name)
        var l = lane(LaneSpec(name: s.name, origin: "poison", count: s.count,
                              damage: deliveredBy(you, keys), heal: healedBy(spec.agg, keys),
                              resisted: resistedBy(you, keys), linked: []), b)
        if s.ambiguous { l.ambiguous = true }
        out.append(l)
    }
    return stableSorted(out) { x, y in
        if x.count != y.count { return x.count > y.count }
        return Collate.less(x.name, y.name)
    }
}

/// Cast-less spell lanes, minus any name a poison emote already counted (rule 2).
private func spellLanes(_ spec: ProcsViewSpec, _ b: RateBase, _ covered: Set<String>,
                        _ states: [StateSpan]) -> [ProcLaneView] {
    let you = spec.agg.out["you"]
    let swings = spec.agg.procs.swings
    var out: [ProcLaneView] = []
    for (key, l) in spec.agg.procs.spellProcs.pairs {
        if covered.contains(key) { continue }
        out.append(lane(LaneSpec(
            // A held clicky is its own origin: same counts, same denominators, same links. Only the
            // word changes, because "proc" claims a mechanism this firing does not have.
            name: l.name,
            origin: l.click ? "click" : "spell",
            count: laneCount(l),
            damage: l.damage,
            heal: l.heal,
            resisted: resistedBy(you, [key]),
            linked: linksFor(l, states, spec.agg.procs.swingsByState, swings)), b))
    }
    return stableSorted(out) { x, y in
        if x.count != y.count { return x.count > y.count }
        return Collate.less(x.name, y.name)
    }
}

/// The slay lane (rule 3), from the taxonomy's own `slay` category — a Slay Undead proc rides an
/// ordinary swing and prints no spell line of its own.
///
/// Emitted only when it fired; a permanent 0-count row on every non-undead pull is noise.
/// `marginalDamage` subtracts the swing that would have landed anyway, at this segment's mean melee
/// hit.
private func slayLanes(_ you: SourceStat?, _ b: RateBase) -> [ProcLaneView] {
    guard let slay = you?.byCategory["slay"] else { return [] }
    if slay.hits == 0 { return [] }
    let melee = you?.byCategory["melee"]
    let meanMelee: Double = (melee != nil && melee!.hits > 0)
        ? Double(melee!.total) / Double(melee!.hits) : 0.0
    var l = lane(LaneSpec(name: "Slay Undead", origin: "slay", count: slay.hits,
                          damage: slay.total, heal: 0, resisted: 0, linked: []), b)
    l.marginalDamage = Double(slay.total) - Double(slay.hits) * meanMelee
    return [l]
}

/// The Finishing Blow lane — the other swing-borne AA. The modifier has always been parsed and
/// tallied on the source's `mods`, but the drill groups by skill, so the damage sits invisibly spread
/// across Slash / Bash / Strike. This gives that counted fact a surface.
///
/// It is not a category, where Slay Undead is one: a category moves the damage out of `melee`, and
/// Finishing Blow's damage IS a weapon swing's, so moving it would change every melee mean and swing
/// denominator to fix a listing problem.
///
/// Its baseline differs from the slay lane's by one subtraction. Slay swings left the melee category,
/// so `melee` there is already the ordinary body; Finishing Blow swings did not, so the swings the
/// proc rode are subtracted out before the mean is taken.
private func finishingBlowLanes(_ you: SourceStat?, _ b: RateBase) -> [ProcLaneView] {
    guard let t = you?.mods[FINISHING_BLOW] else { return [] }
    // `count` includes avoided swings; the miss family only carries single-word modifiers, so this
    // subtraction is a guard and not a correction.
    let hits = t.count - t.avoided
    if hits <= 0 { return [] }
    let melee = you?.byCategory["melee"]
    // The ordinary body: this category minus the swings this proc rode. Clamped because a compound
    // carrying both `Slay Undead` and `Finishing Blow` would book under `slay` while the tally still
    // counted it here. A negative baseline is worse.
    let plainHits = Swift.max((melee?.hits ?? 0) - hits, 0)
    let plainTotal = Swift.max((melee?.total ?? 0) - t.total, 0)
    let meanMelee = plainHits > 0 ? Double(plainTotal) / Double(plainHits) : 0.0
    var l = lane(LaneSpec(name: FINISHING_BLOW, origin: "aa", count: hits, damage: t.total,
                          heal: 0, resisted: 0, linked: []), b)
    l.marginalDamage = Double(t.total) - Double(hits) * meanMelee
    return [l]
}

/// The lane list, one pass per origin: poison, spell, slay, aa, each block sorted by count desc. The
/// two swing-borne AAs sit last because they are the rows whose `directDamage` is not the damage the
/// proc added.
private func buildLanes(_ spec: ProcsViewSpec, _ states: [StateSpan]) -> [ProcLaneView] {
    let b = rateBase(spec, states)
    let you = spec.agg.out["you"]
    let poison = poisonLanes(spec, you, b)
    var covered = Set<String>()
    for l in poison { for k in candidateKeys(l.name) { covered.insert(k) } }
    // One entry per distinct `<kind>:<key>`, in the order the spans first appear.
    var seen = JSMap<StateSpan>()
    for s in states {
        let k = stateKeyOf(s.kind, s.key)
        if !seen.containsKey(k) { seen.insert(k, s) }
    }
    let linkStates = seen.values
    var out = poison
    out.append(contentsOf: spellLanes(spec, b, covered, linkStates))
    out.append(contentsOf: slayLanes(you, b))
    out.append(contentsOf: finishingBlowLanes(you, b))
    return out
}

/// The damage rows one lane covers.
///
/// A slay lane is a presentation exception: the aggregate's rows are the weapon names, and the drill
/// merges them into one row under the lane's name. Tagging the weapon rows instead would put a proc
/// rate on lanes that are mostly ordinary swings.
///
/// A cast-less lane narrows to the marked rows when any exist, so the proc rate does not land on the
/// hand-casts too — the confusion the origin split exists to end.
private func taggedSkills(_ you: SourceStat?, _ l: ProcLaneView) -> [String] {
    if l.origin == "slay" { return [l.name] }
    let rows = skillsMatching(you, candidateKeys(l.name))
    let split = rows.filter { isCastlessLaneName($0.0) }
    let castless = l.origin == "spell" || l.origin == "click"
    return (castless && !split.isEmpty) ? split.map(\.0) : rows.map(\.0)
}

/// The is-a-proc join: one tag per (damage row, lane), so the drill marks exactly the rows the ledger
/// counts. It runs here because this is where both definitions of "proc" live — the Strike ledger and
/// the cast-less inference — and a second definition downstream is a future disagreement.
///
/// Two absences are deliberate. Only your rows are tagged, since the lanes are folded from your
/// procs. And an `aa` lane is turned away: Finishing Blow rides a swing that stays in the `melee`
/// category, so no row IS the proc.
private func procSkillTags(_ spec: ProcsViewSpec, _ lanes: [ProcLaneView]) -> [ProcSkillTag] {
    let you = spec.agg.out["you"]
    let landed = effectLandings(spec.agg)
    var out: [ProcSkillTag] = []
    for l in lanes {
        if l.origin == "aa" { continue }
        var skills = taggedSkills(you, l)
        // A damage-less strike (Weakening, Clumsiness and the like deal nothing) is its own row, so
        // the tag joins on the ledger's label the way a damage row's tag joins on its own.
        if skills.isEmpty && landed.containsKey(candidateKeys(l.name)[0]) {
            skills.append(l.name)
        }
        for skill in skills {
            out.append(ProcSkillTag(skill: skill, lane: l.name, origin: l.origin, rate: l.rate,
                                    activeSec: spec.activeSec))
        }
    }
    return out
}

/// The procs-per-minute headline, summed over the lanes it is built from so it cannot drift from the
/// rows beneath it.
///
/// It divides by the segment while every lane divides by its own source window: "how many procs did
/// this fight see per minute" is a question about the fight, and summing lanes measured over disjoint
/// windows would give a rate with no denominator. It carries no source fields, an absence meaning
/// "not applicable" where a lane's means "unknown".
///
/// A click lane is excluded: a button the player pressed is not a proc.
private func overallRate(_ lanes: [ProcLaneView], _ b: RateBase) -> ProcRateView {
    procRate(RateInput(count: lanes.map { $0.origin == "click" ? 0 : $0.count }.reduce(0, +),
                       activeSec: b.activeSec, durationSec: b.durationSec, swings: b.swings,
                       source: nil, sourceUnknown: false))
}

/// The per-segment proc ledger plus the proc-analytics superset, built entirely from the frozen
/// aggregate and the session state timeline.
///
/// `enc` is present only for a fight: coats-at-engage and the engage-relative timings are questions
/// about one pull's opening instant, and a zone session has no such instant. A zone view therefore
/// reports no `slowLandMs` and no coats rather than measuring from an arbitrary zero.
public func buildProcsView(_ spec: ProcsViewSpec) -> ProcsView {
    let p = spec.agg.procs
    let strikes = stableSorted(p.strikes.values.map {
        ProcLane(name: $0.name, count: $0.count, total: nil, ambiguous: $0.ambiguous ? true : nil)
    }) { a, b in
        if a.count != b.count { return a.count > b.count }
        return Collate.less(a.name, b.name)
    }
    let poisonDamage = stableSorted(p.poisonDamage.values.map {
        ProcLane(name: $0.name, count: $0.count, total: $0.total, ambiguous: nil)
    }) { a, b in
        let ta = a.total ?? 0, tb = b.total ?? 0
        if ta != tb { return ta > tb }
        return Collate.less(a.name, b.name)
    }
    let dispels = stableSorted(p.dispels.values.map {
        ProcLane(name: $0.name, count: $0.count, total: nil, ambiguous: true)
    }) { a, b in
        if a.count != b.count { return a.count > b.count }
        return Collate.less(a.name, b.name)
    }

    let coatAtEngage = spec.enc?.coatAtEngage
    let start = spec.enc?.startTs ?? 0
    let states = spec.st.stateTimeline.spansOverlapping(spec.startTs, spec.endTs)
    let b = rateBase(spec, states)
    let lanes = buildLanes(spec, states)
    var attribution: AttributionReport?
    if spec.kind == "zone" {
        let forDirect = lanes.map {
            LaneForDirect(name: $0.name, directDamage: $0.directDamage, directHeal: $0.directHeal,
                          dpsContribution: $0.dpsContribution, linked: $0.linked)
        }
        attribution = buildAttributionReport(spec.id, spec.agg.windows.list(), states, forDirect)
    }
    return ProcsView(
        coatAtEngage: coatAtEngage,
        combatAtEngage: spec.enc?.combatAtEngage ?? [],
        slowExpected: coatAtEngage.map { isSlowCapable($0.poison) } ?? false,
        coats: spec.enc == nil ? []
            : p.coats.map { CoatMarkView(poison: $0.poison, tMs: Swift.max($0.ts - start, 0)) },
        strikes: strikes,
        strikeCount: strikes.map(\.count).reduce(0, +),
        slowLands: p.slowLands,
        slowLandMs: (spec.enc != nil && p.firstSlowTs > 0)
            ? Swift.max(p.firstSlowTs - start, 0) : nil,
        poisonDamage: poisonDamage,
        poisonDamageTotal: poisonDamage.map { $0.total ?? 0 }.reduce(0, +),
        dispels: dispels,
        dispelCount: dispels.map(\.count).reduce(0, +),
        stanceSwitches: p.stanceSwitches,
        invocationSwitches: p.invocationSwitches,
        lanes: lanes,
        overall: overallRate(lanes, b),
        procSkills: procSkillTags(spec, lanes),
        states: states,
        // Tier B is zone-scope only: a single pull has no inactive sample, so a per-fight
        // counterfactual would invite reading one minute of noise as an effect.
        attribution: attribution)
}
