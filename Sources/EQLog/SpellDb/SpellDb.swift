// The spell database the parser's output depends on. The `candidates` list a `buffApply` carries is
// this table, so a golden cannot be matched without reproducing the load path exactly:
//
//   spells.json → removals → derived durations → corrections → placeholder blanking → build
//               → overlay corrections mined from the committed baseline
//
// The committed JSON ships in `EQData`, so there is exactly one copy and a re-scrape reaches both
// readers at once. The era join is the one app pass absent here: it writes exactly one field, which
// no table below indexes and no classifier reads.
// (eqlog/src/spelldb/mod.rs)
import Foundation
import EQData

/// One row of `spells.json`: the fields the parser's output can depend on, and no others. The
/// scrape carries more that no classifier and no table below reads; leaving them out of the struct
/// is what makes that claim checkable rather than stated.
public struct SpellEntry: Sendable, Decodable {
    public var name: String
    public var durationText: String?
    public var durationMs: Int64?
    public var targetType: String?
    public var spellType: String?
    public var classes: String?
    public var msgCastOnYou: String?
    public var msgCastOnOther: String?
    public var msgWearsOff: String?
    public var illusion: Bool
    public var effects: [String]?

    enum CodingKeys: String, CodingKey {
        case name, durationText, durationMs, targetType, spellType, classes
        case msgCastOnYou, msgCastOnOther, msgWearsOff, illusion, effects
    }

    /// Aliases for the stub's spelling of the three message fields.
    public var castOnYou: String? { msgCastOnYou }
    public var castOnOther: String? { msgCastOnOther }
    public var wearsOff: String? { msgWearsOff }
}

/// One cast-on-other suffix, precompiled. `index` is the entry's position in the insertion-ordered
/// suffix table and is the only thing that decides precedence when a line ends with two known
/// suffixes.
public struct SuffixEntry: Sendable {
    public var tail: String
    public var index: Int
    public var cands: [Int]
    /// `tail` as UTF-8, so the ends-with test is Rust's byte test rather than a grapheme one.
    let tailBytes: [UInt8]

    init(tail: String, index: Int, cands: [Int]) {
        self.tail = tail
        self.index = index
        self.cands = cands
        self.tailBytes = Array(tail.utf8)
    }

    /// Aliases for the stub's spelling.
    public var suffix: String { tail }
    public var indices: [Int] { cands }
}

public final class SpellDb: @unchecked Sendable {
    public private(set) var spells: [SpellEntry]
    /// Canonical name to the first entry with it. The insertion order is kept because a reader walks it.
    var byKey: [String: Int]
    var byKeyOrder: [Int]
    var castOnYouMap: [String: [Int]]
    var wearsOffMap: [String: [Int]]
    var castOnOtherByLastWord: [String: [SuffixEntry]]
    var castOnOtherUnkeyed: [SuffixEntry]
    /// The derived charm roster, keyed by `spellCanonKey`.
    var charmKeys: Set<String>

    init(spells: [SpellEntry],
         byKey: [String: Int],
         byKeyOrder: [Int],
         castOnYou: [String: [Int]],
         wearsOff: [String: [Int]],
         castOnOtherByLastWord: [String: [SuffixEntry]],
         castOnOtherUnkeyed: [SuffixEntry],
         charmKeys: Set<String>) {
        self.spells = spells
        self.byKey = byKey
        self.byKeyOrder = byKeyOrder
        self.castOnYouMap = castOnYou
        self.wearsOffMap = wearsOff
        self.castOnOtherByLastWord = castOnOtherByLastWord
        self.castOnOtherUnkeyed = castOnOtherUnkeyed
        self.charmKeys = charmKeys
    }

    /// An empty catalog, for a caller that wants the API without the data.
    public convenience init() {
        self.init(spells: [], byKey: [:], byKeyOrder: [], castOnYou: [:], wearsOff: [:],
                  castOnOtherByLastWord: [:], castOnOtherUnkeyed: [], charmKeys: [])
    }

    /// The process's one spell database. `load()` is a pure function of committed bytes, so a second
    /// `Parser` in the same process cannot observe this as different from the first.
    public static func shared() -> SpellDb { sharedDb }
    private static let sharedDb: SpellDb = SpellDb.load()

    public func entry(_ i: Int) -> SpellEntry? {
        i >= 0 && i < spells.count ? spells[i] : nil
    }

    public func castOnYou(_ text: String) -> [Int]? { castOnYouMap[text] }

    public func wearsOff(_ text: String) -> [Int]? { wearsOffMap[text] }

    /// Every canonical key the database carries. Exposed as the keys rather than as a `has()` so a
    /// fold can take an owned set and borrow nothing from the parser.
    public func keys() -> [String] { Array(byKey.keys) }

