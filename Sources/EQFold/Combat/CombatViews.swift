// Segment serialization: a selected fight or zone session, turned into the view the renderer draws
// (fold/src/combat/views.rs).
//
// Read-only over the engine — `buildSelected` takes the state — so selecting a fight can never
// finalize an encounter or move a point of damage. Anything that reshapes a row copies first: the
// maps handed to `sourceViews` are the engine's live accumulators, and a write into one would
// corrupt the fight, the zone session and every later snapshot permanently.
//
// Layout belongs to the renderer. This module emits exactly the engine's own attribution — you and
// each pet as their own authoritative row — and never a second presentation of the same numbers.
//
// `lands` is a view-time graft, never an ingest counter: "does this Strike have damage rows" is only
// answerable once every line of the segment is in. That is why this file carries its own row shape
// rather than reusing `SkillStat`.
import Foundation
import EQLog
import EQCompanionCore

/// The stable UI ordering of the damage taxonomy.
private let CATEGORY_ORDER = ["melee", "slay", "spell", "dot", "ds"]

private func categoryRank(_ c: String) -> Int {
    CATEGORY_ORDER.firstIndex(of: c) ?? Int.max
}

/// Per-skill cap in the drill, top level and per category alike — a small payload.
private let SKILL_CAP = 12

/// The generic lane name the parser gives every weapon verb (`slash`, `pierce`, `crush` and `hit`
/// all answer "Melee") — a label to replace, not to show four times in one table.
private let GENERIC_LANE = "Melee"

/// A per-skill lane as the view sees it: the accumulator's counters plus the effect-landing graft.
private struct SkillRow {
    var name: String
    var total: Int64 = 0
    var hits: Int64 = 0
    var crits: Int64 = 0
    var max: Int64 = 0
    /// Smallest landed amount; 0 = "no landed hit yet" (the accumulator's own sentinel).
    var min: Int64 = 0
    var misses: Int64 = 0
    var resists: Int64 = 0
    /// Landings this lane recorded with no damage line of its own — grafted here, never accumulated.
    var lands: Int64 = 0

    init(_ s: SkillStat) {
        name = s.name; total = s.total; hits = s.hits; crits = s.crits; max = s.max
        min = s.min; misses = s.misses; resists = s.resists; lands = 0
    }

    init(name: String) { self.name = name }
}

private struct CatRow {
    var category: String
    var total: Int64 = 0
    var hits: Int64 = 0
    var crits: Int64 = 0
    var max: Int64 = 0
    var resists: Int64 = 0
    var bySkill = JSMap<SkillRow>()

    init(_ c: CategoryStat) {
        category = c.category; total = c.total; hits = c.hits; crits = c.crits
        max = c.max; resists = c.resists
        for (k, v) in c.bySkill.pairs { bySkill.insert(k, SkillRow(v)) }
    }

    init(category: String) { self.category = category }
}

/// One source, projected into the view's own row shape. Always a copy — the source is live state.
private struct SourceRows {
    var bySkill = JSMap<SkillRow>()
    var byCategory = JSMap<CatRow>()
}

private func project(_ s: SourceStat) -> SourceRows {
    var r = SourceRows()
    for (k, v) in s.bySkill.pairs { r.bySkill.insert(k, SkillRow(v)) }
    for (k, v) in s.byCategory.pairs { r.byCategory.insert(k, CatRow(v)) }
    return r
}

/// A copy of `s`'s lanes carrying the effect landings.
///
/// A lane the resists already created simply gains its `lands`; a lane with landings and no resists
/// is created in the `spell` category, the same one a resist lands in. Its total is 0, so it sorts to
/// the bottom of the ranked list.
///
/// `laneCanonKey`, not `spellCanonKey`: a cast-less lane carries the origin marker in its name, and a
/// landing belongs to the spell either half of a split is about.
private func withLandings(_ s: SourceStat, _ lands: JSMap<EffectLanding>) -> SourceRows {
    var rows = project(s)
    var spell = rows.byCategory["spell"] ?? CatRow(category: "spell")
    var byKey = JSMap<String>()
    for (k, v) in rows.bySkill.pairs { byKey.insert(laneCanonKey(v.name), k) }
    for (key, l) in lands.pairs {
        let name = byKey[key] ?? l.name
        var a = rows.bySkill[name] ?? SkillRow(name: name)
        a.lands += l.count
        rows.bySkill.insert(name, a)
        var b = spell.bySkill[name] ?? SkillRow(name: name)
        b.lands += l.count
        spell.bySkill.insert(name, b)
    }
    rows.byCategory.insert("spell", spell)
    return rows
}

