// JavaScript string semantics, spelled out (eqlog/src/jsstr.rs): the places Swift's defaults are
// not V8's. `String.prototype.trim` strips ECMA WhiteSpace ∪ LineTerminator; `\s` in a JS regex is
// that same set; `JSON.stringify` escapes `"`, `\` and the C0 controls and nothing else. The whole
// golden rests on `writeJSONString`.
import Foundation

public enum JS {
    /// The ECMA-262 `WhiteSpace ∪ LineTerminator` set as an ICU regex class. Interpolate for `\s`.
    public static let S = "[\\t\\n\\x0B\\x0C\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}]"
    /// The same set without brackets, for a class that unions it with something else.
    public static let S_INNER = "\\t\\n\\x0B\\x0C\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
    /// JavaScript's `.`: everything but the four ECMA line terminators.
    public static let DOT = "[^\\n\\r\\x{2028}\\x{2029}]"
    /// JS `\d` and `\w` are ASCII.
    public static let D = "[0-9]"
    public static let W = "[0-9A-Za-z_]"

    public static func isSpace(_ c: Character) -> Bool {
        guard let u = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return isSpace(u)
    }

    public static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x9, 0xA, 0xB, 0xC, 0xD, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    /// `String.prototype.trim`.
    public static func trim(_ s: String) -> String {
        // The common case allocates nothing: neither end is whitespace.
        if let f = s.unicodeScalars.first, let l = s.unicodeScalars.last, !isSpace(f), !isSpace(l) { return s }
        var scalars = s.unicodeScalars[...]
        while let f = scalars.first, isSpace(f) { scalars.removeFirst() }
        while let l = scalars.last, isSpace(l) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    public static func trim(_ s: Substring) -> String { trim(String(s)) }

    /// `JSON.stringify` on a string, including the quotes.
    public static func writeJSONString(_ out: inout String, _ s: String) {
        out.append("\"")
        // Fast path: nothing to escape (no control byte, quote or backslash) → one append.
        var copy = s
        let clean = copy.withUTF8 { b -> Bool in
            for x in b where x < 0x20 || x == 0x22 || x == 0x5c { return false }
            return true
        }
        if clean {
            out.append(s)
            out.append("\"")
            return
        }
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\u{8}": out.append("\\b")
            case "\u{9}": out.append("\\t")
            case "\u{A}": out.append("\\n")
            case "\u{C}": out.append("\\f")
            case "\u{D}": out.append("\\r")
            default:
                if u.value < 0x20 {
                    let hex = Array("0123456789abcdef")
                    out.append("\\u00")
                    out.append(hex[Int((u.value >> 4) & 0xf)])
                    out.append(hex[Int(u.value & 0xf)])
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out.append("\"")
    }

    public static func jsonString(_ s: String) -> String {
        var o = ""
        writeJSONString(&o, s)
        return o
    }

    /// `JSON.stringify` on a number: an integral double prints without a fraction; otherwise the
    /// shortest round-trip form, which Swift's `description` also produces.
    public static func writeNumber(_ out: inout String, _ v: Double) {
        if v == v.rounded(.towardZero), abs(v) < 9.0e15 {
            out.append(String(Int64(v)))
        } else {
            out.append(numberText(v))
        }
    }

    /// Shortest round-trip, in JS spelling: no `+` in exponents below 1e21, no `.0`.
    public static func numberText(_ v: Double) -> String {
        if v == v.rounded(.towardZero), abs(v) < 9.0e15 { return String(Int64(v)) }
        var s = "\(v)"
        // Swift prints 1e-07 as "1e-07"; JS prints "1e-7". Both notations only part company far
        // outside the corpus's range; normalise the exponent spelling anyway.
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mant = s[..<e]
            var exp = String(s[s.index(after: e)...])
            var sign = ""
            if exp.hasPrefix("+") { exp.removeFirst() } else if exp.hasPrefix("-") { sign = "-"; exp.removeFirst() }
            while exp.count > 1, exp.hasPrefix("0") { exp.removeFirst() }
            s = "\(mant)e\(sign.isEmpty ? "+" : sign)\(exp)"
        }
        return s
    }

    /// `String.prototype.toLowerCase` — Unicode default case conversion, which Swift's `lowercased()` is.
    @inline(__always) public static func lower(_ s: String) -> String { s.lowercased() }

    @inline(__always) private static func asciiLower(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5a) ? b | 0x20 : b
    }

    /// ASCII case-insensitive equality (`eq_ignore_ascii_case`).
    public static func eqIgnoreASCIICase(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.count != y.count { return false }
        for i in 0..<x.count where asciiLower(x[i]) != asciiLower(y[i]) { return false }
        return true
    }

    /// `text` starts with `lower` (an ASCII-lowercase needle), case-insensitively.
    public static func startsWithCI(_ text: Substring, _ lower: String) -> Bool {
        let t = Array(text.utf8), n = Array(lower.utf8)
        if t.count < n.count { return false }
        for i in 0..<n.count where asciiLower(t[i]) != n[i] { return false }
        return true
    }
}


/// A native substring search. With Foundation imported, `String.contains(String)` resolves to
/// Foundation's locale-aware `range(of:)`, which the profiler put at a third of a parse; this
/// concrete overload wins overload resolution and is a `memmem`.
public extension String {
    @inline(__always)
    func contains(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var n = needle
        var h = self
        return h.withUTF8 { hb in
            n.withUTF8 { nb in
                guard hb.count >= nb.count else { return false }
                return memmem(hb.baseAddress, hb.count, nb.baseAddress, nb.count) != nil
            }
        }
    }
}

public extension Substring {
    @inline(__always)
    func contains(_ needle: String) -> Bool { String(self).contains(needle) }
}