    /// True when the derived roster — or, for a name the catalog does not carry, the stem roster —
    /// calls this spell a charm.
    public func isCharmSpell(_ name: String) -> Bool {
        charmKeys.contains(Names.spellCanonKey(name)) || Stems.charmStemsTest(name)
    }

    /// One bucket lookup, then table order within it, then the (measured-empty) unkeyable list
    /// merged in by index.
    public func matchCastOnOther(_ text: String) -> (SuffixEntry, String)? {
        let lastWord: String
        if let at = text.lastIndex(of: " ") {
            lastWord = String(text[text.index(after: at)...])
        } else {
            lastWord = text
        }
        let bucket = castOnOtherByLastWord[lastWord] ?? []
        if bucket.isEmpty && castOnOtherUnkeyed.isEmpty { return nil }
        let bytes = Array(text.utf8)
        let keyed = SpellDb.firstSuffixMatch(bytes, bucket)
        let unkeyed = castOnOtherUnkeyed.isEmpty ? nil : SpellDb.firstSuffixMatch(bytes, castOnOtherUnkeyed)
        switch (keyed, unkeyed) {
        case (let k, nil): return k
        case (nil, let u): return u
        case (.some(let k), .some(let u)): return u.0.index < k.0.index ? u : k
        }
    }

    /// The two rejections are as load-bearing as the match.
    static func firstSuffixMatch(_ bytes: [UInt8], _ list: [SuffixEntry]) -> (SuffixEntry, String)? {
        for entry in list {
            if hasSuffixBytes(bytes, entry.tailBytes), bytes.count > entry.tailBytes.count {
                let head = bytes[0..<(bytes.count - entry.tailBytes.count)]
                let target = JS.trim(String(decoding: head, as: UTF8.self))
                // The 60-character cap is a JS length: UTF-16 code units, not bytes and not chars.
                if !target.isEmpty, target.utf16.count <= 60 { return (entry, target) }
            }
        }
        return nil
    }

    @inline(__always) static func hasSuffixBytes(_ text: [UInt8], _ tail: [UInt8]) -> Bool {
        if text.count < tail.count { return false }
        let off = text.count - tail.count
        for i in 0..<tail.count where text[off + i] != tail[i] { return false }
        return true
    }

    /// The keyed entries in insertion order. The fold walks this and projects the whole table into
    /// an owned record at construction, rather than borrowing the parser.
    public func byKeyValues() -> [SpellEntry] { byKeyOrder.map { spells[$0] } }

    public func byKeyGet(_ key: String) -> SpellEntry? { byKey[key].map { spells[$0] } }

    /// The keyed entries as (canonical key, entry) pairs. Handing out the pairs rather than a
    /// `has()`/`get()` is what lets the resist fold build its projection in one pass; the key is
    /// `dbCanonKey`'s, which is the spelling a lookup has to be made with.
    public func byKeyEntries() -> [(String, SpellEntry)] { byKey.map { ($0.key, spells[$0.value]) } }
}

// MARK: - The load chain

extension SpellDb {
    /// The whole load chain, once.
    public static func load() -> SpellDb {
        guard let json = EQData.text("spells.json") else { fatalError("spells.json is not shipped") }
        guard let file = try? JSONDecoder().decode(SpellDbFile.self, from: Data(json.utf8)) else {
            fatalError("spells.json is not readable")
        }
        let sidecar = SpellDbPasses.sidecar()
        // Removals first: what the game does not have at all.
        var spells = SpellDbPasses.applyRemovals(file.spells, sidecar.removals)
        SpellDbPasses.applyDerivedDurations(&spells)
        SpellDbPasses.applyCorrections(&spells, sidecar.corrections)
        SpellDbPasses.applyPlaceholderMessages(&spells)
        let db = build(spells)
        let corrections = SpellDbOverlay.deriveLandingCorrections(db)
        applyOverlayCorrections(db, corrections)
        return db
    }

    struct SpellDbFile: Decodable { var spells: [SpellEntry] }

