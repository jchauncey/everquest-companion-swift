// Damage modifiers and categories (eqlog/src/taxonomy.rs).
import Foundation

public enum Taxonomy {
    private static let twoWord = ["Slay Undead", "Finishing Blow", "Crippling Blow"]

    public static func parseModifiers(_ modifier: String?) -> [String] {
        guard let modifier, !modifier.isEmpty else { return [] }
        let raw = JS.trim(modifier)
        if raw.isEmpty { return [] }
        var mods: [String] = []
        var rest = raw
        for tw in twoWord where rest.contains(tw) {
            mods.append(tw)
            if let r = rest.range(of: tw) {
                rest = JS.trim(String(rest[..<r.lowerBound]) + " " + String(rest[r.upperBound...]))
            }
        }
        for tok in rest.unicodeScalars.split(whereSeparator: JS.isSpace) where !tok.isEmpty {
            mods.append(String(String.UnicodeScalarView(tok)))
        }
        return mods
    }

    public static func hasCritical(_ mods: [String]) -> Bool { mods.contains { JS.eqIgnoreASCIICase($0, "critical") } }
    public static func hasSlayUndead(_ mods: [String]) -> Bool { mods.contains { JS.eqIgnoreASCIICase($0, "slay undead") } }

    public static func damageCategory(_ dtype: String, _ mods: [String]) -> String {
        if dtype == "melee", hasSlayUndead(mods) { return "slay" }
        return dtype
    }
}