// MARK: - Wire shapes

public struct SkillView {
    public var name: String
    public var total: Int64
    public var pct: Double
    public var hits: Int64
    public var crits: Int64
    public var max: Int64
    /// Meaningful only over landed hits: a lane that only missed or resisted has no smallest hit to
    /// report, and emitting 0 would read as "landed a 0-damage hit".
    public var min: Int64?
    public var misses: Int64
    public var resists: Int64?
    /// Absent, never 0: absent means no landing evidence exists for this lane, which is the truth for
    /// a hand-cast stun that prints nothing when it lands, so the UI declines to state a resist rate
    /// rather than print 100%.
    public var lands: Int64?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name), "total": .int(total), "pct": .double(pct),
            "hits": .int(hits), "crits": .int(crits), "max": .int(max), "misses": .int(misses),
        ]
        if let v = min { o["min"] = .int(v) }
        if let v = resists { o["resists"] = .int(v) }
        if let v = lands { o["lands"] = .int(v) }
        return .object(o)
    }
}

public struct CategoryView {
    public var category: String
    public var total: Int64
    public var pct: Double
    public var hits: Int64
    public var crits: Int64
    public var critPct: Double
    public var max: Int64
    public var resists: Int64
    public var resistPct: Double
    public var skills: [SkillView]

    public var json: JSONValue {
        [
            "category": .string(category), "total": .int(total), "pct": .double(pct),
            "hits": .int(hits), "crits": .int(crits), "critPct": .double(critPct),
            "max": .int(max), "resists": .int(resists), "resistPct": .double(resistPct),
            "skills": .array(skills.map(\.json)),
        ]
    }
}

public struct MissBreakdown {
    public var miss: Int64
    public var dodge: Int64
    public var parry: Int64
    public var riposte: Int64
    public var block: Int64
    public var absorb: Int64

    init(_ m: [Int64]) {
        miss = m[0]; dodge = m[1]; parry = m[2]; riposte = m[3]; block = m[4]; absorb = m[5]
    }

    public var json: JSONValue {
        [
            "miss": .int(miss), "dodge": .int(dodge), "parry": .int(parry),
            "riposte": .int(riposte), "block": .int(block), "absorb": .int(absorb),
        ]
    }
}

public struct RatesView {
    public var miss: Double
    public var dodge: Double
    public var parry: Double
    public var riposte: Double
    public var block: Double
    public var absorb: Double

    public var json: JSONValue {
        [
            "miss": .double(miss), "dodge": .double(dodge), "parry": .double(parry),
            "riposte": .double(riposte), "block": .double(block), "absorb": .double(absorb),
        ]
    }
}

public struct RoundsView {
    public var totalRounds: Int64
    public var avgHitsPerRound: Double
    public var maxHitsInRound: Int64
    public var multiHitRounds: Int64
    /// `histogram[k-1]` = rounds that landed exactly k hits.
    public var histogram: [Int64]

    public var json: JSONValue {
        [
            "totalRounds": .int(totalRounds), "avgHitsPerRound": .double(avgHitsPerRound),
            "maxHitsInRound": .int(maxHitsInRound), "multiHitRounds": .int(multiHitRounds),
            "histogram": .array(histogram.map { .int($0) }),
        ]
    }
}

public struct RoundLaneView {
    public var verb: String
    public var label: String
    public var rounds: Int64
    public var buckets: [Int64]
    public var multiRounds: Int64
    public var multiPct: Double
    public var fannedRounds: Int64
    public var confidence: String

