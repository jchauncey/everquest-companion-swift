// Fight search: the scoring half of `combat.searchFights` (engined/src/search.rs). The corpus half is
// the combat engine's `fightSummaries`, one call away.
//
// The ranking lives in this target and not in EQFold because the equivalence oracle compares what a
// fold PUBLISHES; a scorer over published rows is not part of that claim, and putting it there would
// put oracle-uncovered code inside the target whose value is that the oracle covers it.
//
// Edit distance rather than anything semantic: the corpus is short proper nouns and the queries are
// typo'd lookups, which is the one shape character-level distance is strictly better at. The rules
// must match the app's exactly — two search boxes over one corpus that rank differently is the
// defect this shared scoring exists to prevent.
//
// The one place the languages could drift is `tokenize`. JavaScript's `toLowerCase` is Unicode full
// case folding and this uses Swift's, which is the same algorithm for every character the class
// `[a-z0-9]` can survive; every character it cannot survive is dropped by the class in all three
// languages. The claim is over the class, not over the whole of Unicode casing.

import Foundation
import EQCompanionCore

public enum Search {
    /// One ranked fight, as this module hands it back. `FoldSink` widens it into the wire's
    /// `FightHit` beside the corpus count, which is the number this scorer never sees.
    public struct Hit {
        /// The summary, exactly as the fold published it.
        public var summary: JSONValue
        /// 0..1 relevance.
        public var score: Double
    }

    /// Per-token match scores, in strict descending order of confidence. The gaps are wide on
    /// purpose: an exact token match must always outrank a prefix, a prefix a substring, and any of
    /// those a typo correction, no matter how the mean across tokens shakes out.
    static let scoreExact = 1.0
    static let scorePrefix = 0.85
    static let scoreSubstring = 0.7
    /// Ceiling for a typo (edit-distance) match; scaled down by how many edits it took.
    static let scoreFuzzy = 0.6

    /// Shortest token either side may be and still be eligible for a typo match.
    ///
    /// One edit on a 2-letter token reaches most of the alphabet: measured, without this `wan gohl`
    /// returned "an urd ghoul wizard" beside the wan ghoul knight it was aimed at. Both sides are
    /// checked, because the budget below keys on the LONGER token and a 2-letter haystack token
    /// would otherwise inherit a long query's generous budget.
    static let minFuzzyLen = 3

    /// Edit budget for a typo match, keyed on the LONGER of the two tokens.
    ///
    /// The longer one, not the query's, is load-bearing: `gohl` → `ghoul` is two edits and the query
    /// token is four characters, so a query-length budget would reject exactly the case the user
    /// asked for.
    static func editBudget(_ longest: Int) -> Int {
        switch longest {
        case 0...2: return 0
        case 3...4: return 1
        default: return 2
        }
    }

    /// Lowercased alphanumeric tokens. EQ names carry backticks, apostrophes, `(3)` instance suffixes
    /// and `+N` others-suffixes; all of that is punctuation to a search box.
    public static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var current: [UInt8] = []
        for byte in text.lowercased().utf8 {
            let alnum = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            if alnum {
                current.append(byte)
            } else if !current.isEmpty {
                out.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { out.append(String(decoding: current, as: UTF8.self)) }
        return out
    }

    /// Restricted Damerau-Levenshtein (optimal string alignment) distance, aborted once it provably
    /// exceeds `max`. Answers `max + 1` for "further apart than we care about", so the caller never
    /// pays for a full matrix over two unrelated words.
    ///
    /// "Restricted" means a transposed pair is one edit but may not be edited again afterwards — the
    /// standard OSA variant, and the right one here because it makes `gohul`→`ghoul` and
    /// `freeprot`→`freeport` one edit each. Where it diverges from unrestricted Damerau needs three
    /// or more overlapping transpositions, already past any budget above.
    ///
    /// Bytes, not characters, and that is exact rather than approximate: both sides are `[a-z0-9]`
    /// tokens out of `tokenize`, so every character is one ASCII byte.
    public static func damerauLevenshtein(_ a: String, _ b: String, _ max: Int) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if a == b { return 0 }
        if abs(a.count - b.count) > max { return max + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        // Three rolling rows — prev-prev is what makes the transposition step possible.
        var prev2 = [Int](repeating: 0, count: b.count + 1)
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] != b[j - 1] ? 1 : 0
                var v = min(cur[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    v = min(v, prev2[j - 2] + 1)
                }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            // Every remaining path goes through this row, so a row whose best cell already exceeds
            // the budget can never come back under it.
            if rowMin > max { return max + 1 }
            swap(&prev2, &prev)
            swap(&prev, &cur)
        }
        let d = prev[b.count]
        return d > max ? max + 1 : d
    }

