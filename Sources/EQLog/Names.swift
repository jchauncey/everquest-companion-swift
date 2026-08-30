// Name folds (eqlog/src/names.rs).
import Foundation

public enum Names {
    /// `norm`: trim, and the three self-words become `You`.
    public static func norm(_ name: String) -> String {
        let n = JS.trim(name)
        let l = n.lowercased()
        if l == "you" || l == "yourself" || l == "your" { return "You" }
        return n
    }

    public static func norm(_ name: Substring) -> String { norm(String(name)) }

    /// `id_key`: trim + lowercase, the self-words → `you`.
    public static func idKey(_ name: String) -> String {
        let n = JS.trim(name)
        let l = n.lowercased()
        if l == "you" || l == "yourself" || l == "your" { return "you" }
        return l
    }

    private static let rankTail = Re(" (?:I|II|III|IV|V|VI|VII|VIII|IX|X)$")
    private static let rankTailCI = Re("(?i) (?:I|II|III|IV|V|VI|VII|VIII|IX|X)$")

    public static func stripRankTail(_ name: String) -> String { rankTail.replaceFirst(name, with: "") }

    public static func spellCanonKey(_ spell: String) -> String {
        JS.trim(stripRankTail(JS.trim(spell))).lowercased()
    }

    public static func dbCanonKey(_ name: String) -> String {
        JS.trim(rankTailCI.replaceFirst(JS.trim(name), with: "")).lowercased()
    }

    public static func spellRank(_ spell: String) -> Int64 {
        guard let r = rankTail.find(JS.trim(spell)) else { return 0 }
        let m = JS.trim(String(JS.trim(spell)[r]))
        switch m {
        case "I": return 1
        case "II": return 2
        case "III": return 3
        case "IV": return 4
        case "V": return 5
        case "VI": return 6
        case "VII": return 7
        case "VIII": return 8
        case "IX": return 9
        case "X": return 10
        default: return 0
        }
    }

    private static let possessive = Re("(?i)['`\\u{2019}]s$")

    public static func cleanMob(_ s: String?) -> String? {
        guard let s else { return nil }
        let out = JS.trim(possessive.replaceFirst(s, with: ""))
        return out.isEmpty ? nil : out
    }
}
