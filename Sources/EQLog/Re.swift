// The regex shim: ICU (`NSRegularExpression`) driven with the Rust crate's dialect, so a ported
// pattern is pasted rather than rewritten. Three translations are applied to every pattern:
//   `\u{XXXX}` → `\x{XXXX}`      (code-point escapes)
//   `(?-u:\b)` → `\b`            (the ASCII word boundary; ICU's `\b` is the nearest)
//   `$`        → `\z`            (Rust's `$` is END OF INPUT; ICU's `$` also matches before a
//                                 trailing line terminator — and the log carries bare CRs)
//   `.`        → `[^\n]`          (Rust's `.` excludes only `\n`; ICU's also excludes `\r`, NEL
//                                 and the two Unicode separators)
// `^`, `(?i)`, `(?:…)`, lazy quantifiers and alternation are the same in both.
//
// Captures come back as `Substring`s over the ORIGINAL Swift string, so a classifier slices the
// line without copying and `JS.trim` runs on the slice.
import Foundation

public struct Caps {
    public let whole: Substring
    private let groups: [Substring?]

    init(whole: Substring, groups: [Substring?]) {
        self.whole = whole
        self.groups = groups
    }

    /// Group `i` (1-based), or nil when it did not participate. `self[0]` is the whole match.
    public subscript(i: Int) -> Substring? {
        if i == 0 { return whole }
        return i - 1 < groups.count ? groups[i - 1] : nil
    }

    /// Group `i` as a String, or "" — for a group the pattern guarantees participates.
    public func s(_ i: Int) -> String { self[i].map(String.init) ?? "" }
    public var count: Int { groups.count + 1 }
    public var start: String.Index { whole.startIndex }
    public var end: String.Index { whole.endIndex }
}

/// One line's bridged form, cached: the cascade asks up to 45 regexes about the same line, and
/// bridging a Swift String to an NSString (with its UTF-16 length) each time costs more than the
/// match. A single-entry cache keyed by string EQUALITY (a short memcmp) makes it one bridge per
/// line. Thread-local, since the tail and a test may parse concurrently.
final class BridgeCache {
    var last: String = ""
    var ns: NSString = ""
    var range = NSRange(location: 0, length: 0)

    static var current: BridgeCache {
        let key = "eqlog.re.bridge"
        if let c = Thread.current.threadDictionary[key] as? BridgeCache { return c }
        let c = BridgeCache()
        Thread.current.threadDictionary[key] = c
        return c
    }

    @inline(__always)
    func bridged(_ s: String) -> (NSString, NSRange) {
        if s == last { return (ns, range) }
        let n = s as NSString
        last = s
        ns = n
        range = NSRange(location: 0, length: n.length)
        return (n, range)
    }
}

public final class Re: @unchecked Sendable {
    public let pattern: String
    let re: NSRegularExpression

    public init(_ rust: String) {
        pattern = rust
        let icu = Re.translate(rust)
        do {
            re = try NSRegularExpression(pattern: icu, options: [])
        } catch {
            fatalError("bad pattern \(rust) → \(icu): \(error)")
        }
    }

    /// Case-insensitive shorthand for `(?i)…`.
    public convenience init(ci rust: String) { self.init("(?i)" + rust) }

    static func translate(_ p: String) -> String {
        var out = ""
        var chars = Array(p)
        var i = 0
        var inClass = false
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "u", i + 2 < chars.count, chars[i + 2] == "{" {
                    out.append("\\x{")
                    i += 3
                    continue
                }
                out.append(c); out.append(n)
                i += 2
                continue
            }
            if inClass {
                if c == "]" { inClass = false }
                out.append(c)
                i += 1
                continue
            }
            if c == "[" { inClass = true; out.append(c); i += 1; continue }
            if c == "(", i + 6 < chars.count, String(chars[i..<i + 7]) == "(?-u:\\b" {
                // `(?-u:\b)` → `\b`
                if i + 7 < chars.count, chars[i + 7] == ")" {
                    out.append("\\b")
                    i += 8
                    continue
                }
            }
            if c == "$" { out.append("\\z"); i += 1; continue }
            if c == "." { out.append("[^\\n]"); i += 1; continue }
            out.append(c)
            i += 1
        }
        _ = chars
        chars = []
        return out
    }

    public func isMatch(_ s: String) -> Bool {
        let (ns, r) = BridgeCache.current.bridged(s)
        return re.firstMatch(in: ns as String, options: [], range: r) != nil
    }

    public func isMatch(_ s: Substring) -> Bool { isMatch(String(s)) }

    /// The first match's captures, or nil.
    public func captures(_ s: String) -> Caps? {
        let (ns, r) = BridgeCache.current.bridged(s)
        guard let m = re.firstMatch(in: ns as String, options: [], range: r) else { return nil }
        return caps(m, in: s)
    }

    public func captures(_ s: Substring) -> Caps? { captures(String(s)) }

    private func caps(_ m: NSTextCheckingResult, in s: String) -> Caps {
        guard let wr = Range(m.range, in: s) else { return Caps(whole: s[s.startIndex..<s.startIndex], groups: []) }
        var groups: [Substring?] = []
        groups.reserveCapacity(m.numberOfRanges - 1)
        for g in 1..<max(1, m.numberOfRanges) {
            let r = m.range(at: g)
            if r.location == NSNotFound { groups.append(nil) } else if let rr = Range(r, in: s) { groups.append(s[rr]) } else { groups.append(nil) }
        }
        return Caps(whole: s[wr], groups: groups)
    }

    /// Every match, in order.
    public func allCaptures(_ s: String) -> [Caps] {
        re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)).map { caps($0, in: s) }
    }

    /// The first match's range.
    public func find(_ s: String) -> Range<String.Index>? {
        let (ns, r) = BridgeCache.current.bridged(s)
        guard let m = re.firstMatch(in: ns as String, options: [], range: r) else { return nil }
        return Range(m.range, in: s)
    }

    /// `Regex::replace` — the FIRST match replaced with a literal.
    public func replaceFirst(_ s: String, with lit: String) -> String {
        guard let r = find(s) else { return s }
        return s.replacingCharacters(in: r, with: lit)
    }

    /// `Regex::replace_all` with a literal.
    public func replaceAll(_ s: String, with lit: String) -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s),
                                    withTemplate: NSRegularExpression.escapedTemplate(for: lit))
    }
}
