// Corrections to the wiki's stated mob positions.
//
// `mobs.json` carries what each wiki page's `|location` field says, verbatim - and a few of those
// pages are simply wrong (a transposed digit puts a Lower Guk ghoul 500 units outside the zone).
// A wrong pin is worse than no pin: the map's whole promise is that a mark means the mob is there.
//
// So `mobLocFixes.json` overrides those rows, under two rules that keep this from becoming a
// private second corpus:
//
//   1. EVERY FIX IS GUARDED. It states `was` - the position the shipped corpus is expected to
//      carry - and applies only while that is what the corpus still says. When a re-scrape brings
//      down a different value (the wiki fixed it, or restated it), the fix retires itself and the
//      fresh data wins. A correction can never outlive the error it corrects.
//   2. EVERY FIX IS CITED. `why` names the evidence, and the corrected row is MARKED (`locFix`)
//      so the pane can say the position is ours rather than the wiki's.
//
// A fix replaces the whole `loc` array, because a page that stated one position badly may need
// two, or none.
import Foundation
import EQCompanionCore

enum MobLocFixes {
    struct Fix {
        /// The replacement `loc` array, in the corpus's own shape.
        var loc: [JSONValue]
        /// The position the corpus must still state for this fix to apply. Absent = unguarded.
        var was: (ns: Double, ew: Double)?
        var why: String
    }

    /// Page title → fix. Page title, not name: several pages share a mob name.
    static func parse(_ file: JSONValue) -> [String: Fix] {
        var out: [String: Fix] = [:]
        for f in file["fixes"].array ?? [] {
            guard let page = f["page"].string, let loc = f["loc"].array else { continue }
            let w = f["was"]
            let was: (ns: Double, ew: Double)? =
                if let ns = w["ns"].double, let ew = w["ew"].double { (ns, ew) } else { nil }
            out[page] = Fix(loc: loc, was: was, why: f["why"].string ?? "")
        }
        return out
    }

    /// True when the corpus still states the position this fix was written against.
    static func guardHolds(_ fix: Fix, corpus loc: [JSONValue]) -> Bool {
        guard let was = fix.was else { return true }
        return loc.contains { $0["ns"].double == was.ns && $0["ew"].double == was.ew }
    }
}
