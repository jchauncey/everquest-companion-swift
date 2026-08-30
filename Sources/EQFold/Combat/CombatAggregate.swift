// Pure accumulation over a segment (encounter or zone session): per-source / per-category /
// per-skill damage stats, accuracy and resist counters, the target ledger, healing annotations
// (`fold/src/combat/aggregate.rs`). Routing decides which aggregate a line belongs to; this file
// only folds.
//
// The ledgers beside the damage half (`heal`, `procs`, `windows`, and `SourceStat`'s `mods` /
// `rounds` / `roundAcc`) fold on ingest because the encounter event ring is capped, truncated at
// finalize and absent for zone sessions. None of them moves a damage total — every field is a count
// or an index over damage already booked.
//
// `out` / `inc` / `targets` publish their iteration order, so they are `JSMap`s, never dictionaries.
import Foundation
import EQCompanionCore

/// The engine's internal damage record. Sourced from the canonical `damage` event, but with a
/// non-null attacker — caster-less other-player DoTs carry `attacker: null` and are dropped by the
/// caller before this is built.
public struct DamageEvent {
    public var ts: Int64
    public var attacker: String
    public var target: String
    public var amount: Int64
    public var dtype: String
    public var dclass: String?
    public var skill: String
    public var crit: Bool
    /// Taxonomy category. Derived from dtype+modifiers when the event omits it, so aggregation
    /// always has an axis.
    public var category: String
    /// Parsed paren-modifier tokens, e.g. `["Riposte", "Critical"]`.
    public var modifiers: [String]
    /// The un-conjugated melee verb (`strike`, `kick`), on melee/slay lines only. The join key
    /// between a swing and the active special attack.
    public var verb: String?

    public init(ts: Int64, attacker: String, target: String, amount: Int64, dtype: String,
                dclass: String?, skill: String, crit: Bool, category: String,
                modifiers: [String], verb: String?) {
        self.ts = ts; self.attacker = attacker; self.target = target; self.amount = amount
        self.dtype = dtype; self.dclass = dclass; self.skill = skill; self.crit = crit
        self.category = category; self.modifiers = modifiers; self.verb = verb
    }
}

/// The identity of a meter row. Bundled because the outgoing routing paths resolve all three once
/// and hand the same triple to every `Agg` method.
public struct SourceRef {
    public var id: String
    public var name: String
    public var kind: SourceKind
    public init(id: String, name: String, kind: SourceKind) {
        self.id = id; self.name = name; self.kind = kind
    }
}

/// `shared/combat.ts SourceKind`. An enum because exactly one transition between two kinds is legal
/// (`other` → `member`, see `reid`); every other kind is constant for a given row id.
public enum SourceKind: String, Sendable {
    case you, pet, member, other
    case allyPet
    case enemy

    public var asStr: String { rawValue }
}

/// `shared/logEvents.ts MissType` — the six avoided-swing outcomes, in the order the breakdown is
/// serialized in.
public enum MissType: Int, Sendable, CaseIterable {
    case miss = 0, dodge, parry, riposte, block, absorb

    public static func parse(_ s: String) -> MissType? {
        switch s {
        case "miss": return .miss
        case "dodge": return .dodge
        case "parry": return .parry
        case "riposte": return .riposte
        case "block": return .block
        case "absorb": return .absorb
        default: return nil
        }
    }

    var slot: Int { rawValue }

    /// The log's own word for the outcome — a timeline instant's `detail`.
    public var asStr: String {
        switch self {
        case .miss: return "miss"
        case .dodge: return "dodge"
        case .parry: return "parry"
        case .riposte: return "riposte"
        case .block: return "block"
        case .absorb: return "absorb"
        }
    }
}

