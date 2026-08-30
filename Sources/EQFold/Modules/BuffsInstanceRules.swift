// The pure rules the buff-instance store applies. Nothing here holds state or reads a clock; each
// function answers one question the store asks while censoring, retiring or projecting an instance.
// (fold/src/modules/buffs_instance_rules.rs)
import Foundation
import EQLog
import EQCompanionCore

/// A landed instance awaiting its next fade — the record behind one row.
///
/// It is a MULTISET: `group` holds one landing per entity of that name we believe is holding this
/// spell, oldest first.
public final class OpenCast {
    /// The spell's IDENTITY — the DB name a resolved landing carries, or the joined family. Never
    /// the ranked cast text; that is `castName`.
    public var spell: String
    /// The ranked text the cast line spelled, when it says something the DB name does not.
    public var castName: String?
    /// The rank-stripped spell key — the LINE, and half of the learner's key.
    public var spellKey: String
    /// The entity this instance is on ('self' or a canonical name key).
    public var entityKey: String
    public var group: HoldGroup
    /// Whose cast this is: 'self' or an allowlisted external.
    public var caster: String
    /// The entity disposition this cast is bound to (for censoring on zone/death).
    public var disp: Disposition
    /// True once an `offlineGap` has passed over this open cast — set for a BUFF and a DEBUFF alike.
    /// The instance survives; what is refused is the SAMPLE, because neither half of the pair is a
    /// clean observation once an absence sits inside it. Both errors point the same way — too long —
    /// and the estimator is a recency-weighted MAX. Censor, never correct.
    public var spannedGap: Bool

    init(spell: String, castName: String?, spellKey: String, entityKey: String, group: HoldGroup,
         caster: String, disp: Disposition, spannedGap: Bool) {
        self.spell = spell; self.castName = castName; self.spellKey = spellKey
        self.entityKey = entityKey; self.group = group; self.caster = caster
        self.disp = disp; self.spannedGap = spannedGap
    }
}

/// A cast in flight, not yet confirmed landed or cleared. It displays nothing.
public struct Pending {
    public var key: String
    public var beganTs: Int64
    /// The landing emote's subject key ('self' or a name key), once its text is recognized.
    public var emoteSubjectKey: String?
}

public enum BuffsInstanceRules {
    /// The death censor's reach: a mob died, so anything that was on an ENEMY goes with it. It takes
    /// two tests: the SPELL'S CLASS (a mob can share its name with your charmed pet) and the
    /// RECORD'S DISPOSITION (Pacify is beneficial and is cast at enemies). The reach is the union.
    public static func deathCensorsOpen(_ o: OpenCast, _ entityKey: String, _ isDebuff: Bool) -> Bool {
        if !isDebuff && o.disp != .hostile { return false }
        return o.entityKey == entityKey || o.entityKey == "unknown-hostile"
    }

    /// The same union for an ACTIVE row.
    public static func deathCensorsActive(_ a: ActiveBuff, _ aKey: String, _ entityKey: String) -> Bool {
        if a.cls != .debuff && a.disposition != .hostile { return false }
        return aKey == entityKey || aKey == "unknown-hostile" || a.inferredTarget == true
    }

    /// A name the world hands out more than once. The leading article is how EQ spells "one of
    /// these" as against an identity. Read off the canonical key, already lowercased.
    public static func isArticleNamed(_ entityKey: String) -> Bool {
        entityKey.hasPrefix("a ") || entityKey.hasPrefix("an ") || entityKey.hasPrefix("the ")
    }

    /// How much longer than the current estimate an ARTICLE-named mob's bound may claim.
    public static let deathBoundMaxEstimateMultiple: Int64 = 2
    /// The absolute ceiling on any bound, as a multiple of the spell database's own duration.
    public static let deathBoundMaxDbMultiple: Int64 = 3

