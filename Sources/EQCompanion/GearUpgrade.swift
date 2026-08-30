// What an item's stat block reads at any ` +N` upgrade state — a port of
// `src/shared/itemUpgrade.ts`, which is itself an extraction of the eqlwiki ItemLevelSlider
// module. Nothing here is derived, averaged or tidied up; where the reference disagrees with
// clean decimal arithmetic the reference wins, because the number a player reads on the wiki
// page is the number this app has to reproduce.
//
// The state is the in-game item window's `Tier N  x / y` row. An inventory dump prints the TIER
// and stops, so a name that says ` +5` is `{full: 5, fraction: 0}` and every number derived from
// it is a FLOOR on what the item really reads.
import Foundation

/// The in-game `Tier N  x / y` row: `full` = N, `fraction` = x (and y is always 2^full).
struct ItemUpgradeState: Equatable, Hashable {
    var full: Int = 0
    var fraction: Int = 0

    static let base = ItemUpgradeState(full: 0, fraction: 0)

    /// `full` an integer in 0...10, `fraction` in 0..<2^full, forced to 0 at both ends: tier 0
    /// has no denominator to bank against and tier 10 is the cap.
    var normalized: ItemUpgradeState {
        let f = min(GearUpgrade.maxTier, max(0, full))
        if f == 0 || f == GearUpgrade.maxTier { return ItemUpgradeState(full: f, fraction: 0) }
        let maxFraction = (1 << f) - 1
        return ItemUpgradeState(full: f, fraction: min(maxFraction, max(0, fraction)))
    }

    /// `full + fraction / 2^full` — the slider's position, and the multiplier every stat reads.
    var effectiveLevel: Double {
        let s = normalized
        return Double(s.full) + Double(s.fraction) / pow(2, Double(s.full))
    }

    /// `2^full + fraction` — merge exp banked in total. Only the WEIGHT curve consumes it.
    var totalProgression: Double {
        let s = normalized
        return pow(2, Double(s.full)) + Double(s.fraction)
    }

    /// The headline percentage: `effectiveLevel * 10` (tier 2 + 3/4 → 27.5).
    var percent: Double { effectiveLevel * 10 }

    /// `+27.5%`, `+30%`, `+100%` — as the item window draws it.
    var percentLabel: String {
        let p = percent
        let rounded = (p * 1000).rounded() / 1000
        if rounded == rounded.rounded() { return "+\(Int(rounded))%" }
        return "+\(String(format: "%g", rounded))%"
    }
}

/// How a stat key scales. `unchanged` is the DEFAULT and covers everything the reference leaves
/// alone: heroic stats, Attack, Dmg Bon, Backstab, Range, Size, charges, effect magnitudes.
enum UpgradeStatClass {
    case primary, flat, damage, delay, weight, unchanged
}

enum GearUpgrade {
    static let maxTier = 10

    // MARK: - Rounding (the fixtures fail on any other spelling)

    /// Round half AWAY FROM ZERO at `digits` decimals (Excel's ROUND, not `Math.round`).
    static func excelRound(_ value: Double, _ digits: Int = 0) -> Double {
        let f = pow(10.0, Double(digits))
        let x = value * f
        let r = x < 0 ? -(-x).rounded(.toNearestOrAwayFromZero) : x.rounded(.toNearestOrAwayFromZero)
        return r / f
    }

    /// Ceil AWAY FROM ZERO at `digits` decimals (Excel's ROUNDUP).
    static func excelRoundUp(_ value: Double, _ digits: Int = 0) -> Double {
        let f = pow(10.0, Double(digits))
        return (value < 0 ? -(-value * f).rounded(.up) : (value * f).rounded(.up)) / f
    }

    // MARK: - Stat keys