/// One avoided swing as the aggregate folds it. `verb` / `laneSkill` / `modifiers` / `target` are
/// the additive, amount-free inputs to the round grouper and the modifier tallies.
public struct MissFold {
    public var mtype: MissType
    /// The accuracy lane the miss counts against — `Melee` for every avoided swing.
    public var skill: String
    /// Un-conjugated verb off the miss line, when it named one.
    public var verb: String?
    /// The round lane's display name for that verb (special-attack renamed) — never the aggregation
    /// lane above, which stays `Melee`.
    public var laneSkill: String?
    public var modifiers: [String]
    public var target: String
    public var ts: Int64

    public init(mtype: MissType, skill: String, verb: String?, laneSkill: String?,
                modifiers: [String], target: String, ts: Int64) {
        self.mtype = mtype; self.skill = skill; self.verb = verb; self.laneSkill = laneSkill
        self.modifiers = modifiers; self.target = target; self.ts = ts
    }
}

public final class SkillStat {
    public var name: String
    public var total: Int64 = 0
    public var hits: Int64 = 0
    public var crits: Int64 = 0
    public var max: Int64 = 0
    /// Smallest landed amount on this lane; 0 = "no landed hit yet" (see `accrueMin`).
    public var min: Int64 = 0
    public var misses: Int64 = 0
    public var resists: Int64 = 0
    public init(name: String) { self.name = name }
}

func newSkill(_ name: String) -> SkillStat { SkillStat(name: name) }

/// Fold a landed amount into a per-skill running minimum. 0 is the "nothing landed yet" sentinel:
/// `route()` drops `amount <= 0`, so every value reaching here is > 0 and a lane that only missed or
/// resisted keeps min 0.
func accrueMin(_ prev: Int64, _ amount: Int64) -> Int64 {
    prev == 0 ? amount : Swift.min(prev, amount)
}

/// Per-category rollup within a source (drill-down level 2). Holds the category total plus its own
/// per-skill breakdown (level 3).
public final class CategoryStat {
    public var category: String
    public var total: Int64 = 0
    public var hits: Int64 = 0
    public var crits: Int64 = 0
    public var max: Int64 = 0
    public var resists: Int64 = 0
    public var bySkill = JSMap<SkillStat>()
    public init(category: String) { self.category = category }
}

/// One base modifier's tally on a source. Counts, plus the landed line's own amount re-read into
/// `total`.
///
/// The log prints 14 compound modifier forms which decompose over 8 bases. The parser decomposes;
/// this tallies the components. `total` is an index, not a second accumulation.
public final class ModifierTally {
    public var name: String
    /// Annotated swings/casts — landed AND avoided.
    public var count: Int64 = 0
    /// Of those, how many carried no amount (an avoided swing).
    public var avoided: Int64 = 0
    public var total: Int64 = 0
    public init(name: String) { self.name = name }
}

/// The legacy melee-rounds heuristic: `skillLower` → (`floor(ts/1000)` → hits in that bucket).
///
/// The buckets are the only state; the hits-per-round histogram is derived at view time and not
/// cached back. A dictionary and not a `JSMap` because `finalizeRounds` counts the values and never
/// publishes an order.
public final class RoundsAccum {
    public var bucket: [String: [Int64: Int64]] = [:]
    public init() {}
}

func accrueRound(_ r: RoundsAccum, _ skill: String, _ ts: Int64) {
    let key = skill.lowercased()
    // `i64::div_euclid(1_000)` — floor division, so a negative ts buckets down rather than toward 0.
    let q = ts / 1000, rem = ts % 1000
    let sec = rem < 0 ? q - 1 : q
    r.bucket[key, default: [:]][sec, default: 0] += 1
}

/// Collapse the in-progress buckets into the hits-per-round histogram. Read-only, so calling it at
/// snapshot or finalize is safe and repeatable.
public func finalizeRounds(_ r: RoundsAccum) -> [Int64] {
    var hist: [Int64] = []
    for seconds in r.bucket.values {
        for hits in seconds.values {
            let idx = Int(Swift.max(0, hits - 1))
            if hist.count <= idx { hist.append(contentsOf: repeatElement(0, count: idx + 1 - hist.count)) }
            hist[idx] += 1
        }
    }
    return hist
}

