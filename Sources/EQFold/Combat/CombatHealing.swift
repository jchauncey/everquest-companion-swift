// Healing + absorption: the meter-grade ledger (per healer, per spell, with crit / min / max /
// overheal) and the serializable view over it (fold/src/combat/healing.rs).
//
// It lives on the same `Agg` the damage bars use, so a healing meter inherits fight / zone-session
// selection, the finalized-zone-session freeze and the encounter history for free.
//
// The honesty rules (world-model law 6 — never say what the log cannot say):
//
//   * Overheal comes from the `for N (M) hit points` form only. EQ prints the parens exactly when
//     raw > effective, so a plain line contributes 0 and the sum is a FLOOR.
//   * The two `magical skin absorbs` families carry no amount. Counted, never valued.
//   * A heal the log announces but never values (the monk's Mend) gets an `unstated` lane carrying a
//     count and a total of 0. That 0 is the absence of a measurement, so it enters no sum.
//   * A rune's amount is absorption GRANTED, not damage consumed. It ranks in the healing total but
//     rides an `absorbed` lane for its whole life, and a rune has no overheal — none is invented.
//   * Rune sources are not split: `You gain a rune for N points of absorption.` names no spell and
//     no caster, so there is ONE absorption lane.
//
// `min` is ABSENT, never zero — a lane with no landed line has no `min` at all. Note the asymmetry
// with the damage model's per-lane minimum: a 0-effective (fully overhealed) tick still LANDED a
// line, so it participates here, unlike a whiff.
import Foundation
import EQCompanionCore

/// Spell-less heal lines get one shared lane.
public let UNSPECIFIED_SPELL = "Unspecified"
/// Display name of the absorption lane.
public let RUNE_LANE = "Rune"
/// Row id of the self row — the row the absorption and unstated lanes attach to.
public let SELF_ROW_ID = "you"
/// Cap on serialized spell lanes per healer. It applies to the HEAL lanes only: absorption and
/// unstated lanes are appended after the cap, so a long tail of small heals cannot squeeze them out.
private let SPELL_CAP = 14

/// One heal line, already attributed by the engine.
public struct HealInput {
    /// Effective (landed) heal.
    public var amount: Int64
    /// Raw/pre-overheal amount, present only on the `(M)` lines.
    public var rawAmount: Int64?
    public var spell: String?
    public var crit: Bool

    public init(amount: Int64 = 0, rawAmount: Int64? = nil, spell: String? = nil, crit: Bool = false) {
        self.amount = amount; self.rawAmount = rawAmount; self.spell = spell; self.crit = crit
    }
}

public enum HealSourceKind: Sendable {
    case you, pet, other, enemy

    var asStr: String {
        switch self {
        case .you: return "you"
        case .pet: return "pet"
        case .other: return "other"
        case .enemy: return "enemy"
        }
    }
}

private struct HealSpellStat {
    var name: String
    var total: Int64 = 0
    var count: Int64 = 0
    var crits: Int64 = 0
    var max: Int64 = 0
    var min: Int64?
    var overheal: Int64 = 0
    var fullOverheal: Int64 = 0
}

private struct HealSourceStat {
    var name: String
    var kind: HealSourceKind
    var total: Int64 = 0
    var count: Int64 = 0
    var crits: Int64 = 0
    var max: Int64 = 0
    var min: Int64?
    var overheal: Int64 = 0
    var fullOverheal: Int64 = 0
    var bySpell = JSMap<HealSpellStat>()
}

/// The absorption counters. Amounts exist for runes only — the rest are counts by construction,
/// which is why only the rune lane can become a ledger row.
private struct MitAccum {
    var runeTotal: Int64 = 0
    var runeCount: Int64 = 0
    var runeMax: Int64 = 0
    var runeMin: Int64?
    var absorbedSwings: Int64 = 0
    var absorbedDamageShields: Int64 = 0
}

/// Track the smallest LANDED heal. A 0-effective (fully overhealed) tick still landed a line, so it
/// participates, unlike the damage model's min, which must never see a miss.
private func accrueMin(_ cur: Int64?, _ amount: Int64) -> Int64 {
    guard let prev = cur else { return amount }
    return Swift.min(prev, amount)
}

