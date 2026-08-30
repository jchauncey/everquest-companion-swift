// The four load-time passes that run over the scraped entries before any table is derived:
// removals, derived durations, corrections, placeholder blanking. See `SpellDb.swift` for the chain.
// (eqlog/src/spelldb/passes.rs)
import Foundation
import EQData

/// `data/spell-overlay.json`: the projection of the app's removal and correction lists this parser
/// needs.
public struct Sidecar: Decodable {
    public var removals: [String]
    public var corrections: [Correction]
}

public struct Correction: Decodable {
    public var spells: [String]
    public var field: String
    public var from: String?
    public var to: String
}

public enum SpellDbPasses {
    public static func sidecar() -> Sidecar {
        guard let text = EQData.text("spell-overlay.json") else {
            fatalError("spell-overlay.json is not shipped")
        }
        guard let s = try? JSONDecoder().decode(Sidecar.self, from: Data(text.utf8)) else {
            fatalError("spell-overlay.json is not readable")
        }
        return s
    }

    /// Drop every row named by a removal.
    public static func applyRemovals(_ spells: [SpellEntry], _ removals: [String]) -> [SpellEntry] {
        let wanted = Set(removals)
        return spells.filter { !wanted.contains($0.name) }
    }

    /// Re-derive `durationMs` from `durationText` through the one reader.
    public static func applyDerivedDurations(_ spells: inout [SpellEntry]) {
        for i in spells.indices {
            spells[i].durationMs = parseDurationMs(spells[i].durationText)
        }
    }

    /// The name index is built once, before any correction runs, so a `name` correction does not
    /// re-index — which matters for a pair of corrections that rename a row another one then patches.
    public static func applyCorrections(_ spells: inout [SpellEntry], _ corrections: [Correction]) {
        var byName: [String: [Int]] = [:]
        let owned = spells.map(\.name)
        for (i, n) in owned.enumerated() { byName[n, default: []].append(i) }
        for c in corrections {
            for name in c.spells {
                // A rename that already ran leaves no row under `from`; nothing to write.
                guard let all = byName[name] else { continue }
                // A message correction writes the first row of its name; a name / spellType /
                // classes correction writes all of them.
                let rows: ArraySlice<Int> =
                    (c.field == "name" || c.field == "spellType" || c.field == "classes")
                    ? all[...] : all[..<1]
                for at in rows {
                    let current = fieldOf(spells[at], c.field)
                    if current == c.to { continue } // satisfied
                    let describes: Bool
                    switch c.from {
                    case .none: describes = current == nil
                    case .some(let from): describes = current == from
                    }
                    if !describes { continue } // stale — the app reports it and its audit suite fails on it
                    setField(&spells[at], c.field, c.to)
                }
            }
        }
    }

    static func fieldOf(_ s: SpellEntry, _ field: String) -> String? {
        switch field {
        case "name": return s.name
        case "spellType": return s.spellType
        case "classes": return s.classes
        case "msgCastOnYou": return s.msgCastOnYou
        case "msgCastOnOther": return s.msgCastOnOther
        case "msgWearsOff": return s.msgWearsOff
        default: fatalError("spell-overlay.json names an unknown field \(field)")
        }
    }

    static func setField(_ s: inout SpellEntry, _ field: String, _ to: String) {
        switch field {
        case "name": s.name = to
        case "spellType": s.spellType = to
        case "classes": s.classes = to
        case "msgCastOnYou": s.msgCastOnYou = to
        case "msgCastOnOther": s.msgCastOnOther = to
        case "msgWearsOff": s.msgWearsOff = to
        default: fatalError("spell-overlay.json names an unknown field \(field)")
        }
    }

    /// Blank the scrape's stub fields so every table reads them as the nothing they are.
    public static func applyPlaceholderMessages(_ spells: inout [SpellEntry]) {
        for i in spells.indices {
            if let m = spells[i].msgCastOnYou, isPlaceholder(m) { spells[i].msgCastOnYou = nil }
            if let m = spells[i].msgCastOnOther, isPlaceholder(m) { spells[i].msgCastOnOther = nil }
            if let m = spells[i].msgWearsOff, isPlaceholder(m) { spells[i].msgWearsOff = nil }
        }
    }