    /// Best score for ONE query token against ONE haystack token. `0` means no match at all, which
    /// is what excludes a record — see `scoreQuery`'s coverage rule.
    static func tokenScore(_ q: String, _ h: String) -> Double {
        if q == h { return scoreExact }
        if h.hasPrefix(q) { return scorePrefix }
        if !q.isEmpty, h.range(of: q) != nil { return scoreSubstring }
        let qLen = q.utf8.count, hLen = h.utf8.count
        if qLen < minFuzzyLen || hLen < minFuzzyLen { return 0 }
        let longest = Swift.max(qLen, hLen)
        let budget = editBudget(longest)
        if budget == 0 { return 0 }
        let d = damerauLevenshtein(q, h, budget)
        if d > budget { return 0 }
        // Length-normalized: the same number of edits is a weaker signal on a short token than on a
        // long one (`wan`→`can` is one edit across a third of the word).
        return scoreFuzzy * (1.0 - Double(d) / Double(longest))
    }

    /// Best score for one query token across a whole haystack. Short-circuits on an exact hit.
    static func bestTokenScore(_ q: String, _ hay: [String]) -> Double {
        var best = 0.0
        for h in hay {
            let s = tokenScore(q, h)
            if s > best {
                best = s
                if abs(best - scoreExact) < .ulpOfOne { break }
            }
        }
        return best
    }

    /// Score one record's haystack tokens against an already-tokenized query. `nil` is EXCLUDED,
    /// which is not the same as scored zero.
    ///
    /// Each query token takes its best score across the haystack (exact > prefix > substring >
    /// bounded Damerau-Levenshtein), and the record is excluded unless every query token matched
    /// something above zero — `gohul knigt` must not surface every ghoul in the corpus because one
    /// word landed. The score is the mean token score.
    public static func scoreQuery(_ query: [String], _ hay: [String]) -> Double? {
        if query.isEmpty || hay.isEmpty { return nil }
        var sum = 0.0
        for q in query {
            let best = bestTokenScore(q, hay)
            if best == 0 { return nil }
            sum += best
        }
        return sum / Double(query.count)
    }

    /// Search a corpus of fight-summary JSON by name + zone.
    ///
    /// Order: score desc, then recency (newer `startTs` first), then `id`, so the ranking never
    /// depends on the corpus's arrival order. The last term is load-bearing — two fights against the
    /// same mob in the same zone score identically by construction, and a search box whose rows
    /// swapped between keystrokes would be the shuffled-window defect the view layer's total sort
    /// exists to prevent.
    ///
    /// An empty or whitespace-only query returns no hits rather than everything: the UI shows its
    /// ordinary browse list in that state, and the whole corpus would make the empty box the most
    /// expensive keystroke of all.
    ///
    /// No index, on purpose. A linear scan, measured in the Rust at 1.71 ms for the worst real query
    /// over 2,080 fights and 7.66 ms cold over a synthetic 5,000 where every fight survives the
    /// coverage rule — inside the per-keystroke budget, so an inverted index would be complexity
    /// bought with nothing.
    public static func search(_ corpus: [JSONValue], _ query: String, _ limit: Int) -> [Hit] {
        let terms = tokenize(query)
        if terms.isEmpty { return [] }
        var hits: [(Hit, Int)] = []
        for (i, summary) in corpus.enumerated() {
            guard let score = scoreQuery(terms, haystack(summary)) else { continue }
            hits.append((Hit(summary: summary, score: score), i))
        }
        // The corpus index is the last term, standing in for the stability of Rust's `sort_by`:
        // Swift's sort is not stable, and two summaries can tie on all three ranking terms.
        hits.sort { a, b in
            if a.0.score != b.0.score { return a.0.score > b.0.score }
            let (ta, tb) = (startTs(a.0.summary), startTs(b.0.summary))
            if ta != tb { return tb < ta }
            let (ia, ib) = (idOf(a.0.summary), idOf(b.0.summary))
            if ia != ib { return ia < ib }
            return a.1 < b.1
        }
        return hits.prefix(limit).map(\.0)
    }

    /// The tokens one summary is matched against: the name, plus the zone when it has one.
    ///
    /// No memoization, unlike the app's: the corpus is rebuilt per call from `fightSummaries`, so
    /// there is no stable object to key a cache on and it would never hit.
    static func haystack(_ summary: JSONValue) -> [String] {
        let name = summary["name"].string ?? ""
        if let zone = summary["zone"].string, !zone.isEmpty { return tokenize("\(name) \(zone)") }
        return tokenize(name)
    }

    static func startTs(_ summary: JSONValue) -> Int64 { summary["startTs"].int64 ?? 0 }

    static func idOf(_ summary: JSONValue) -> String { summary["id"].string ?? "" }
}