public final class SourceStat {
    public var name: String
    public var kind: SourceKind
    public var total: Int64 = 0
    public var hits: Int64 = 0
    public var crits: Int64 = 0
    public var ambiguousHits: Int64 = 0
    public var ambiguousTotal: Int64 = 0
    /// Avoided swings by this source, all outcomes.
    public var misses: Int64 = 0
    /// The six-slot breakdown, indexed by `MissType`.
    public var miss: [Int64] = [0, 0, 0, 0, 0, 0]
    public var resists: Int64 = 0
    public var bySkill = JSMap<SkillStat>()
    public var byCategory = JSMap<CategoryStat>()
    /// The legacy melee-rounds heuristic.
    public var rounds = RoundsAccum()
    /// Base-modifier tallies — see `ModifierTally`.
    public var mods = JSMap<ModifierTally>()
    /// Per (verb, swings-per-round) counters, built by the pure grouper in `CombatRounds`.
    public var roundAcc = RoundAccum()

    public init(name: String, kind: SourceKind) { self.name = name; self.kind = kind }
}

public func newSource(_ name: String, _ kind: SourceKind) -> SourceStat {
    SourceStat(name: name, kind: kind)
}

/// A damage total booked against a named entity — the `targets`, `enemyHeal` and `incHeal` shape.
public final class NamedTotal {
    public var name: String
    public var amount: Int64
    /// Only `incHeal` counts; the other two carry 0 and never publish it.
    public var count: Int64
    public init(name: String, amount: Int64, count: Int64) {
        self.name = name; self.amount = amount; self.count = count
    }
}

/// A rogue-poison Strike lane. Keyed by the display name, ambiguity included. The count is exact,
/// the name may not be.
public final class StrikeLane {
    public var name: String
    public var count: Int64
    public var ambiguous: Bool
    public init(name: String, count: Int64, ambiguous: Bool) {
        self.name = name; self.count = count; self.ambiguous = ambiguous
    }
}

/// A poison-typed damage lane. The game states the damage type on every typed spell line, so this is
/// printed fact rather than a name-matched guess. An index over damage already counted.
public final class PoisonLane {
    public var name: String
    public var count: Int64
    public var total: Int64
    public init(name: String, count: Int64, total: Int64) {
        self.name = name; self.count = count; self.total = total
    }
}

/// A dispel landing lane. Every one is ambiguous by construction.
public final class DispelLane {
    public var name: String
    public var count: Int64
    public init(name: String, count: Int64) { self.name = name; self.count = count }
}

/// One coat applied inside a segment, in order.
public struct CoatMark {
    public var poison: String
    public var ts: Int64
    public init(poison: String, ts: Int64) { self.poison = poison; self.ts = ts }
}

/// The per-segment proc accumulator. Pure counters, incremented on ingest from lines the game
/// printed, so a downsampled or truncated timeline can never move a number here.
public final class ProcAccum {
    public var strikes = JSMap<StrikeLane>()
    /// Weakening-Strike landings — broken out because it is the one we time.
    public var slowLands: Int64 = 0
    /// Absolute ts of the first slow landing in this segment (0 = none).
    public var firstSlowTs: Int64 = 0
    public var poisonDamage = JSMap<PoisonLane>()
    public var dispels = JSMap<DispelLane>()
    /// Your coats applied inside this segment, in order.
    public var coats: [CoatMark] = []
    public var stanceSwitches: Int64 = 0
    public var invocationSwitches: Int64 = 0
    /// Your logged swing attempts here: melee + slay hits, plus your misses. The mechanical
    /// denominator for a chance-on-hit proc rate.
    public var swings: Int64 = 0
    /// `<kind>:<key>` → how many of those swings were logged while that state was open.
    public var swingsByState = JSMap<Int64>()
    /// Ms of the meter's own active time that elapsed while a state was open — the PPM denominator
    /// for a lane whose source window is known.
    public var activeMsByState = JSMap<Int64>()
    /// Cast-less spell lanes, keyed by `spellCanonKey`. Their damage is already inside this segment's
    /// outgoing total — an index, never a second accumulation.
    public var spellProcs = JSMap<SpellProcLane>()