private func add(_ m: inout JSMap<HealSourceStat>, _ key: String, _ name: String,
                 _ kind: HealSourceKind, _ h: HealInput) {
    var s = m[key] ?? HealSourceStat(name: name, kind: kind)
    if s.name != name { s.name = name }
    // A healer can later be reclassified (a charmed mob becomes your pet); the latest attribution
    // wins, matching how the damage model relabels a source.
    s.kind = kind
    // EQ omits the parens whenever nothing was wasted, so a plain line's raw == effective.
    let raw = h.rawAmount ?? h.amount
    let over = Swift.max(raw - h.amount, 0)
    s.total += h.amount
    s.count += 1
    if h.crit { s.crits += 1 }
    s.max = Swift.max(s.max, h.amount)
    s.min = accrueMin(s.min, h.amount)
    s.overheal += over
    if h.amount == 0 { s.fullOverheal += 1 }
    // Absent, blank and whitespace-only spell names all fall to the one shared lane; a nullish check
    // would let `''` through as a lane of its own.
    let trimmed = (h.spell ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let spellName = trimmed.isEmpty ? UNSPECIFIED_SPELL : trimmed
    var sp = s.bySpell[spellName] ?? HealSpellStat(name: spellName)
    sp.total += h.amount
    sp.count += 1
    if h.crit { sp.crits += 1 }
    sp.max = Swift.max(sp.max, h.amount)
    sp.min = accrueMin(sp.min, h.amount)
    sp.overheal += over
    if h.amount == 0 { sp.fullOverheal += 1 }
    s.bySpell.insert(spellName, sp)
    m.insert(key, s)
}

/// The healing half of an aggregate. Two independent ledgers mirroring the damage model's
/// out/incoming split: `friendly` is heals that landed on you, your pets or the player by name;
/// `hostile` is heals that landed on an engaged hostile, ranked by healer. Heals between third
/// parties are not collected — the log gives no faction for an arbitrary name.
public struct HealAccum {
    fileprivate var friendly = JSMap<HealSourceStat>()
    fileprivate var hostile = JSMap<HealSourceStat>()
    fileprivate var mit = MitAccum()
    /// Amount-less heals by skill name → how many landed. A map rather than a single Mend counter so
    /// the ledger need not change shape if a second amount-less family appears.
    fileprivate var unstated = JSMap<Int64>()

    public init() {}

    public mutating func addFriendly(_ key: String, _ name: String, _ kind: HealSourceKind, _ h: HealInput) {
        add(&friendly, key, name, kind, h)
    }

    public mutating func addHostile(_ key: String, _ name: String, _ h: HealInput) {
        add(&hostile, key, name, .enemy, h)
    }

    /// One amount-less heal line. A count, and deliberately nothing else.
    public mutating func addUnstated(_ skill: String) {
        unstated.insert(skill, (unstated[skill] ?? 0) + 1)
    }

    public mutating func addRune(_ amount: Int64) {
        mit.runeTotal += amount
        mit.runeCount += 1
        mit.runeMax = Swift.max(mit.runeMax, amount)
        mit.runeMin = mit.runeMin.map { Swift.min($0, amount) } ?? amount
    }

    public mutating func addAbsorbedSwing() { mit.absorbedSwings += 1 }

    public mutating func addAbsorbedDamageShield() { mit.absorbedDamageShields += 1 }
}

// MARK: - Views

public struct HealSpellView {
    public var name: String
    public var total: Int64
    public var pct: Double
    public var count: Int64
    public var crits: Int64
    public var max: Int64
    public var min: Int64?
    public var overheal: Int64
    public var fullOverheal: Int64
    public var classification: String

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name), "total": .int(total), "pct": .double(pct),
            "count": .int(count), "crits": .int(crits), "max": .int(max),
            "overheal": .int(overheal), "fullOverheal": .int(fullOverheal),
            "classification": .string(classification),
        ]
        if let m = min { o["min"] = .int(m) }
        return .object(o)
    }
}

public struct HealSourceView {
    public var id: String
    public var name: String
    public var kind: String
    public var total: Int64
    public var absorbedTotal: Int64
    public var hps: Double
    public var pct: Double
    public var count: Int64
    public var unstatedCount: Int64
    public var crits: Int64
    public var critPct: Double
    public var max: Int64
    public var min: Int64?
    public var overheal: Int64
    public var overhealPct: Double
    public var fullOverheal: Int64
    public var spells: [HealSpellView]

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "kind": .string(kind),
            "total": .int(total), "absorbedTotal": .int(absorbedTotal),
            "hps": .double(hps), "pct": .double(pct), "count": .int(count),
            "unstatedCount": .int(unstatedCount), "crits": .int(crits),
            "critPct": .double(critPct), "max": .int(max), "overheal": .int(overheal),
            "overhealPct": .double(overhealPct), "fullOverheal": .int(fullOverheal),
            "spells": .array(spells.map(\.json)),
        ]
        if let m = min { o["min"] = .int(m) }
        return .object(o)
    }
}