    /// Key aliases, mirroring the slider's own table. Matching is on the WHOLE normalized key,
    /// which is what keeps `HEROIC STR` out of `STR`.
    private static let aliases: [String: String] = [
        "MANA_REGEN": "MANA_REGEN", "ENDURANCE": "END", "HP_REGEN": "HP_REGEN",
        "END_REGEN": "END_REGEN", "DISEASE": "SV_DISEASE", "POISON": "SV_POISON",
        "DAMAGE": "DMG", "ATK_DELAY": "DELAY", "REGEN": "HP_REGEN", "ENDUR": "END",
        "MAGIC": "SV_MAGIC", "MANA": "MP", "FIRE": "SV_FIRE", "COLD": "SV_COLD", "WT": "WEIGHT"
    ]

    /// `sv magic` / `SV  MAGIC` / `Mana Regen` → `SV_MAGIC` / `SV_MAGIC` / `MANA_REGEN`.
    static func normalizeStatKey(_ key: String) -> String {
        var k = key.trimmingCharacters(in: .whitespaces).uppercased()
        k = k.replacingOccurrences(of: "[\\s-]+", with: "_", options: .regularExpression)
        while k.hasSuffix(":") { k.removeLast() }
        return aliases[k] ?? k
    }

    private static let primaryKeys: Set<String> =
        ["AC", "STR", "STA", "AGI", "DEX", "WIS", "INT", "CHA", "HP", "MP", "END"]
    private static let flatKeys: Set<String> = ["HP_REGEN", "MANA_REGEN", "END_REGEN", "HASTE"]

    /// Which rule a key scales by. Takes a RAW key; normalization happens here.
    static func statClass(_ key: String) -> UpgradeStatClass {
        let k = normalizeStatKey(key)
        if k == "DMG" { return .damage }
        if k == "DELAY" { return .delay }
        if k == "WEIGHT" { return .weight }
        if flatKeys.contains(k) { return .flat }
        if primaryKeys.contains(k) || k.hasPrefix("SV_") { return .primary }
        return .unchanged
    }

    // MARK: - The scaling rules

    /// PRIMARY (AC, the seven attributes, HP/MP/END, every SV_*):
    ///   base == 0       → 0            (an absent stat stays absent)
    ///   0 < base <= 10  → base + full  (FRACTION IGNORED)
    ///   base > 10       → floor(base + round(base * effective / 10))
    ///   base < 0        → min(0, base + full)  penalties shrink toward zero, never past it
    static func scalePrimary(_ base: Int, _ state: ItemUpgradeState) -> Int {
        let s = state.normalized
        if base == 0 { return 0 }
        if base < 0 { return min(0, base + s.full) }
        if base <= 10 { return base + s.full }
        return Int(floor(Double(base) + excelRound(Double(base) * s.effectiveLevel / 10, 0)))
    }

    /// WEAPON DMG: `base + floor(base * effective / 10)` — and it reads the fraction.
    static func scaleDamage(_ base: Int, _ state: ItemUpgradeState) -> Int {
        if base <= 0 { return base }
        return base + Int(floor(Double(base) * state.effectiveLevel / 10))
    }

    /// FLAT (the three regens, Haste): `base + full`, fraction ignored.
    static func scaleFlat(_ base: Int, _ state: ItemUpgradeState) -> Int {
        if base <= 0 { return base }
        return base + state.normalized.full
    }

    /// WEIGHT: `max(0, ceilToOneDecimal(base * (1 - 0.09 * log2(totalProgression))))`. The
    /// `base <= 0.1` test is an ENTRY GUARD, not an output clamp.
    static func scaleWeight(_ base: Double, _ state: ItemUpgradeState) -> Double {
        let s = state.normalized
        if s.full == 0 || base <= 0.1 { return base }
        return max(0, excelRoundUp(base * (1 - 0.09 * log2(s.totalProgression)), 1))
    }

    /// One base value at `state`, by the rule its key takes. `delay` and `unchanged` are the same
    /// answer, kept apart on purpose: DELAY not scaling is the whole reason a weapon's ratio improves.
    static func scale(key: String, base: Int, state: ItemUpgradeState) -> Int {
        switch statClass(key) {
        case .primary: return scalePrimary(base, state)
        case .flat: return scaleFlat(base, state)
        case .damage: return scaleDamage(base, state)
        case .weight, .delay, .unchanged: return base
        }
    }