    public init() {}

    /// Count one of your logged swing attempts against the states open when you made it. The total
    /// and the per-state split move together so no call site can update one without the other.
    public func addSwing(_ active: Set<String>) {
        swings += 1
        for key in active.sorted() { bumpState(&swingsByState, key, 1) }
    }

    /// Charge one hit's active-time delta to every state open for it. Called on every folded damage
    /// line, incoming included, because that is what the meter's own `activeMs` counts.
    public func addActiveMs(_ ms: Int64, _ active: Set<String>) {
        if ms <= 0 { return }
        for key in active.sorted() { bumpState(&activeMsByState, key, ms) }
    }

    public func addSpellProc(_ f: SpellProcFold) {
        EQFold.addSpellProc(&spellProcs, f)
    }

    public func addStrike(_ name: String, _ ambiguous: Bool, _ ts: Int64, _ isSlow: Bool) {
        if !strikes.containsKey(name) {
            strikes.insert(name, StrikeLane(name: name, count: 0, ambiguous: ambiguous))
        }
        strikes[name]!.count += 1
        if isSlow {
            slowLands += 1
            if firstSlowTs == 0 { firstSlowTs = ts }
        }
    }

    public func addPoisonDamage(_ skill: String, _ amount: Int64) {
        if !poisonDamage.containsKey(skill) {
            poisonDamage.insert(skill, PoisonLane(name: skill, count: 0, total: 0))
        }
        let s = poisonDamage[skill]!
        s.count += 1
        s.total += amount
    }

    public func addDispel(_ label: String) {
        if !dispels.containsKey(label) {
            dispels.insert(label, DispelLane(name: label, count: 0))
        }
        dispels[label]!.count += 1
    }
}

func bumpState(_ map: inout JSMap<Int64>, _ key: String, _ by: Int64) {
    let n = map[key] ?? 0
    map.insert(key, n + by)
}

/// The per-segment aggregate. Keyed by instance id (or `you` / `pet:<instanceId>` / `member:<key>` /
/// `allypet:<charmer>:<pet>`); `name` holds the display spelling, refreshed on every arrival because
/// the log's latest spelling wins.
public final class Agg {
    public var out = JSMap<SourceStat>()
    public var inc = JSMap<SourceStat>()
    public var targets = JSMap<NamedTotal>()
    /// Healing received by hostile instances engaged here (instanceId → total).
    public var enemyHeal = JSMap<NamedTotal>()
    /// Healing received by You / your pets: healerKey → { name, total, count }.
    public var incHeal = JSMap<NamedTotal>()
    /// The meter-grade healing + absorption ledger. On the same aggregate as the damage bars so the
    /// healing overlays inherit fight / zone-session selection for free.
    public var heal = HealAccum()
    /// Proc ledger — Strikes, poison-typed lanes, non-damage spell landings on engaged mobs, and the
    /// stance/coat bookkeeping. On the `Agg` for the same reason the healing ledger is.
    public var procs = ProcAccum()
    /// The minute-window ledger the Tier-B counterfactual is computed from.
    public var windows = WindowAccum()

    public init() {}

    /// Sum of a source map's totals — the DPS numerator for a segment.
    public static func sum(_ map: JSMap<SourceStat>) -> Int64 {
        map.values.reduce(Int64(0)) { $0 &+ $1.total }
    }

    public static func sumHeal(_ map: JSMap<NamedTotal>) -> Int64 {
        map.values.reduce(Int64(0)) { $0 &+ $1.amount }
    }