public struct MitigationView {
    public var runeTotal: Int64
    public var runeCount: Int64
    public var runeMax: Int64
    public var runeMin: Int64?
    public var absorbedSwings: Int64
    public var absorbedDamageShields: Int64

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "runeTotal": .int(runeTotal), "runeCount": .int(runeCount),
            "runeMax": .int(runeMax), "absorbedSwings": .int(absorbedSwings),
            "absorbedDamageShields": .int(absorbedDamageShields),
        ]
        if let m = runeMin { o["runeMin"] = .int(m) }
        return .object(o)
    }
}

public struct HealingView {
    public var healers: [HealSourceView]
    public var total: Int64
    public var hps: Double
    public var restoredTotal: Int64
    public var absorbedTotal: Int64
    public var overheal: Int64
    public var enemyHealers: [HealSourceView]
    public var enemyTotal: Int64
    public var mitigation: MitigationView

    public var json: JSONValue {
        [
            "healers": .array(healers.map(\.json)),
            "total": .int(total),
            "hps": .double(hps),
            "restoredTotal": .int(restoredTotal),
            "absorbedTotal": .int(absorbedTotal),
            "overheal": .int(overheal),
            "enemyHealers": .array(enemyHealers.map(\.json)),
            "enemyTotal": .int(enemyTotal),
            "mitigation": mitigation.json,
        ]
    }
}

private func healLanes(_ s: HealSourceStat) -> [HealSpellView] {
    let rows = stableSorted(s.bySpell.values) { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.count != b.count { return a.count > b.count }
        return Collate.less(a.name, b.name)
    }
    return rows.prefix(SPELL_CAP).map { r in
        HealSpellView(name: r.name, total: r.total, pct: 0.0, count: r.count, crits: r.crits,
                      max: r.max, min: r.min, overheal: r.overheal, fullOverheal: r.fullOverheal,
                      classification: "restored")
    }
}

/// The rune grants as one drill lane. No crits and no overheal: the log never says a shield expired
/// unused, so "wasted absorption" would be an invention.
private func runeLane(_ m: MitAccum) -> HealSpellView? {
    if m.runeCount == 0 { return nil }
    return HealSpellView(name: RUNE_LANE, total: m.runeTotal, pct: 0.0, count: m.runeCount,
                         crits: 0, max: m.runeMax, min: m.runeMin, overheal: 0, fullOverheal: 0,
                         classification: "absorbed")
}

/// The amount-less heal lanes. Every field that would be a claim about SIZE stays 0, and `min` is
/// absent rather than zero. `count` is the entire content of the lane, as of the line.
private func unstatedLanes(_ m: JSMap<Int64>) -> [HealSpellView] {
    let rows = stableSorted(m.pairs) { a, b in
        if a.1 != b.1 { return a.1 > b.1 }
        return Collate.less(a.0, b.0)
    }
    return rows.map { (name, count) in
        HealSpellView(name: name, total: 0, pct: 0.0, count: count, crits: 0, max: 0, min: nil,
                      overheal: 0, fullOverheal: 0, classification: "unstated")
    }
}

/// One flat ranked list — heals and absorption together, biggest first, each lane keeping its
/// classification so the two are never confused. Deliberately not grouped into sections.
private func rankLanes(_ lanes: [HealSpellView]) -> [HealSpellView] {
    var l = stableSorted(lanes) { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.count != b.count { return a.count > b.count }
        return Collate.less(a.name, b.name)
    }
    let maxTotal = Double(Swift.max(l.map(\.total).max() ?? 0, 1))
    for i in l.indices { l[i].pct = (Double(l[i].total) / maxTotal) * 100.0 }
    return l
}