    // MARK: - SV VOID synthesis

    /// The upgrade grants a synthetic `SV VOID: +full` line to any upgraded item carrying at least
    /// TWO distinct fields from this set. AC, HP and MP are deliberately NOT in it.
    private static let voidTriggers: Set<String> = [
        "STR", "STA", "INT", "AGI", "DEX", "CHA", "WIS",
        "SV_FIRE", "SV_COLD", "SV_POISON", "SV_MAGIC", "SV_DISEASE"
    ]

    /// Whether an upgraded copy of these stat/save rows gains the synthetic SV VOID line.
    /// An item that already states SV VOID keeps its own (scaled) line; we never draw a second.
    static func synthesizesVoidSave(statKeys: [String], saveKeys: [String], state: ItemUpgradeState) -> Bool {
        if state.normalized.full == 0 { return false }
        if saveKeys.contains(where: { normalizeStatKey($0) == "SV_VOID" }) { return false }
        var seen = Set<String>()
        for k in statKeys + saveKeys {
            let n = normalizeStatKey(k)
            if voidTriggers.contains(n) { seen.insert(n) }
        }
        return seen.count >= 2
    }

    // MARK: - Stat-value text

    /// `+15` → 15, `36%` → 36, `-5` → -5. `nil` when the value states no number.
    static func statNumber(_ value: String) -> Double? {
        guard let r = value.range(of: "-?\\d+(?:\\.\\d+)?", options: .regularExpression) else { return nil }
        return Double(value[r])
    }

    /// A value → an integer, or nil when it is not one. A trailing `%` DISQUALIFIES the value
    /// rather than being stripped: a percentage that fell into an integer total would be a lie.
    static func statInteger(_ value: String) -> Int? {
        let t = value.trimmingCharacters(in: .whitespaces)
        guard t.range(of: "^[+-]?\\d+$", options: .regularExpression) != nil else { return nil }
        return Int(t.hasPrefix("+") ? String(t.dropFirst()) : t)
    }

    /// Re-render a scaled value in the SOURCE's own spelling: the leading `+` survives only if the
    /// item wrote one, and a trailing `%` is carried across verbatim.
    static func renderStatValue(source: String, scaled: Int) -> String {
        let hadPlus = source.range(of: "^\\s*\\+", options: .regularExpression) != nil
        let suffix = source.range(of: "\\d\\s*%\\s*$", options: .regularExpression) != nil ? "%" : ""
        let body = scaled > 0 && hadPlus ? "+\(scaled)" : "\(scaled)"
        return body + suffix
    }

    /// The ONE reading of a ` +N` the game wrote down. `nil` is "the name carried no suffix",
    /// never tier 0 arriving by another road; both answer the base state.
    static func state(forTier tier: Int?) -> ItemUpgradeState {
        guard let tier else { return .base }
        return ItemUpgradeState(full: tier, fraction: 0).normalized
    }

    // MARK: - Display labels

    private static let statLabels: [String: String] = [
        "STR": "Strength", "STA": "Stamina", "AGI": "Agility", "DEX": "Dexterity",
        "WIS": "Wisdom", "INT": "Intelligence", "CHA": "Charisma",
        "HP": "HP", "MANA": "Mana", "END": "Endurance", "ENDURANCE": "Endurance",
        "AC": "AC", "HASTE": "Haste", "ATTACK": "Attack", "REGEN": "Regen"
    ]

    /// In-window label for a stat key ("STR" → "Strength", "SV FIRE" → "SV Fire").
    static func statLabel(_ key: String) -> String {
        let k = key.uppercased()
        if let l = statLabels[k] { return l }
        if k.hasPrefix("SV ") { return "SV " + titleCase(String(k.dropFirst(3))) }
        return titleCase(k)
    }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            guard let f = w.first else { return "" }
            return String(f).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