    /// The subject words a message can consist entirely of, lowercased.
    static let bareSubjects: Set<String> = ["you", "your", "someone", "target", "player", "soandso"]

    /// A subject with no predicate, or the literal `N/A`.
    public static func isPlaceholder(_ msg: String) -> Bool {
        let text = JS.trim(msg)
        if text.uppercased() == "N/A" { return true }
        // A run of non-alphanumerics collapses to one space; leading and trailing runs fall to the trim.
        var words = ""
        words.reserveCapacity(text.utf8.count)
        var gap = false
        for c in text.unicodeScalars {
            if isASCIIAlphanumeric(c) {
                if gap && !words.isEmpty { words.append(" ") }
                gap = false
                words.unicodeScalars.append(c)
            } else {
                gap = true
            }
        }
        let collapsed = JS.trim(words).lowercased()
        return collapsed.isEmpty || bareSubjects.contains(collapsed)
    }

    @inline(__always) static func isASCIIAlphanumeric(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 48 && c.value <= 57) || (c.value >= 65 && c.value <= 90) || (c.value >= 97 && c.value <= 122)
    }

    /// Rust's `x.round() as i64` — half away from zero, saturating.
    @inline(__always) static func round64(_ x: Double) -> Int64 {
        if x.isNaN { return 0 }
        let r = x.rounded()
        if r >= 9.223372036854775e18 { return Int64.max }
        if r <= -9.223372036854775e18 { return Int64.min }
        return Int64(r)
    }

    static func unitMs(_ n: Double, _ unitRaw: String) -> Int64? {
        let u = unitRaw.lowercased()
        switch u {
        case "h", "hr", "hrs", "hour", "hours": return round64(n * 3_600_000.0)
        case "m", "min", "mins", "minute", "minutes": return round64(n * 60_000.0)
        case "s", "sec", "secs", "second", "seconds": return round64(n * 1000.0)
        case "tick", "ticks": return round64(n * 6000.0)
        default: return nil
        }
    }

    private static let clockRe = Re("([0-9]+):([0-9]{2})(?::([0-9]{2}))?")

    static func parseClockMs(_ t: String) -> Int64? {
        guard let m = clockRe.captures(t) else { return nil }
        let h: Int64, min: Int64, s: Int64
        if let third = m[3] {
            guard let a = Int64(m.s(1)), let b = Int64(m.s(2)), let c = Int64(String(third)) else { return nil }
            (h, min, s) = (a, b, c)
        } else {
            guard let a = Int64(m.s(1)), let b = Int64(m.s(2)) else { return nil }
            (h, min, s) = (0, a, b)
        }
        let ms = ((h * 60 + min) * 60 + s) * 1000
        return ms > 0 ? ms : nil
    }

    private static let refuseRe = Re("instant|permanent|unlimited|until(?-u:\\b)|special|varies|n/a|per tick|per level")
    private static let compRe = Re("([0-9]+(?:\\.[0-9]+)?)\\s*(hours?|hrs?|hr|minutes?|mins?|min|seconds?|secs?|sec|ticks?|h|m|s)(?-u:\\b)")
    private static let formulaRe = Re("(?-u:\\b)to(?-u:\\b)|@\\s*l[0-9]|@l[0-9]")

    /// The wiki's several duration forms, or `nil` for instant/permanent/absent.
    public static func parseDurationMs(_ text: String?) -> Int64? {
        guard let text else { return nil }
        if text.isEmpty { return nil }
        let t = JS.trim(text.lowercased())
        if t.isEmpty { return nil }
        if refuseRe.isMatch(t) { return nil }
        var comps: [Int64] = []
        for c in compRe.allCaptures(t) {
            let n = Double(c.s(1)) ?? Double.nan
            if let ms = unitMs(n, c.s(2)) { comps.append(ms) }
        }
        if comps.isEmpty { return parseClockMs(t) }
        if formulaRe.isMatch(t) { return comps.max() }
        return comps.reduce(Int64(0), &+)
    }
}