/// A ledger row. `pct` / `hps` are placeholders — they are relative to the final row set, so
/// `rankRows` fills them in last.
///
/// `extraLanes` carries the absorption and unstated lanes onto the row they belong to. The row's
/// HEADLINE stats stay about restored healing only (law 5): `total` is the combined ranking figure
/// and `absorbedTotal` says how much of it is absorption.
private func toView(_ key: String, _ s: HealSourceStat, _ extraLanes: [HealSpellView]) -> HealSourceView {
    let absorbedTotal = extraLanes.filter { $0.classification == "absorbed" }.map(\.total).reduce(0, +)
    // Summed off the lanes rather than tracked a second time on the row, so the two cannot disagree.
    let unstatedCount = extraLanes.filter { $0.classification == "unstated" }.map(\.count).reduce(0, +)
    var spells = healLanes(s)
    spells.append(contentsOf: extraLanes)
    return HealSourceView(
        id: key,
        name: s.name,
        kind: s.kind.asStr,
        total: s.total + absorbedTotal,
        absorbedTotal: absorbedTotal,
        hps: 0.0,
        pct: 0.0,
        count: s.count,
        unstatedCount: unstatedCount,
        crits: s.crits,
        critPct: s.count > 0 ? (Double(s.crits) / Double(s.count)) * 100.0 : 0.0,
        max: s.max,
        min: s.min,
        overheal: s.overheal,
        // Relative to restored healing, never to the combined total: absorption in the denominator
        // would deflate a healer's overheal rate.
        overhealPct: s.total + s.overheal > 0
            ? (Double(s.overheal) / Double(s.total + s.overheal)) * 100.0 : 0.0,
        fullOverheal: s.fullOverheal,
        spells: rankLanes(spells))
}

/// Sort the final row set and derive the two scope-relative figures (bar fill + rate).
private func rankRows(_ rows: [HealSourceView], _ durationSec: Double) -> [HealSourceView] {
    var r = stableSorted(rows) { a, b in
        if a.total != b.total { return a.total > b.total }
        if a.count != b.count { return a.count > b.count }
        return Collate.less(a.name, b.name)
    }
    let maxTotal = Double(Swift.max(r.map(\.total).max() ?? 0, 1))
    let dur = Swift.max(1.0, durationSec)
    for i in r.indices {
        r[i].pct = (Double(r[i].total) / maxTotal) * 100.0
        r[i].hps = Double(r[i].total) / dur
    }
    return r
}

private func sourceViews(_ m: JSMap<HealSourceStat>, _ durationSec: Double) -> [HealSourceView] {
    rankRows(m.pairs.map { toView($0.0, $0.1, []) }, durationSec)
}

private func mitigationView(_ m: MitAccum) -> MitigationView {
    MitigationView(runeTotal: m.runeTotal, runeCount: m.runeCount, runeMax: m.runeMax,
                   runeMin: m.runeMin, absorbedSwings: m.absorbedSwings,
                   absorbedDamageShields: m.absorbedDamageShields)
}

/// Serialize an accumulator into the snapshot's healing view.
///
/// The rune lane attaches to the self row so a drill-down is one flat ranked list of everything that
/// kept you up. The self row is SYNTHESIZED when it does not exist: absorption with no heals is a
/// real segment, and so is an unstated heal with no valued heal beside it.
///
/// The enemy ledger gets no absorption: runes are yours, and a mob's own shield is a miss.
public func buildHealingView(_ acc: HealAccum, _ durationSec: Double) -> HealingView {
    var extras: [HealSpellView] = []
    if let rune = runeLane(acc.mit) { extras.append(rune) }
    extras.append(contentsOf: unstatedLanes(acc.unstated))

    var rows: [HealSourceView] = []
    var selfSeen = false
    for (key, s) in acc.friendly.pairs {
        let isSelf = key == SELF_ROW_ID
        if isSelf { selfSeen = true }
        rows.append(toView(key, s, isSelf ? extras : []))
    }
    if !extras.isEmpty && !selfSeen {
        rows.append(toView(SELF_ROW_ID, HealSourceStat(name: "You", kind: .you), extras))
    }
    let healers = rankRows(rows, durationSec)
    let enemyHealers = sourceViews(acc.hostile, durationSec)
    let total = healers.map(\.total).reduce(0, +)
    let absorbedTotal = healers.map(\.absorbedTotal).reduce(0, +)
    return HealingView(
        healers: healers,
        total: total,
        hps: Double(total) / Swift.max(1.0, durationSec),
        restoredTotal: total - absorbedTotal,
        absorbedTotal: absorbedTotal,
        overheal: healers.map(\.overheal).reduce(0, +),
        enemyHealers: enemyHealers,
        enemyTotal: enemyHealers.map(\.total).reduce(0, +),
        mitigation: mitigationView(acc.mit))
}