    public var json: JSONValue {
        [
            "verb": .string(verb), "label": .string(label), "rounds": .int(rounds),
            "buckets": .array(buckets.map { .int($0) }), "multiRounds": .int(multiRounds),
            "multiPct": .double(multiPct), "fannedRounds": .int(fannedRounds),
            "confidence": .string(confidence),
        ]
    }
}

public struct ModifierTallyView {
    public var name: String
    public var count: Int64
    public var avoided: Int64

    public var json: JSONValue {
        ["name": .string(name), "count": .int(count), "avoided": .int(avoided)]
    }
}

public struct ExcludedView {
    public var frenzy: Int64
    public var riposte: Int64
    public var flurry: Int64
    public var rampage: Int64

    public var json: JSONValue {
        ["frenzy": .int(frenzy), "riposte": .int(riposte), "flurry": .int(flurry),
         "rampage": .int(rampage)]
    }
}

public struct SourceRoundsView {
    public var lanes: [RoundLaneView]
    public var primaryRounds: Int64
    public var excluded: ExcludedView
    public var modifiers: [ModifierTallyView]
    public var ripostesGiven: Int64
    public var riposteLanded: Int64
    public var riposteDamage: Int64
    public var ripostesTaken: Int64
    public var rampagesTaken: Int64
    public var flurries: Int64
    public var flurryPct: Double

    public var json: JSONValue {
        [
            "lanes": .array(lanes.map(\.json)), "primaryRounds": .int(primaryRounds),
            "excluded": excluded.json, "modifiers": .array(modifiers.map(\.json)),
            "ripostesGiven": .int(ripostesGiven), "riposteLanded": .int(riposteLanded),
            "riposteDamage": .int(riposteDamage), "ripostesTaken": .int(ripostesTaken),
            "rampagesTaken": .int(rampagesTaken), "flurries": .int(flurries),
            "flurryPct": .double(flurryPct),
        ]
    }
}

public struct SourceView {
    public var id: String
    public var name: String
    public var kind: String
    public var total: Int64
    public var dps: Double
    public var pct: Double
    public var hits: Int64
    public var crits: Int64
    public var critPct: Double
    public var ambiguousHits: Int64
    public var ambiguousTotal: Int64
    public var misses: Int64
    public var hitPct: Double
    public var missBreakdown: MissBreakdown
    public var resists: Int64
    public var resistPct: Double
    public var skills: [SkillView]
    public var categories: [CategoryView]
    public var rounds: RoundsView?
    public var roundStats: SourceRoundsView?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "kind": .string(kind),
            "total": .int(total), "dps": .double(dps), "pct": .double(pct),
            "hits": .int(hits), "crits": .int(crits), "critPct": .double(critPct),
            "ambiguousHits": .int(ambiguousHits), "ambiguousTotal": .int(ambiguousTotal),
            "misses": .int(misses), "hitPct": .double(hitPct),
            "missBreakdown": missBreakdown.json, "resists": .int(resists),
            "resistPct": .double(resistPct), "skills": .array(skills.map(\.json)),
            "categories": .array(categories.map(\.json)),
        ]
        if let r = rounds { o["rounds"] = r.json }
        if let r = roundStats { o["roundStats"] = r.json }
        return .object(o)
    }
}

public struct RiposteView {
    public var events: Int64
    public var swings: Int64
    public var hits: Int64
    public var damage: Int64
    public var pctOfSwingDamage: Double
    public var taken: Int64

    public var json: JSONValue {
        [
            "events": .int(events), "swings": .int(swings), "hits": .int(hits),
            "damage": .int(damage), "pctOfSwingDamage": .double(pctOfSwingDamage),
            "taken": .int(taken),
        ]
    }
}

public struct DefenseView {
    public var swings: Int64
    public var hits: Int64
    public var avoided: MissBreakdown
    public var avoidedTotal: Int64
    public var avoidedPct: Double
    public var defended: Int64
    public var defendedPct: Double
    public var rates: RatesView
    public var riposte: RiposteView

