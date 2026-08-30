// `String.prototype.localeCompare` for the combat views — the name tiebreak the ranked lists in this
// directory reach for (`fold/src/combat/collate.rs`).
//
// CLDR root collation is `alternate = non-ignorable`, so whitespace, punctuation and symbols each
// carry a primary weight, below digits, below letters — which is what decides a tie like
// `a willowisp` against `Asaka L\`Rei`.
//
// Stated limit: a character outside the table sorts after every letter, ordered by codepoint. The
// repertoire seen so far is ASCII plus the backtick and the proc-lane marker's middle dot.
import Foundation

public enum Collate {
    /// The CLDR root primary order for the repertoire these lists actually contain: whitespace, then
    /// punctuation, then symbols, then digits, then letters.
    static let primaryOrder: [Unicode.Scalar] = [
        "\t", " ", "_", "-", "\u{2013}", "\u{2014}", ",", ";", ":", "!", "?", ".", "\u{00b7}", "'",
        "\u{2019}", "\"", "(", ")", "[", "]", "{", "}", "@", "*", "/", "\\", "&", "#", "%", "`", "^",
        "+", "<", "=", ">", "|", "~", "$", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]

    /// Where the letters begin, so a letter always sorts after every space, mark and digit.
    static let letterBase = UInt32(primaryOrder.count)
    /// …and where an unknown character begins: after every letter, ordered by codepoint.
    static let unknownBase = letterBase + 0x0011_0000

    static let primaryIndex: [UInt32: UInt32] = {
        var m: [UInt32: UInt32] = [:]
        for (i, s) in primaryOrder.enumerated() { m[s.value] = UInt32(i) }
        return m
    }()

    static func primary(_ c: Unicode.Scalar) -> UInt32 {
        if let i = primaryIndex[c.value] { return i }
        if c.properties.isAlphabetic {
            // Case folds away at the primary level; it comes back as the tertiary difference below.
            let lower = String(c).lowercased().unicodeScalars.first ?? c
            return letterBase &+ lower.value
        }
        return unknownBase &+ c.value
    }

    /// The tertiary weight: lowercase before uppercase for the same letter, as CLDR root does.
    /// Compared left to right across the whole string only after every primary weight has tied,
    /// which is why `aB` sorts before `Ab`.
    static func tertiary(_ c: Unicode.Scalar) -> UInt8 {
        c.properties.isUppercase ? 1 : 0
    }

    private static func lex<T: Comparable>(_ a: [T], _ b: [T]) -> ComparisonResult {
        var i = 0
        while i < a.count && i < b.count {
            if a[i] < b[i] { return .orderedAscending }
            if a[i] > b[i] { return .orderedDescending }
            i += 1
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }

    /// `a.localeCompare(b)` over the names these views rank.
    public static func compareNames(_ a: String, _ b: String) -> ComparisonResult {
        let byPrimary = lex(a.unicodeScalars.map(primary), b.unicodeScalars.map(primary))
        if byPrimary != .orderedSame { return byPrimary }
        let byTertiary = lex(a.unicodeScalars.map(tertiary), b.unicodeScalars.map(tertiary))
        if byTertiary != .orderedSame { return byTertiary }
        // Identical under the collation: codepoint order is the last resort, so the comparator is a
        // total order and a sort over it is reproducible. Rust's `str` Ord is UTF-8 byte order.
        return lex(Array(a.utf8), Array(b.utf8))
    }

    /// `compareNames(a, b) == Ordering::Less`, for a `sort(by:)` predicate.
    public static func less(_ a: String, _ b: String) -> Bool {
        compareNames(a, b) == .orderedAscending
    }
}
