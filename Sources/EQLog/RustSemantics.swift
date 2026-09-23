// The Rust library semantics the goldens were cut under, stated once. `JS` (JSStr.swift) is the
// same idea for the JavaScript half: where upstream leaned on a language's own behaviour, the port
// restates it here rather than hoping Swift's agrees.
import Foundation

public enum Rust {
    /// `i64::div_euclid`: the quotient rounded so the remainder is never negative. Swift's `/`
    /// truncates toward zero, which differs for a negative dividend.
    public static func divEuclid(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        if a % b < 0 { return b > 0 ? q - 1 : q + 1 }
        return q
    }

    /// `slice::sort_by` — stable. Swift's `sorted(by:)` is not guaranteed to be, and several
    /// upstream comparators are not total, so a tie must keep insertion order.
    public static func stableSorted<T>(_ xs: [T], _ less: (T, T) -> Bool) -> [T] {
        xs.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// `stableSorted` over a three-way comparator (negative, zero, positive), JS `sort`'s shape.
    public static func stableSorted<T>(_ xs: [T], cmp: (T, T) -> Int) -> [T] {
        xs.enumerated().sorted { a, b in
            let c = cmp(a.element, b.element)
            return c != 0 ? c < 0 : a.offset < b.offset
        }.map(\.element)
    }

    /// `str` ordering: byte-wise over UTF-8, which is also Unicode code point order. Swift's `<` on
    /// `String` compares by canonical equivalence and does not agree.
    public static func bytesLess(_ a: String, _ b: String) -> Bool {
        a.utf8.lexicographicallyPrecedes(b.utf8)
    }
}