    public var json: JSONValue {
        [
            "swings": .int(swings), "hits": .int(hits), "avoided": avoided.json,
            "avoidedTotal": .int(avoidedTotal), "avoidedPct": .double(avoidedPct),
            "defended": .int(defended), "defendedPct": .double(defendedPct),
            "rates": rates.json, "riposte": riposte.json,
        ]
    }
}

public struct HealerView {
    public var name: String
    public var total: Int64
    public var count: Int64

    public var json: JSONValue {
        ["name": .string(name), "total": .int(total), "count": .int(count)]
    }
}

public struct SegmentView {
    public var id: String
    public var kind: String
    public var name: String
    public var zone: String?
    public var durationSec: Double
    public var active: Bool
    public var activeSec: Double
    public var outTotal: Int64
    public var outDps: Double
    public var activeDps: Double
    public var entities: [SourceView]
    public var inTotal: Int64
    public var inDps: Double
    public var incoming: [SourceView]
    public var defense: DefenseView
    public var enemyHealTotal: Int64
    public var incomingHealTotal: Int64
    public var incomingHealers: [HealerView]
    public var healing: HealingView
    public var procs: ProcsView

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "kind": .string(kind), "name": .string(name),
            "durationSec": .double(durationSec), "active": .bool(active),
            "activeSec": .double(activeSec), "outTotal": .int(outTotal),
            "outDps": .double(outDps), "activeDps": .double(activeDps),
            "entities": .array(entities.map(\.json)), "inTotal": .int(inTotal),
            "inDps": .double(inDps), "incoming": .array(incoming.map(\.json)),
            "defense": defense.json, "enemyHealTotal": .int(enemyHealTotal),
            "incomingHealTotal": .int(incomingHealTotal),
            "incomingHealers": .array(incomingHealers.map(\.json)),
            "healing": healing.json, "procs": procs.json,
        ]
        if let z = zone { o["zone"] = .string(z) }
        return .object(o)
    }
}

// MARK: - Builders

private func skillView(_ k: SkillRow, _ skMax: Int64) -> SkillView {
    SkillView(name: k.name, total: k.total, pct: (Double(k.total) / Double(skMax)) * 100.0,
              hits: k.hits, crits: k.crits, max: k.max,
              min: k.hits > 0 ? k.min : nil, misses: k.misses,
              resists: k.resists != 0 ? k.resists : nil,
              lands: k.lands != 0 ? k.lands : nil)
}

/// Rank per-skill lanes for the drill: damage first. The tiebreak only reorders rows with no damage
/// at all, where the lane with the most observations is the one worth a slot under the row cap.
private func rankSkills(_ rows: JSMap<SkillRow>) -> [SkillRow] {
    Rust.stableSorted(rows.values) { a, b in
        if a.total != b.total { return a.total > b.total }
        return (a.lands + a.resists) > (b.lands + b.resists)
    }
}

private func maxTotal(_ rows: JSMap<SkillRow>) -> Int64 {
    Swift.max(rows.values.map(\.total).max() ?? 0, 1)
}

/// Build the per-category drill-down views, ordered by `CATEGORY_ORDER`, each with its own per-skill
/// breakdown under the same row cap.
private func categoryViews(_ byCat: JSMap<CatRow>) -> [CategoryView] {
    let catMax = Double(Swift.max(byCat.values.map(\.total).max() ?? 0, 1))
    let cats = Rust.stableSorted(byCat.values) { categoryRank($0.category) < categoryRank($1.category) }
    return cats.map { c in
        let skMax = maxTotal(c.bySkill)
        let casts = c.hits + c.resists
        return CategoryView(
            category: c.category,
            total: c.total,
            pct: (Double(c.total) / catMax) * 100.0,
            hits: c.hits,
            crits: c.crits,
            critPct: c.hits > 0 ? (Double(c.crits) / Double(c.hits)) * 100.0 : 0.0,
            max: c.max,
            resists: c.resists,
            resistPct: casts > 0 ? (Double(c.resists) / Double(casts)) * 100.0 : 0.0,
            skills: rankSkills(c.bySkill).prefix(SKILL_CAP).map { skillView($0, skMax) })
    }
}

