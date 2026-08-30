// Cast-anchored attribution — the one cast history both the buffs and the crowd-control modules
// share. Pure apart from the times it is told about; no events, no clock.
//
// No bar without a cast line: EQ prints every landing sentence as a broadcast naming no caster, so
// the cast line is the only thing separating your work from a stranger's.
//
// Three anchor forms. `You begin casting <S>.` and `<Name> begins casting <S>.` name the spell —
// only the first carries a RANK. `You activate Quick Buff.` names a window rather than a spell, so
// a landing it admits stays a family.
// (fold/src/modules/buff_anchors.rs)
import Foundation
import EQLog
import EQCompanionCore

/// One remembered cast line. `display` is the ranked name exactly as the log spelled it; the map is
/// keyed by the rank-STRIPPED line, so a rank upgrade replaces its predecessor. `rankChanged`
/// records that two ranks of one line were cast in the same window.
struct CastAnchor {
    var display: String
    var ts: Int64
    var caster: String
    var rankChanged: Bool
}

/// What admitted a landing, and by whom — the caller needs the caster to key the learner.
public struct CastAttribution {
    public var caster: String
    /// The ranked display name from the cast line, when the anchor named a spell.
    public var display: String?
    /// When the line that admitted this landing was printed — the cast's own ts, or the Quick Buff
    /// activation's for an `unnamed` one.
    public var ts: Int64
    /// True when the anchor cannot say which rank landed (two ranks inside one window).
    public var rankChanged: Bool
    /// True when the anchor named no spell at all (a Quick Buff burst) — so it cannot narrow.
    public var unnamed: Bool
}

/// The landing sentence carries no rank, so two ranks of one line in flight at once leaves nothing
/// that can say which landed. The flag refuses the SAMPLE; the row is still drawn.
private func isRankChange(_ prev: CastAnchor?, _ display: String, _ ts: Int64, _ caster: String) -> Bool {
    guard let p = prev else { return false }
    return p.caster == caster && p.display != display && ts - p.ts <= BuffsShapes.ownCastWindowMs
}

public final class CastAnchors {
    /// Newest anchor per rank-STRIPPED line key. Cleared by a fizzle/interrupt.
    private var byLine = JSMap<CastAnchor>()
    /// Newest ts this line was ever cast, whatever became of the cast — a different question from
    /// the anchor above. A fizzle retracts the ANCHOR but not the knowledge that the spell is in
    /// your book, which is what narrows a Quick Buff burst.
    private var everCast = JSMap<Int64>()
    /// ts of the last `You activate Quick Buff.` — the spell-less self anchor.
    private var quickBuffTs: Int64 = 0
    /// The externals allowlist — caster KEYS, not display spellings. Empty by default. Not cleared
    /// by `reset`, because it is a user preference rather than log state.
    private var externals = Set<String>()

    public init() {}

    public func reset() {
        byLine.clear()
        everCast.clear()
        quickBuffTs = 0
    }

    /// `You begin casting <S>.` / `You begin singing <S>.` — the self anchor.
    public func noteSelfCast(_ spell: String, _ ts: Int64) {
        note(spell, ts, BuffsShapes.selfCaster)
    }

    /// Replace the externals allowlist, whole. A name added mid-session anchors the very next cast;
    /// nothing already landed is retro-admitted, which is why `byLine` is untouched.
    public func setTrust(_ externals: [String]) {
        self.externals = Set(externals.map { BuffsShapes.casterKey($0) })
    }

    /// Trusted against this world's allowlist: you, plus whoever the user named.
    private func trusted(_ caster: String) -> Bool {
        BuffsShapes.casterTrusted(caster) || externals.contains(BuffsShapes.casterKey(caster))
    }

    /// `<Name> begins casting <S>.` — recorded ONLY for a caster on the externals allowlist.
    public func noteOtherCast(_ caster: String, _ spell: String, _ ts: Int64) {
        if !trusted(caster) { return }
        note(spell, ts, BuffsShapes.casterKey(caster))
    }

    private func note(_ spell: String, _ ts: Int64, _ caster: String) {
        let key = BuffsShapes.spellKey(spell)
        let display = JS.trim(spell)
        let rankChanged = isRankChange(byLine[key], display, ts, caster)
        let isSelf = caster == BuffsShapes.selfCaster
        byLine.insert(key, CastAnchor(display: display, ts: ts, caster: caster, rankChanged: rankChanged))
        // Self only: an external's cast says nothing about what is in YOUR spellbook.
        if isSelf, everCast[key].map({ ts > $0 }) ?? true {
            everCast.insert(key, ts)
        }
    }

    /// `You activate Quick Buff.` — a self anchor that names a window rather than a spell.
    public func noteQuickBuff(_ ts: Int64) { quickBuffTs = ts }

    /// A fizzle/interrupt: the cast did not land, so nothing it might have resolved is ours.
    public func clearCast(_ spell: String) { byLine.remove(BuffsShapes.spellKey(spell)) }

    private func inQuickBuffBurst(_ ts: Int64) -> Bool {
        quickBuffTs > 0 && ts >= quickBuffTs && ts - quickBuffTs <= BuffsShapes.quickBuffWindowMs
    }

    /// The gate: what, if anything, admits a landing of `spell` at `ts`? A named anchor wins.
    /// Failing that, a Quick Buff burst admits the landing as yours but `unnamed`. An unanchored
    /// landing produces nothing.
    public func attribute(_ spell: String, _ ts: Int64) -> CastAttribution? {
        if let a = byLine[BuffsShapes.spellKey(spell)] {
            // Re-checked against the CURRENT allowlist, so a name the user just removed stops
            // anchoring immediately rather than at the next cast.
            if ts >= a.ts, ts - a.ts <= BuffsShapes.ownCastWindowMs, trusted(a.caster) {
                return CastAttribution(caster: a.caster, display: a.display, ts: a.ts,
                                   rankChanged: a.rankChanged, unnamed: false)
            }
        }
        if inQuickBuffBurst(ts) {
            return CastAttribution(caster: BuffsShapes.selfCaster, display: nil, ts: quickBuffTs,
                               rankChanged: false, unnamed: true)
        }
        return nil
    }

    /// True when this exact spell has a NAMED anchor in window — the candidate-narrowing test.
    public func namedAnchorFor(_ spell: String, _ ts: Int64) -> CastAttribution? {
        guard let a = attribute(spell, ts), !a.unnamed else { return nil }
        return a
    }

    /// The newest ts YOU ever cast this line — the ambiguous-apply recency tiebreak.
    public func lastCastTs(_ spell: String) -> Int64? { everCast[BuffsShapes.spellKey(spell)] }
}