    /// True when this aggregate recorded nothing at all — the drop rule `finalizeCurrent` and
    /// `finalizeZoneSession` are gated on.
    ///
    /// Map emptiness, not a total: a miss creates a source row with no damage, and that encounter is
    /// kept because the hit-rate is real even when the damage is zero.
    public var isEmpty: Bool { out.isEmpty && inc.isEmpty }

    /// Re-state a row's identity from the ref that just arrived: latest display name wins, and the
    /// kind may make exactly one transition, `other` → `member`. One-way on purpose.
    static func reid(_ s: SourceStat, _ r: SourceRef) {
        if s.name != r.name { s.name = r.name }
        if s.kind == .other && r.kind == .member { s.kind = .member }
    }

    func outRow(_ r: SourceRef) -> SourceStat {
        if !out.containsKey(r.id) { out.insert(r.id, newSource(r.name, r.kind)) }
        let s = out[r.id]!
        Agg.reid(s, r)
        return s
    }

    func incRow(_ id: String, _ name: String) -> SourceStat {
        if !inc.containsKey(id) { inc.insert(id, newSource(name, .enemy)) }
        return inc[id]!
    }

    /// Drop a recorded row. The one caller is `retractOther`: a name a stronger model has just
    /// claimed as a pet must not keep a second bar beside the pet's own.
    @discardableResult
    public func dropOut(_ id: String) -> Bool { out.remove(id) }

    public func addOut(_ r: SourceRef, _ ev: DamageEvent, _ ambiguous: Bool) {
        addToSource(outRow(r), ev, ambiguous)
    }

    public func addInc(_ id: String, _ name: String, _ ev: DamageEvent) {
        addToSource(incRow(id, name), ev, false)
    }

    public func addOutMiss(_ r: SourceRef, _ m: MissFold) { addMissToSource(outRow(r), m) }

    public func addIncMiss(_ id: String, _ name: String, _ m: MissFold) {
        addMissToSource(incRow(id, name), m)
    }

    public func addOutResist(_ r: SourceRef, _ spell: String, _ category: String) {
        addResistToSource(outRow(r), spell, category)
    }

    public func addIncResist(_ id: String, _ name: String, _ spell: String, _ category: String) {
        addResistToSource(incRow(id, name), spell, category)
    }

    public func addEnemyHeal(_ id: String, _ name: String, _ amount: Int64) {
        bump(&enemyHeal, id, name, amount, false)
    }

    public func addIncHeal(_ healerKey: String, _ name: String, _ amount: Int64) {
        bump(&incHeal, healerKey, name, amount, true)
    }

    public func bumpTarget(_ id: String, _ name: String, _ amount: Int64) {
        bump(&targets, id, name, amount, false)
    }
}

func bump(_ map: inout JSMap<NamedTotal>, _ id: String, _ name: String, _ amount: Int64, _ counted: Bool) {
    if !map.containsKey(id) { map.insert(id, NamedTotal(name: name, amount: 0, count: 0)) }
    let t = map[id]!
    t.amount += amount
    if counted { t.count += 1 }
}

func addToSource(_ src: SourceStat, _ ev: DamageEvent, _ ambiguous: Bool) {
    src.total += ev.amount
    src.hits += 1
    if ev.crit { src.crits += 1 }
    if ambiguous {
        src.ambiguousHits += 1
        src.ambiguousTotal += ev.amount
    }
    do {
        let s = lane(&src.bySkill, ev.skill)
        s.total += ev.amount
        s.hits += 1
        if ev.crit { s.crits += 1 }
        s.max = Swift.max(s.max, ev.amount)
        s.min = accrueMin(s.min, ev.amount)
    }
    addToCategory(src, ev)
    addSwingCounters(src, ev)
}