/// The melee-rounds heuristic view: the (skill, second) buckets collapsed into a hits-per-round
/// histogram. The log never records double or triple attack, so this counts hits landed in the same
/// second — a cluster proxy exposed as a distribution, never a multi-attack certainty.
private func roundsView(_ s: SourceStat) -> RoundsView? {
    let hist = finalizeRounds(s.rounds)
    let totalRounds = hist.reduce(0, +)
    if totalRounds == 0 { return nil }
    var totalHits: Int64 = 0
    for (i, n) in hist.enumerated() { totalHits += n * Int64(i + 1) }
    return RoundsView(totalRounds: totalRounds,
                      avgHitsPerRound: Double(totalHits) / Double(totalRounds),
                      maxHitsInRound: Int64(hist.count),
                      multiHitRounds: hist.dropFirst().reduce(0, +),
                      histogram: hist)
}

/// Title-case a verb for display (`backstab` → `Backstab`).
private func titleVerb(_ verb: String) -> String {
    guard let f = verb.first else { return "" }
    return String(f).uppercased() + String(verb.dropFirst())
}

/// The row label for a verb lane. A special-attack lane the log named wins ("Flying Kick"); a weapon
/// verb falls back to the verb itself, since the parser answers "Melee" for all of them.
private func roundLaneLabel(_ verb: String, _ skill: String) -> String {
    (skill.isEmpty || skill == GENERIC_LANE) ? titleVerb(verb) : skill
}

private func tallyOf(_ mods: [ModifierTallyView], _ name: String) -> Int64 {
    mods.first { $0.name.lowercased() == name }?.count ?? 0
}

/// Build one source's Rounds payload, or `nil` when it has no rounds and no annotations, so a
/// spell-only source shows no panel instead of a row of zeroes.
///
/// `taken` is the segment-level incoming annotation count, resolved by the caller because it is not a
/// property of this source's rows: a `(Riposte)` counter aimed at you is booked on the mob that swung
/// it.
private func roundStatsView(_ s: SourceStat, _ taken: (Int64, Int64)) -> SourceRoundsView? {
    // Ranked by count desc then name, so the order is stable across snapshots.
    let modifiers = Rust.stableSorted(s.mods.values.map {
        ModifierTallyView(name: $0.name, count: $0.count, avoided: $0.avoided)
    }) { a, b in
        if a.count != b.count { return a.count > b.count }
        return Collate.less(a.name, b.name)
    }
    let tallies = s.roundAcc.snapshot()
    if tallies.isEmpty && modifiers.isEmpty { return nil }
    let lanes = Rust.stableSorted(tallies.map { t in
        RoundLaneView(verb: t.verb, label: roundLaneLabel(t.verb, t.skill), rounds: t.rounds,
                      buckets: t.buckets, multiRounds: t.multiRounds,
                      multiPct: t.rounds > 0 ? (Double(t.multiRounds) / Double(t.rounds)) * 100.0 : 0.0,
                      fannedRounds: t.fannedRounds, confidence: roundConfidence(t.verb))
    }) { a, b in
        if a.rounds != b.rounds { return a.rounds > b.rounds }
        return Collate.less(a.label, b.label)
    }
    let primaryRounds = lanes.map(\.rounds).reduce(0, +)
    let flurries = tallyOf(modifiers, "flurry")
    // The riposte counter-swing comes off the accumulator, not `modifiers`, because the view shape is
    // counts-only on the wire. The key is the log's own spelling; the lowercase lookup above is a
    // display convenience, not the storage key.
    let rip = s.mods["Riposte"]
    let riposteLanded = rip.map { $0.count - $0.avoided } ?? 0
    let riposteDamage = rip?.total ?? 0
    return SourceRoundsView(
        lanes: lanes,
        primaryRounds: primaryRounds,
        excluded: ExcludedView(frenzy: s.roundAcc.excluded[0], riposte: s.roundAcc.excluded[1],
                               flurry: s.roundAcc.excluded[2], rampage: s.roundAcc.excluded[3]),
        modifiers: modifiers,
        ripostesGiven: tallyOf(modifiers, "riposte"),
        riposteLanded: riposteLanded,
        riposteDamage: riposteDamage,
        ripostesTaken: taken.0,
        rampagesTaken: taken.1,
        flurries: flurries,
        flurryPct: primaryRounds > 0 ? (Double(flurries) / Double(primaryRounds)) * 100.0 : 0.0)
}