    /// The death lower bound — the span a corpse is allowed to teach, or nil when it teaches
    /// nothing. Five rails, each of which refuses rather than guesses: a WITNESSED channel, ONE
    /// landing only, it must BEAT the current estimate, the same-name cap, the absolute cap. An
    /// offline gap refuses it too.
    public static func deathBoundSpan(_ o: OpenCast, _ entityKey: String, _ deathTs: Int64,
                                      _ stats: SpellStats) -> Int64? {
        let dbMsRaw = stats.dbDurationFor(o.spellKey)
        if !stats.hasWearOffChannel(o.spellKey) || o.spannedGap { return nil }
        guard let dbMs = dbMsRaw, dbMs > 0 else { return nil }
        if o.group.count != 1 { return nil }
        let span = deathTs - o.group.oldestTs
        guard let estimateMs = stats.estimateFor(o.spellKey, o.caster).ms else { return nil }
        if span <= 0 || span <= estimateMs { return nil }
        if isArticleNamed(entityKey) && span > deathBoundMaxEstimateMultiple * estimateMs { return nil }
        return span <= deathBoundMaxDbMultiple * dbMs ? span : nil
    }

    /// Zone: the player keeps self buffs, a SUMMONED pet follows and keeps its buffs, a CHARMED pet
    /// is left behind, and so are hostile mobs.
    public static func openLeftBehindOnZone(_ o: OpenCast) -> Bool {
        switch o.disp {
        case .zelf: return false
        case .summoned: return false
        case .charmed: return true
        case .hostile: return true
        }
    }

    /// The long-stop retirement every instance has: 90 minutes, or twice what we know about the
    /// spell, whichever is longer. It answers "we lost the thread", not "it expired".
    public static func hygieneCap(_ a: ActiveBuff, _ dbMs: Int64?) -> Double {
        Swift.max(BuffsShapes.hygieneCapMs(a.p75, a.n), dbMs.map { 2.0 * Double($0) } ?? 0.0)
    }

    /// The unwitnessed-expiry cull: a row whose countdown ran out and whose close was never
    /// witnessed is culled after its own timeout rather than squatting at 0 s under the hygiene cap.
    /// It mints nothing. The exemption is on `self`, not on class. A row with no number is counting
    /// UP and keeps the hygiene cap.
    public static func unwitnessedCullCap(_ a: ActiveBuff) -> Double {
        if a.cls != .debuff && a.isSelf { return Double.infinity }
        if let dur = a.overlayDurationMs, dur > 0 {
            return Double(dur + BuffsShapes.unwitnessedTimeoutMs(a.overlaySource))
        }
        // No number at all: the row is counting UP and has nothing to be overdue against.
        return Double.infinity
    }

    /// The orphaned-record reaper — the buffs half of the retention rule.
    ///
    /// The hygiene sweep's unwitnessed cull deletes the active row while keeping the open record,
    /// which is what lets a late wear-off still mint a sample. It reaps only ORPHANS, on the shared
    /// schedule. It mints nothing and says nothing.
    public static func reapOrphanedOpen(_ open: inout JSMap<OpenCast>, _ active: JSMap<ActiveBuff>,
                                        _ stats: SpellStats, _ now: Int64) {
        var dead: [String] = []
        for (ik, _) in open.pairs where !active.containsKey(ik) { dead.append(ik) }
        for ik in dead {
            guard let o = open[ik] else { continue }
            let cap = now - BuffsShapes.learningRecordCapMs(stats.dbDurationFor(o.spellKey),
                                                            BuffsShapes.hygieneAbsoluteMs)
            o.group.dropExpired(cap)
            if o.group.isEmpty { open.remove(ik) }
        }
    }

    /// Does this landing never expire — no countdown, no duration sample, no hygiene retirement?
    ///
    /// Two independent reasons: the SPELL itself states `Permanent`, or a SELF illusion was cast at
    /// or after the Permanent Illusion AA was owned. Both are gated on `self`.
    public static func landingIsPermanent(_ isSelf: Bool, _ dbPermanent: Bool, _ illusion: Bool,
                                          _ ts: Int64, _ permanentIllusionOwnedTs: Int64?) -> Bool {
        if !isSelf { return false }
        if dbPermanent { return true }
        return illusion && (permanentIllusionOwnedTs.map { ts >= $0 } ?? false)
    }
}