/// The count-only counters a landed swing feeds: the melee-rounds heuristic, the base modifier
/// tallies, and the attack-round grouper. None of them touches `src.total`, a category total or a
/// lane total.
func addSwingCounters(_ src: SourceStat, _ ev: DamageEvent) {
    let isSwing = ev.category == "melee" || ev.category == "slay"
    // Only melee/slay hits cluster into rounds; spells and DoTs are single applications.
    if isSwing { accrueRound(src.rounds, ev.skill, ev.ts) }
    tallyModifiers(src, ev.modifiers, false, ev.amount)
    // A swing is a melee/slay line that named its verb — the round grouper's join key.
    if isSwing, let verb = ev.verb {
        src.roundAcc.add(SwingRecord(ts: ev.ts, verb: verb, skill: ev.skill, target: ev.target,
                                     amount: ev.amount, avoided: false, modifiers: ev.modifiers))
    }
}

/// Fold the decomposed base modifiers of one line into a source's tallies. An avoided swing passes
/// amount 0 and is the only caller that may.
func tallyModifiers(_ src: SourceStat, _ mods: [String], _ avoided: Bool, _ amount: Int64) {
    for name in mods {
        if !src.mods.containsKey(name) { src.mods.insert(name, ModifierTally(name: name)) }
        let t = src.mods[name]!
        t.count += 1
        if avoided { t.avoided += 1 } else { t.total += amount }
    }
}

/// Category rollup: the same skill breakdown, partitioned by taxonomy category so a source can be
/// opened into melee/slay/spell/dot/ds.
func addToCategory(_ src: SourceStat, _ ev: DamageEvent) {
    if !src.byCategory.containsKey(ev.category) {
        src.byCategory.insert(ev.category, CategoryStat(category: ev.category))
    }
    let c = src.byCategory[ev.category]!
    c.total += ev.amount
    c.hits += 1
    if ev.crit { c.crits += 1 }
    c.max = Swift.max(c.max, ev.amount)
    let cs = lane(&c.bySkill, ev.skill)
    cs.total += ev.amount
    cs.hits += 1
    if ev.crit { cs.crits += 1 }
    cs.max = Swift.max(cs.max, ev.amount)
    cs.min = accrueMin(cs.min, ev.amount)
}

/// Fold a miss (avoided swing) into a source's accuracy stats. The lane is created lazily, which is
/// what makes an encounter of nothing but whiffs a real encounter rather than an empty one.
func addMissToSource(_ src: SourceStat, _ m: MissFold) {
    src.misses += 1
    src.miss[m.mtype.slot] += 1
    lane(&src.bySkill, m.skill).misses += 1
    // A miss line can carry an annotation (`… but miss! (Flurry)`), and roughly half the log's
    // flurry annotations are on miss lines, so counting only landed ones would halve the stat.
    tallyModifiers(src, m.modifiers, true, 0)
    if let verb = m.verb {
        src.roundAcc.add(SwingRecord(ts: m.ts, verb: verb, skill: m.laneSkill ?? m.skill,
                                     target: m.target, amount: 0, avoided: true,
                                     modifiers: m.modifiers))
    }
}

/// Fold a spell resist into a source's stats — the caster-side analogue of a miss. It carries no
/// damage, so only the resist counters move. The lane is created lazily, so a spell that was always
/// resisted still shows a row (0 hits / N resists).
func addResistToSource(_ src: SourceStat, _ spell: String, _ category: String) {
    src.resists += 1
    lane(&src.bySkill, spell).resists += 1
    if !src.byCategory.containsKey(category) {
        src.byCategory.insert(category, CategoryStat(category: category))
    }
    let c = src.byCategory[category]!
    c.resists += 1
    lane(&c.bySkill, spell).resists += 1
}

/// The six avoided-swing slots, in serialization order. A list so merge and rate loops iterate
/// instead of naming five fields and missing the sixth.
public let MISS_KEYS: [Int] = [0, 1, 2, 3, 4, 5]

func lane(_ map: inout JSMap<SkillStat>, _ name: String) -> SkillStat {
    if let s = map[name] { return s }
    let s = newSkill(name)
    map.insert(name, s)
    return s
}