/// The segment's incoming annotation totals — what was done to you. Summed over every incoming row
/// because the engine books an annotation on the source that swung it. Incoming means the defender is
/// you by construction of `classify`, so this needs no further gating.
private func takenAnnotations(_ inc: JSMap<SourceStat>) -> (Int64, Int64) {
    var riposte: Int64 = 0
    var rampage: Int64 = 0
    for s in inc.values {
        riposte += s.mods["Riposte"]?.count ?? 0
        rampage += s.mods["Rampage"]?.count ?? 0
    }
    return (riposte, rampage)
}

/// Serialize a frozen source map into the snapshot's source views.
///
/// `lands` is grafted onto the `you` row only — an incoming view has no proc ledger behind it, and a
/// mob's slow landing on you is not a lane of yours. `taken` likewise reaches only the `you` row.
private func sourceViews(_ map: JSMap<SourceStat>, _ durationSec: Double,
                         _ lands: JSMap<EffectLanding>?, _ taken: (Int64, Int64)?) -> [SourceView] {
    let graft: JSMap<EffectLanding>? = (lands?.isEmpty ?? true) ? nil : lands
    let rowMax = Double(Swift.max(map.values.map(\.total).max() ?? 0, 1))
    let out: [SourceView] = map.pairs.map { (id, s) in
        let rows: SourceRows = (graft != nil && id == "you") ? withLandings(s, graft!) : project(s)
        let skMax = maxTotal(rows.bySkill)
        let swings = s.hits + s.misses
        // Resist rate is over cast attempts of detrimental spells: landed spell/dot hits plus
        // resists. Melee, slay and damage-shield hits cannot be resisted.
        let spellHits = (rows.byCategory["spell"]?.hits ?? 0) + (rows.byCategory["dot"]?.hits ?? 0)
        let casts = spellHits + s.resists
        return SourceView(
            id: id,
            name: s.name,
            kind: s.kind.asStr,
            total: s.total,
            dps: Double(s.total) / durationSec,
            pct: (Double(s.total) / rowMax) * 100.0,
            hits: s.hits,
            crits: s.crits,
            critPct: s.hits > 0 ? (Double(s.crits) / Double(s.hits)) * 100.0 : 0.0,
            ambiguousHits: s.ambiguousHits,
            ambiguousTotal: s.ambiguousTotal,
            misses: s.misses,
            hitPct: swings > 0 ? (Double(s.hits) / Double(swings)) * 100.0 : 100.0,
            missBreakdown: MissBreakdown(s.miss),
            resists: s.resists,
            resistPct: casts > 0 ? (Double(s.resists) / Double(casts)) * 100.0 : 0.0,
            skills: rankSkills(rows.bySkill).prefix(SKILL_CAP).map { skillView($0, skMax) },
            categories: categoryViews(rows.byCategory),
            rounds: roundsView(s),
            roundStats: roundStatsView(s, id == "you" ? (taken ?? (0, 0)) : (0, 0)))
    }
    // Total desc, and stable, so two rows with the same total keep the order the aggregate recorded
    // them in.
    return Rust.stableSorted(out) { $0.total > $1.total }
}

/// The two categories a weapon swing lands in (a Slay Undead proc rides an ordinary swing).
private let SWING_CATEGORIES = ["melee", "slay"]

/// Landed weapon-swing hits in one row — melee + slay, never the spell/dot/ds lanes.
private func swingHits(_ s: SourceStat) -> Int64 {
    SWING_CATEGORIES.map { s.byCategory[$0]?.hits ?? 0 }.reduce(0, +)
}

