// Ports of the small JS helpers the modules share (fold/src/jsfn.rs).
import Foundation
import EQLog

public enum JSFn {
    public static let tierOpenWorld: Int64 = -1
    public static let tierUnknown: Int64 = -2

    private static func tierAdj(_ word: String) -> Int64? {
        switch word.lowercased() {
        case "awakened": return 1
        case "adaptive": return 2
        case "fused": return 3
        case "refined": return 4
        default: return nil
        }
    }

    private static let stripSuffix = Re("(?i)\(JS.S)*-\(JS.S)*(?:Solo|Group)(?-u:\\b)\(JS.DOT)*$")
    private static let stripNumberedParen = Re("\(JS.S)+[0-9]+\(JS.S)*\\([^)]*\\)\(JS.S)*$")
    private static let stripParen = Re("\(JS.S)+\\([^)]*\\)\(JS.S)*$")
    private static let adjective = Re("\\(([A-Za-z]+)\\)\(JS.S)*$")
    private static let instanceSuffix = Re("(?i)\(JS.S)-\(JS.S)*(?:Solo|Group)(?-u:\\b)")

    /// `(base name, tier)`: the zone line decodes instance adjectives, `- Solo/Group`, open world.
    public static func zoneTier(_ zone: String) -> (String, Int64) {
        let a = stripSuffix.replaceFirst(zone, with: "")
        let b = stripNumberedParen.replaceFirst(a, with: "")
        let c = stripParen.replaceFirst(b, with: "")
        let base = JS.trim(c)
        if let m = adjective.captures(zone) { return (base, tierAdj(m.s(1)) ?? tierUnknown) }
        if instanceSuffix.isMatch(zone) { return (base, 0) }
        return (base, base.isEmpty ? tierUnknown : tierOpenWorld)
    }

    public static func zoneIdKey(_ zone: String) -> String { JS.trim(zone).lowercased() }

    /// `killer` starts with the whole word `you`.
    public static func startsWithYouWord(_ killer: String) -> Bool {
        let s = Array(killer.unicodeScalars)
        guard s.count >= 3 else { return false }
        for (i, want) in ["y", "o", "u"].enumerated() {
            guard let c = Character(s[i]).lowercased().unicodeScalars.first, String(c) == want, s[i].value < 128 else { return false }
        }
        if s.count == 3 { return true }
        let n = s[3]
        return !((n.value >= 48 && n.value <= 57) || (n.value >= 65 && n.value <= 90) || (n.value >= 97 && n.value <= 122) || n == "_")
    }

    private static let tierTail = Re(" \\+([0-9]+)$")
    private static let tierTailStrip = Re(" \\+[0-9]+$")

    public static func itemTierFromName(_ name: String) -> Int64? {
        guard let m = tierTail.captures(JS.trim(name)) else { return nil }
        return Int64(m.s(1))
    }

    public static func itemBaseName(_ name: String) -> String { JS.trim(tierTailStrip.replaceFirst(name, with: "")) }
    public static func itemTierKey(_ name: String) -> String { itemBaseName(name).lowercased() }

    private static let spaces = Re("\(JS.S)+")
    public static func memoKey(_ spell: String) -> String { spaces.replaceAll(JS.trim(spell).lowercased(), with: " ") }

    public static func baseName(_ path: String) -> String {
        if let i = path.lastIndex(where: { $0 == "/" || $0 == "\\" }) { return String(path[path.index(after: i)...]) }
        return path
    }

    public struct SpellRank { public var base: String; public var rank: Int64; public var suffixed: Bool }

    private static let rankRe = Re("(?i) (I|II|III|IV|V|VI|VII|VIII|IX|X)$")

    public static func parseSpellRank(_ name: String) -> SpellRank {
        let trimmed = JS.trim(name)
        guard let m = rankRe.captures(trimmed) else { return SpellRank(base: trimmed, rank: 1, suffixed: false) }
        return SpellRank(base: JS.trim(String(trimmed[..<m.start])), rank: rankValue(m.s(1)), suffixed: true)
    }

    private static func rankValue(_ numeral: String) -> Int64 {
        switch numeral.lowercased() {
        case "i": return 1
        case "ii": return 2
        case "iii": return 3
        case "iv": return 4
        case "v": return 5
        case "vi": return 6
        case "vii": return 7
        case "viii": return 8
        case "ix": return 9
        case "x": return 10
        default: return 1
        }
    }
}
