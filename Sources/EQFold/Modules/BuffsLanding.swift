// The landing gate: what, if anything, does a landing sentence entitle the model to draw?
//
// Four cases, in order.
//
//   1. A named anchor wins. `You begin casting <S>.` names the spell and the rank, so a candidate
//      with one in window resolves to THAT CANDIDATE'S DB NAME. The rank is kept beside it as
//      `castName`; what it may not be is the spell's identity.
//   2. Several of your own casts sharing one sentence resolve to the most recent.
//   3. A Quick Buff burst admits the landing as yours but names no spell. Two narrowings then
//      apply: a candidate you have ever cast, then one you already have up. Failing both the row
//      stays a FAMILY, stating a duration only when every candidate agrees on one and on its
//      nature. A family mints nothing into the learner.
//   4. Nothing else. An unanchored landing produces nothing.
//
// The identity is the DB name and not the cast line's: the anchor and the candidate were matched
// under `spellKey`, so they are the same spell by construction.
// (fold/src/modules/buff_landing.rs)
import Foundation
import EQLog
import EQCompanionCore

/// A candidate spell carried by an ambiguous landing message.
public struct Candidate {
    public var name: String
    public var durationMs: Int64?
    public var illusion: Bool
    public init(name: String, durationMs: Int64?, illusion: Bool) {
        self.name = name; self.durationMs = durationMs; self.illusion = illusion
    }
}

/// What the gate admitted.
public struct AdmittedLanding {
    public var spell: String
    public var durationMs: Int64?
    public var illusion: Bool
    public var caster: String
    /// The ranked display name as the cast line spelled it, when a named anchor resolved this
    /// landing and it says something the DB name does not.
    public var castName: String?
    /// The LINE this instance is identified by, when it differs from the display name.
    public var lineKey: String?
    /// Present only for a family row — every spell the sentence could be.
    public var candidates: [String]?
}

public enum BuffLanding {
    /// The one duration every candidate agrees on, or nothing.
    public static func statedDuration(_ candidates: [Candidate]) -> Int64? {
        guard let first = candidates.first?.durationMs else { return nil }
        return candidates.allSatisfy { $0.durationMs == first } ? first : nil
    }

    private static func resolved(_ cand: Candidate, _ caster: String, _ cast: String?) -> AdmittedLanding {
        AdmittedLanding(
            spell: cand.name,
            durationMs: cand.durationMs,
            illusion: cand.illusion,
            caster: caster,
            castName: cast.flatMap { $0 != cand.name ? $0 : nil },
            lineKey: BuffsShapes.spellKey(cand.name),
            candidates: nil)
    }

    /// Cases 1 and 2: the candidate with a named anchor in window, most recently cast first. The
    /// recency tiebreak reads `lastCastTs` — the self-only ever-cast map — not the anchor's own ts.
    private static func namedLanding(_ cands: [Candidate], _ ts: Int64, _ anchors: CastAnchors) -> AdmittedLanding? {
        var best: AdmittedLanding?
        var bestTs: Int64 = -1
        for c in cands {
            guard let at = anchors.namedAnchorFor(c.name, ts) else { continue }
            let t = anchors.lastCastTs(c.name) ?? -1
            if t <= bestTs { continue }
            best = resolved(c, at.caster, at.display)
            bestTs = t
        }
        return best
    }

    /// Burst narrowing (a): the candidate you have EVER cast, most recent first.
    private static func everCastLanding(_ cands: [Candidate], _ caster: String, _ anchors: CastAnchors) -> AdmittedLanding? {
        var best: Candidate?
        var bestTs: Int64 = -1
        for c in cands {
            guard let t = anchors.lastCastTs(c.name) else { continue }
            if t <= bestTs { continue }
            best = c
            bestTs = t
        }
        return best.map { resolved($0, caster, nil) }
    }

    /// Burst narrowing (b): the candidate you already have up (EQ stacking keeps one per family).
    private static func activeLanding(_ cands: [Candidate], _ caster: String, _ hasActiveSpell: (String) -> Bool) -> AdmittedLanding? {
        cands.first { hasActiveSpell(BuffsShapes.spellKey($0.name)) }.map { resolved($0, caster, nil) }
    }

    /// A landing the burst admits but nobody can narrow: draw the family rather than nothing, but
    /// only while the ambiguity does not reach a claim. Every candidate must agree on NATURE and on
    /// one stated duration; disagree on either and the answer is nothing.
    private static func familyLanding(_ cands: [Candidate], _ caster: String, _ facts: SpellFacts) -> AdmittedLanding? {
        func natureOfCand(_ c: Candidate) -> Nature {
            facts.get(BuffsShapes.spellKey(c.name))?.nature ?? .unknown
        }
        let first = natureOfCand(cands[0])
        if cands.contains(where: { natureOfCand($0) != first }) { return nil }
        guard let durationMs = statedDuration(cands) else { return nil }
        // The de-dupe keeps the FIRST spelling of each name; the sort is over the deduped list.
        var names: [String] = []
        for c in cands where !names.contains(c.name) { names.append(c.name) }
        names.sort { compareNames($0, $1) < 0 }
        return AdmittedLanding(
            spell: names.joined(separator: " / "),
            durationMs: durationMs,
            illusion: cands.allSatisfy { $0.illusion },
            caster: caster,
            castName: nil,
            // Keyed on the alphabetically first candidate's LINE — safe only because the family was
            // admitted on unanimous nature and one agreed duration.
            lineKey: BuffsShapes.spellKey(names[0]),
            candidates: names)
    }

    /// Locale-style ordering over spell names, which are the ASCII strings spells.json holds — NOT
    /// codepoint order, which would sort every capitalized name ahead of every lowercase one.
    /// Case-insensitive-then-case-sensitive, as ICU's default collation gives; the goldens check it.
    public static func compareNames(_ a: String, _ b: String) -> Int {
        let ka = collateKey(a)
        let kb = collateKey(b)
        if ka != kb { return lexLess(ka, kb) ? -1 : 1 }
        if a == b { return 0 }
        return BuffsShapes.codepointLess(a, b) ? -1 : 1
    }

    /// The primary collation weight: letters and digits compared case-insensitively, everything
    /// else ignored — what ICU's default strength does with the "variable" characters.
    private static func collateKey(_ s: String) -> [UInt32] {
        var out: [UInt32] = []
        for ch in s.unicodeScalars where ch.properties.isAlphabetic || ch.properties.numericType != nil {
            for l in String(ch).lowercased().unicodeScalars { out.append(l.value) }
        }
        return out
    }

    private static func lexLess(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        var i = 0
        while i < a.count && i < b.count {
            if a[i] != b[i] { return a[i] < b[i] }
            i += 1
        }
        return a.count < b.count
    }

    /// The gate. See this file's header for the four cases, in order.
    public static func admitLanding(_ cands: [Candidate], _ ts: Int64, _ anchors: CastAnchors,
                                    _ facts: SpellFacts, _ hasActiveSpell: (String) -> Bool) -> AdmittedLanding? {
        if cands.isEmpty { return nil }
        if let named = namedLanding(cands, ts, anchors) { return named }
        // `attribute` reports `unnamed` for every candidate under a burst, so asking with the first
        // one is asking about the burst.
        guard let burst = anchors.attribute(cands[0].name, ts) else { return nil }
        if !burst.unnamed { return nil }
        if cands.count == 1 { return resolved(cands[0], burst.caster, nil) }
        return everCastLanding(cands, burst.caster, anchors)
            ?? activeLanding(cands, burst.caster, hasActiveSpell)
            ?? familyLanding(cands, burst.caster, facts)
    }
}