    /// The four tables, plus the last-word index over the fourth.
    static func build(_ spells: [SpellEntry]) -> SpellDb {
        var byKey: [String: Int] = [:]
        var byKeyOrder: [Int] = []
        var castOnYou: [String: [Int]] = [:]
        var wearsOff: [String: [Int]] = [:]
        // Insertion-ordered, because an entry's position in this table is its precedence.
        var suffixOrder: [(String, [Int])] = []
        var suffixAt: [String: Int] = [:]
        // `dbCanonKey` is a regex fold; the same name is asked for many times per build.
        var canon: [Int: String] = [:]
        func key(_ i: Int) -> String {
            if let k = canon[i] { return k }
            let k = Names.dbCanonKey(spells[i].name)
            canon[i] = k
            return k
        }

        for (i, s) in spells.enumerated() {
            // The first row per canonical name wins.
            if byKey[key(i)] == nil {
                byKey[key(i)] = i
                byKeyOrder.append(i)
            }
            if let msg = s.msgCastOnYou { pushCandidateMap(&castOnYou, msg, i, key) }
            if let msg = s.msgWearsOff { pushCandidateMap(&wearsOff, msg, i, key) }
            if let msg = s.msgCastOnOther, let suf = castOnOtherSuffix(msg) {
                if let at = suffixAt[suf] {
                    pushCandidateVec(&suffixOrder[at].1, i, key)
                } else {
                    suffixAt[suf] = suffixOrder.count
                    suffixOrder.append((suf, [i]))
                }
            }
        }

        var byLastWord: [String: [SuffixEntry]] = [:]
        var unkeyed: [SuffixEntry] = []
        for (index, pair) in suffixOrder.enumerated() {
            let entry = SuffixEntry(tail: matchTail(pair.0), index: index, cands: pair.1)
            switch lastWordKey(pair.0) {
            case nil: unkeyed.append(entry)
            case .some(let k): byLastWord[k, default: []].append(entry)
            }
        }

        return SpellDb(spells: spells, byKey: byKey, byKeyOrder: byKeyOrder,
                       castOnYou: castOnYou, wearsOff: wearsOff,
                       castOnOtherByLastWord: byLastWord, castOnOtherUnkeyed: unkeyed,
                       charmKeys: charmRoster(spells))
    }

    /// De-dupe rank variants of the same base spell, keeping the first.
    static func pushCandidateMap(_ map: inout [String: [Int]], _ msg: String, _ i: Int,
                                 _ key: (Int) -> String) {
        if var list = map[msg] {
            pushCandidateVec(&list, i, key)
            map[msg] = list
        } else {
            map[msg] = [i]
        }
    }

    static func pushCandidateVec(_ list: inout [Int], _ i: Int, _ key: (Int) -> String) {
        let k = key(i)
        if !list.contains(where: { key($0) == k }) { list.append(i) }
    }

    /// An anchored read of the wiki's own effect list. `targetType: 'Self'` rows are excluded.
    static func charmRoster(_ spells: [SpellEntry]) -> Set<String> {
        var out: Set<String> = []
        for s in spells {
            let charms = (s.effects ?? []).contains { Stems.classifyEffectLineIsCharm(JS.trim($0)) }
            if !charms { continue }
            if s.targetType == "Self" { continue }
            out.insert(Names.spellCanonKey(s.name))
        }
        return out
    }

    /// The effective DB: spells.json plus the overlay, with the overlay winning.
    static func applyOverlayCorrections(_ db: SpellDb, _ corrections: [(String, String, String?)]) {
        for (text, spellName, contradicts) in corrections {
            guard let idx = db.byKey[Names.dbCanonKey(spellName)] else { continue }
            // A cast-on-you landing message is a beneficial-buff signal, so a correction pointing at
            // a Detrimental spell is a mining false positive and never overrides the DB.
            if db.spells[idx].spellType == "Detrimental" { continue }
            // One write, two reasons: a wiki contradiction overrides the message's candidates, and a
            // message the DB never had fills the gap.
            let existing = db.castOnYouMap[text]
            if contradicts != nil || existing == nil {
                db.castOnYouMap[text] = [idx]
            } else {
                // The DB maps this text to other spells too — add ours as a candidate.
                let k = Names.dbCanonKey(db.spells[idx].name)
                let already = existing!.contains { Names.dbCanonKey(db.spells[$0].name) == k }
                if !already { db.castOnYouMap[text]!.append(idx) }
            }
        }
    }
}

// MARK: - Suffix helpers

private let someoneSpaced = Re("(?i)^Someone\(JS.S)+'s(?-u:\\b)(.*)$")
private let someonePoss = Re("(?i)^Someone's(?-u:\\b)(.*)$")
private let someoneLead = Re("(?i)^Someone\(JS.S)+(.*)$")

/// Strip the wiki's "Someone" subject, keeping a possessive tail.
public func castOnOtherSuffix(_ msg: String) -> String? {
    let m = JS.trim(msg)
    if let c = someoneSpaced.captures(m) { return JS.trim("'s" + c.s(1)) }
    if let c = someonePoss.captures(m) { return JS.trim("'s" + c.s(1)) }
    if let c = someoneLead.captures(m) { return JS.trim(c.s(1)) }
    return nil
}

/// What a log line must end with for a suffix to match.
private func matchTail(_ suffix: String) -> String {
    suffix.hasPrefix("'s") ? suffix : " " + suffix
}

/// The bucket key for a suffix: its last word, or nothing for a bare possessive tail.
private func lastWordKey(_ suffix: String) -> String? {
    if let at = suffix.lastIndex(of: " ") { return String(suffix[suffix.index(after: at)...]) }
    return suffix.hasPrefix("'s") ? nil : suffix
}