/// Landed weapon-swing damage in one row — the denominator riposte damage is a share of.
private func swingDamage(_ s: SourceStat) -> Int64 {
    SWING_CATEGORIES.map { s.byCategory[$0]?.total ?? 0 }.reduce(0, +)
}

/// Build the segment's defensive view. Every figure is a re-reading of counters ingest already folded
/// — the miss breakdown on the incoming rows, and the `(Riposte)` tally on your own row — so nothing
/// here moves a damage total.
///
/// The denominator is swings at you and only swings: melee + slay hits, the two categories a weapon
/// swing lands in. A mob's nuke, DoT tick or damage shield cannot be blocked, and counting it would
/// deflate every rate in exactly the fights with a caster in them.
///
/// `defended` is the four ACTIVE defences. A mob's own `misses!` and your rune's `absorb` are
/// excluded: neither is a skill of yours, and folding either in would flatter the rate.
private func buildDefenseView(_ inc: JSMap<SourceStat>, _ you: SourceStat?, _ taken: Int64) -> DefenseView {
    var avoided = [Int64](repeating: 0, count: 6)
    var hits: Int64 = 0
    for s in inc.values {
        for k in MISS_KEYS { avoided[k] += s.miss[k] }
        hits += swingHits(s)
    }
    let avoidedTotal = avoided.reduce(0, +)
    let swings = hits + avoidedTotal
    let defended = avoided[4] + avoided[2] + avoided[1] + avoided[3]
    func rate(_ n: Int64) -> Double {
        swings > 0 ? (Double(n) / Double(swings)) * 100.0 : 0.0
    }
    // Both halves of your riposte. `events` comes from the incoming avoidance breakdown; the rest
    // comes from the `(Riposte)` annotation on your own swings, a different fact — Double Riposte
    // fires more counters than events — so the two are reported side by side, never reconciled.
    let t = you?.mods["Riposte"]
    let rSwings = t?.count ?? 0
    let rAvoided = t?.avoided ?? 0
    let damage = t?.total ?? 0
    let base = you.map(swingDamage) ?? 0
    return DefenseView(
        swings: swings,
        hits: hits,
        avoided: MissBreakdown(avoided),
        avoidedTotal: avoidedTotal,
        avoidedPct: rate(avoidedTotal),
        defended: defended,
        defendedPct: rate(defended),
        rates: RatesView(miss: rate(avoided[0]), dodge: rate(avoided[1]), parry: rate(avoided[2]),
                         riposte: rate(avoided[3]), block: rate(avoided[4]), absorb: rate(avoided[5])),
        riposte: RiposteView(events: avoided[3], swings: rSwings, hits: rSwings - rAvoided,
                             damage: damage,
                             pctOfSwingDamage: base > 0 ? (Double(damage) / Double(base)) * 100.0 : 0.0,
                             taken: taken))
}

/// Everything a segment view needs about the segment it describes. Bundled because a fight, the live
/// zone aggregate and a frozen zone session differ only in these fields.
private struct ViewSpec {
    var id: String
    var kind: String
    var name: String
    var zone: String?
    var agg: Agg
    var durationSec: Double
    var activeSec: Double
    var active: Bool
    var st: EngineState
    /// Segment span in absolute ms (first/last attributed damage). The proc view clips the state
    /// spans to it; a segment that saw no damage carries 0/0 and reports no spans.
    var startTs: Int64
    var endTs: Int64
    /// Present only for a fight.
    var enc: Encounter?
}

