// The observed-message overlay, seeded with the committed baseline and nothing else.
//
// A parser needs it because each verified landing line is registered as a spell's `msgCastOnYou`,
// which is what turns that line into a `buffApply` rather than an `unknown`.
//
// Only the baseline is seeded: the user's own mined overlay lives in userData, and a golden recorded
// against a machine-local file would not be a fact about the log.
//
// The tie-break is codepoint order because `localeCompare` answers from ICU and can differ between
// hosts. UTF-8 bytewise order is exactly codepoint order, so it is the comparator.
// (eqlog/src/spelldb/overlay.rs)
import Foundation
import EQData

public enum SpellDbOverlay {
    struct BaselineFile: Decodable { var messages: [BaselineMessage] }
    struct BaselineMessage: Decodable {
        var text: String
        var role: String
        var spells: [BaselineSpell]
    }
    struct BaselineSpell: Decodable {
        var spell: String
        var count: Int64
    }

    /// One accumulated message: the text, its role, and per-canonical-spell counts in insertion order.
    final class Record {
        var text: String
        var role: String
        /// (canonical key, display, count)
        var bySpell: [(String, String, Int64)] = []
        init(text: String, role: String) { self.text = text; self.role = role }
    }

    enum Verdict: Int {
        case contradicts = 0
        case verified = 1
        case shared = 2
        case unknown = 3
        var rank: Int { rawValue }
    }

    /// Minimum observations before a message earns a non-UNKNOWN verdict.
    static let minObservations: Int64 = 2

    /// The landing corrections, as `(message text, spell display, contradicted spell)`. Each text
    /// appears at most once, so the order cannot change what the corrections produce; it is still the
    /// app's sorted order so a reader diffing the two sides sees the same sequence.
    public static func deriveLandingCorrections(_ db: SpellDb) -> [(String, String, String?)] {
        guard let json = EQData.text("messageOverlay.baseline.json") else {
            fatalError("messageOverlay.baseline.json is not shipped")
        }
        guard let file = try? JSONDecoder().decode(BaselineFile.self, from: Data(json.utf8)) else {
            fatalError("messageOverlay.baseline.json is not readable")
        }

        // Merge and aggregate are the same accumulation with a single source, so it is done once.
        var order: [Record] = []
        var at: [String: Int] = [:]
        for m in file.messages {
            let idx: Int
            if let i = at[m.text] {
                idx = i
            } else {
                at[m.text] = order.count
                order.append(Record(text: m.text, role: m.role))
                idx = order.count - 1
            }
            let rec = order[idx]
            for sp in m.spells {
                let key = Names.dbCanonKey(sp.spell)
                if let e = rec.bySpell.firstIndex(where: { $0.0 == key }) {
                    rec.bySpell[e].2 += sp.count
                } else {
                    rec.bySpell.append((key, sp.spell, sp.count))
                }
            }
        }

        struct Built {
            var text: String
            var role: String
            var verdict: Verdict
            var topSpell: String
            var conflictSpell: String?
            var total: Int64
        }
        var messages: [Built] = []
        messages.reserveCapacity(order.count)
        for rec in order {
            var spells = rec.bySpell.map { ($0.1, $0.2) }
            spells = Rust.stableSorted(spells) { a, b in
                if a.1 != b.1 { return b.1 < a.1 }
                return Rust.bytesLess(a.0, b.0)
            }
            let total = spells.reduce(Int64(0)) { $0 &+ $1.1 }
            let (verdict, conflict) = verdictFor(db, rec, total)
            messages.append(Built(text: rec.text, role: rec.role, verdict: verdict,
                                  topSpell: spells.first?.0 ?? "", conflictSpell: conflict,
                                  total: total))
        }
        messages = Rust.stableSorted(messages) { a, b in
            if a.verdict.rank != b.verdict.rank { return a.verdict.rank < b.verdict.rank }
            if a.total != b.total { return b.total < a.total }
            return Rust.bytesLess(a.text, b.text)
        }

        // `looksCastOnOther` walks the whole keyed table for every message; the table cannot change
        // here, so its suffixes are read once.
        let otherTails = otherSuffixTails(db)
        var out: [(String, String, String?)] = []
        for m in messages {
            if m.role != "landing" { continue }
            if looksCastOnOther(otherTails, m.text) { continue }
            switch m.verdict {
            case .verified: out.append((m.text, m.topSpell, nil))
            case .contradicts:
                if let conflict = m.conflictSpell { out.append((m.text, m.topSpell, conflict)) }
            default: break
            }
        }
        return out
    }

    /// Reads the first spell off the unsorted insertion order, which only matters when there is one
    /// spell — the only branch that reaches it.
    static func verdictFor(_ db: SpellDb, _ rec: Record, _ total: Int64) -> (Verdict, String?) {
        if rec.bySpell.count >= 2 { return (.shared, nil) }
        if total < minObservations { return (.unknown, nil) }
        guard let first = rec.bySpell.first else { return (.verified, nil) }
        let display = first.1
        guard let dbSpell = db.byKeyGet(Names.dbCanonKey(display)) else { return (.verified, nil) }
        if rec.role == "landing" {
            let you = dbSpell.msgCastOnYou
            if you == rec.text { return (.verified, nil) }
            if let msg = dbSpell.msgCastOnOther, let suffix = castOnOtherSuffix(msg),
               messageMatchesOtherSuffix(rec.text, suffix) {
                return (.verified, nil)
            }
            return you != nil ? (.contradicts, display) : (.verified, nil)
        }
        // The wears-off role.
        if let wiki = dbSpell.msgWearsOff, wiki != rec.text { return (.contradicts, display) }
        return (.verified, nil)
    }

    /// Every cast-on-other tail the keyed table carries, in `byKeyValues` order.
    static func otherSuffixTails(_ db: SpellDb) -> [[UInt8]] {
        var seen: Set<String> = []
        var out: [[UInt8]] = []
        for s in db.byKeyValues() {
            guard let msg = s.msgCastOnOther, let suffix = castOnOtherSuffix(msg) else { continue }
            let tail = suffix.hasPrefix("'s") ? suffix : " " + suffix
            if seen.insert(tail).inserted { out.append(Array(tail.utf8)) }
        }
        return out
    }

    /// True when a line ends with any cast-on-other suffix, in which case registering it as a
    /// self-landing message would fire a self `buffApply` for a debuff on a mob.
    static func looksCastOnOther(_ tails: [[UInt8]], _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        for tail in tails where SpellDb.hasSuffixBytes(bytes, tail) && bytes.count > tail.count {
            return true
        }
        return false
    }
}

/// The same tail test the DB's own matcher makes.
public func messageMatchesOtherSuffix(_ text: String, _ suffix: String) -> Bool {
    let tail = suffix.hasPrefix("'s") ? suffix : " " + suffix
    let t = Array(text.utf8), s = Array(tail.utf8)
    return SpellDb.hasSuffixBytes(t, s) && t.count > s.count
}
