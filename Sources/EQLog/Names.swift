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

    /// The ten numerals `rankTail` matches, by value.
    private static let numerals: [String: Int64] = [
        "I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10,
    ]

    /// Where `rankTail` matches, without the regex: the pattern is a space, one numeral, then the
    /// end, so only the LAST space can start a match and the text after it must be exactly one
    /// numeral. Returns the index of that space, or nil for no match. `caseInsensitive` answers for
    /// `rankTailCI` when the tail is ASCII; a non-ASCII tail returns `.fallback` so the caller asks
    /// ICU, whose case folding this does not restate.
    enum TailMatch { case none, at(String.Index, Int64), fallback }
    static func rankTailMatch(_ s: String, caseInsensitive: Bool) -> TailMatch {
        let u = s.utf8
        guard let sp = u.lastIndex(of: 0x20) else { return .none }
        let tail = u[u.index(after: sp)...]
        if tail.isEmpty || tail.count > 4 { return .none }
        var word = ""
        for b in tail {
            if b >= 0x80 { return caseInsensitive ? .fallback : .none }
            let c = caseInsensitive && b >= 0x61 && b <= 0x7A ? b - 0x20 : b
            word.unicodeScalars.append(Unicode.Scalar(c))
        }
        guard let v = numerals[word] else { return .none }
        return .at(sp, v)
    }

    public static func stripRankTail(_ name: String) -> String {
        switch rankTailMatch(name, caseInsensitive: false) {
        case .at(let i, _): return String(name[..<i])
        case .none, .fallback: return name
        }
    }

    public static func spellCanonKey(_ spell: String) -> String {
        JS.trim(stripRankTail(JS.trim(spell))).lowercased()
    }

    public static func dbCanonKey(_ name: String) -> String {
        let t = JS.trim(name)
        let stripped: String
        switch rankTailMatch(t, caseInsensitive: true) {
        case .at(let i, _): stripped = String(t[..<i])
        case .none: stripped = t
        case .fallback: stripped = rankTailCI.replaceFirst(t, with: "")
        }
        return JS.trim(stripped).lowercased()
    }

    public static func spellRank(_ spell: String) -> Int64 {
        if case .at(_, let v) = rankTailMatch(JS.trim(spell), caseInsensitive: false) { return v }
        return 0
    }

    /// The regex spellings, kept as the oracle `rankTailMatch` is tested against.
    static func stripRankTailByRegex(_ name: String) -> String { rankTail.replaceFirst(name, with: "") }
    static func dbStripByRegex(_ name: String) -> String { rankTailCI.replaceFirst(name, with: "") }
    static func spellRankByRegex(_ spell: String) -> Int64 {
        guard let r = rankTail.find(JS.trim(spell)) else { return 0 }
        return numerals[JS.trim(String(JS.trim(spell)[r]))] ?? 0
    }

    private static let possessive = Re("(?i)['`\\u{2019}]s$")

    public static func cleanMob(_ s: String?) -> String? {
        guard let s else { return nil }
        let out = JS.trim(possessive.replaceFirst(s, with: ""))
        return out.isEmpty ? nil : out
    }
}