private func buildView(_ spec: ViewSpec) -> SegmentView {
    let agg = spec.agg
    let durationSec = spec.durationSec
    // The effect-landing graft goes to the outgoing view only — a mob slowing you is not a lane of
    // yours. Riposte/rampage taken are booked on the mob that swung the annotated counter and read
    // here from the other end, which is only possible where both maps are in scope.
    let taken = takenAnnotations(agg.inc)
    let lands = effectLandings(agg)
    let entities = sourceViews(agg.out, durationSec, lands, taken)
    let incoming = sourceViews(agg.inc, durationSec, nil, nil)
    let outTotal = entities.map(\.total).reduce(0, +)
    let inTotal = incoming.map(\.total).reduce(0, +)
    let incomingHealers = Rust.stableSorted(agg.incHeal.values.map {
        HealerView(name: $0.name, total: $0.amount, count: $0.count)
    }) { $0.total > $1.total }
    return SegmentView(
        id: spec.id,
        kind: spec.kind,
        name: spec.name,
        zone: spec.zone,
        durationSec: durationSec,
        active: spec.active,
        activeSec: spec.activeSec,
        outTotal: outTotal,
        outDps: Double(outTotal) / durationSec,
        activeDps: Double(outTotal) / Swift.max(1.0, spec.activeSec),
        entities: entities,
        inTotal: inTotal,
        inDps: Double(inTotal) / durationSec,
        incoming: incoming,
        // Built from the same frozen aggregate as the bars above it, so a finalized zone session,
        // which keeps no event ring at all, reports defence exactly.
        defense: buildDefenseView(agg.inc, agg.out["you"], taken.0),
        enemyHealTotal: Agg.sumHeal(agg.enemyHeal),
        incomingHealTotal: incomingHealers.map(\.total).reduce(0, +),
        incomingHealers: incomingHealers,
        healing: buildHealingView(agg.heal, durationSec),
        procs: buildProcsView(ProcsViewSpec(st: spec.st, agg: agg, id: spec.id, kind: spec.kind,
                                            durationSec: durationSec, activeSec: spec.activeSec,
                                            startTs: spec.startTs, endTs: spec.endTs, enc: spec.enc)))
}

/// The one word a zone session is called by, decided from the record so the picker, the overlay
/// header and the panel crumb cannot disagree. A stay the world ended is that zone's `overall`; a
/// stay the user ended with the "New session" mark is its `session`.
private func zoneSessionWord(_ closedBy: ZoneSessionClose) -> String {
    switch closedBy {
    case .mark: return "session"
    case .zone: return "overall"
    }
}

/// Build the selected segment's view, or `nil` when the id resolves to nothing at all — which is the
/// honest answer for a session with no fights in it.
public func buildSelected(_ st: EngineState, _ id: String, _ now: Int64) -> SegmentView? {
    if id == "zone" {
        let zDur = zoneDurationSec(st)
        return buildView(ViewSpec(
            id: "zone", kind: "zone",
            name: "\(st.zone ?? "Session") - overall",
            zone: st.zone, agg: st.zoneAgg, durationSec: zDur,
            activeSec: Swift.min(zDur, zoneActiveSec(st)), active: false, st: st,
            startTs: st.zoneStartTs, endTs: st.zoneLastTs, enc: nil))
    }
    // A finalized zone session: rebuild its full breakdown from the frozen aggregate.
    if let zs = st.zoneHistory.first(where: { $0.id == id }) {
        let zDur = Swift.max(1.0, Double(zs.finalizedMs) / 1000.0)
        return buildView(ViewSpec(
            id: zs.id, kind: "zone", name: "\(zs.zone) - \(zoneSessionWord(zs.closedBy))",
            zone: zs.zone, agg: zs.agg, durationSec: zDur,
            activeSec: Swift.min(zDur, Double(zs.activeMs) / 1000.0), active: false, st: st,
            startTs: zs.startTs, endTs: zs.lastTs, enc: nil))
    }
    let isCurrent = st.current?.id == id
    let found: Encounter? = isCurrent ? st.current : st.history.first { $0.id == id }
    guard let e = found else { return nil }
    let dur = Swift.max(1.0, Double(e.lastTs - e.startTs) / 1000.0)
    return buildView(ViewSpec(
        id: e.id, kind: "fight", name: encounterName(e, isCurrent), zone: e.zone, agg: e.agg,
        durationSec: dur, activeSec: Swift.min(dur, Double(e.activeMs) / 1000.0),
        active: isCurrent && now - e.lastTs < ACTIVE_MS, st: st,
        startTs: e.startTs, endTs: e.lastTs, enc: e))
}
