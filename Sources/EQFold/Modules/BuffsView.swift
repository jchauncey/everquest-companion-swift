// The `ActiveBuff` projection: turn one live buff instance (spell line, entity, caster) plus how it
// got there into the row the UI renders. Pure — it reads the learned per-spell stats and the current
// pet identities and writes nothing — so every caller in the instance store shares one definition of
// what a row says.
// (fold/src/modules/buffs_view.rs)
import Foundation
import EQLog
import EQCompanionCore

/// A currently-active (landed, not yet faded) buff INSTANCE = (spell, target entity).
///
/// Optional fields are skipped when absent and nullable ones are written as null, and the goldens
/// pin the difference.
public struct ActiveBuff {
    /// The spell's IDENTITY — the DB's own display name whenever the model resolved which spell
    /// this is, never the ranked text one cast line happened to spell. A FAMILY the anchors could
    /// not narrow names every candidate here and says so with `candidates`.
    public var spell: String
    /// The ranked name the cast line spelled, when a cast anchor resolved this instance AND the
    /// log's spelling says something `spell` does not. Display only.
    public var castName: String?
    public var cls: BuffClass
    /// True when the spell CALMS its target — a second, orthogonal fact about the spell.
    public var calmsTarget: Bool?
    public var isSelf: Bool
    public var disposition: Disposition?
    public var startedTs: Int64
    public var estimatedMs: Int64?
    public var p25: Double?
    public var p75: Double?
    public var n: Int64
    public var target: String?
    public var inferredTarget: Bool?
    public var durationSource: EstimatorSource?
    public var overlayDurationMs: Int64?
    public var overlaySource: EstimatorSource?
    public var permanent: Bool?
    public var permanentSource: String?
    public var messageDriven: Bool?
    public var count: Int64?
    public var caster: String?
    public var candidates: [String]?

    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "spell": .string(spell),
            "cls": .string(cls.rawValue),
            "self": .bool(isSelf),
            "startedTs": .int(startedTs),
            "estimatedMs": estimatedMs.map { .int($0) } ?? .null,
            "p25": p25.map { .double($0) } ?? .null,
            "p75": p75.map { .double($0) } ?? .null,
            "n": .int(n),
            "overlayDurationMs": overlayDurationMs.map { .int($0) } ?? .null,
        ]
        if let v = castName { o["castName"] = .string(v) }
        if let v = calmsTarget { o["calmsTarget"] = .bool(v) }
        if let v = disposition { o["disposition"] = .string(v.rawValue) }
        if let v = target { o["target"] = .string(v) }
        if let v = inferredTarget { o["inferredTarget"] = .bool(v) }
        if let v = durationSource { o["durationSource"] = .string(v.rawValue) }
        if let v = overlaySource { o["overlaySource"] = .string(v.rawValue) }
        if let v = permanent { o["permanent"] = .bool(v) }
        if let v = permanentSource { o["permanentSource"] = .string(v) }
        if let v = messageDriven { o["messageDriven"] = .bool(v) }
        if let v = count { o["count"] = .int(v) }
        if let v = caster { o["caster"] = .string(v) }
        if let v = candidates { o["candidates"] = .array(v.map { .string($0) }) }
        return .object(o)
    }
}

/// Everything that identifies the instance being projected, plus how it was established.
public struct ActiveSpec {
    /// The IDENTITY — a resolved landing's DB name, or the joined family.
    public var spell: String = ""
    /// Display only: the ranked text the cast line spelled, when it said one.
    public var castName: String?
    public var key: String = ""
    public var entityKey: String = ""
    public var startedTs: Int64 = 0
    public var dispOverride: Disposition?
    /// 'self' or an allowlisted external — the second half of the learner's key.
    public var caster: String?
    /// How many entities of that display name are holding it.
    public var count: Int64?
    /// Present when the landing sentence stayed a FAMILY.
    public var candidates: [String]?
    public var messageDriven: Bool = false
    public var permanent: Bool = false

    public init() {}
}

/// Target label + inference. Self: none. Otherwise the bound entity's display name; a debuff whose
/// target was inferred (no confirmed message) is flagged.
private func resolveTargetLabel(_ entityKey: String, _ cls: BuffClass, _ isSelf: Bool,
                                _ disp: Disposition?, _ messageDriven: Bool,
                                _ pets: PetEntities) -> (String?, Bool) {
    if isSelf { return (nil, false) }
    // A landing line NAMED this entity, so the target is stated rather than inferred.
    if messageDriven { return (pets.entityDisplayFor(entityKey), false) }
    // Self-keyed debuff = an inferred, not-yet-named hostile target.
    if cls == .debuff && entityKey == BuffsShapes.selfKey { return (pets.petTargetDisplay, true) }
    if disp == .summoned && pets.summonedKey == entityKey { return (pets.summonedDisplay, false) }
    if disp == .charmed && pets.charmedKey == entityKey { return (pets.charmedDisplay, false) }
    if pets.petTargetKey == entityKey { return (pets.petTargetDisplay, cls == .debuff) }
    if entityKey == "unknown-hostile" { return (nil, true) }
    // A cast-timing-inferred debuff target (no confirming message) is a best guess.
    return (pets.entityDisplayFor(entityKey), cls == .debuff && !messageDriven)
}

/// The overlay's countdown duration, computed here where the samples and the DB live and carried on
/// the row so the pure projection never reaches back. It is the SAME estimator the Buffs tab uses.
/// It is read PER CASTER, because the AAs and focus items behind an external's duration are theirs.
private func overlayDurationOf(_ key: String, _ permanent: Bool, _ stats: SpellStats,
                               _ caster: String) -> (Int64?, EstimatorSource?) {
    if permanent { return (nil, nil) }
    let est = stats.estimateFor(key, caster)
    if let ms = est.ms, let src = est.source { return (ms, src) }
    return (nil, nil)
}

public func buildActive(_ spec: ActiveSpec, _ stats: SpellStats, _ pets: PetEntities) -> ActiveBuff {
    let caster = spec.caster ?? BuffsShapes.selfCaster
    let cls = stats.classOf(spec.key)
    // A DEBUFF is never the player's own buff, even if cast timing bound it to the self key before
    // its class was known.
    let isSelf = spec.entityKey == BuffsShapes.selfKey && cls != .debuff
    let (target, inferredTarget) = resolveTargetLabel(spec.entityKey, cls, isSelf, spec.dispOverride,
                                                      spec.messageDriven, pets)
    // The calm flag, read at the same seam as `cls` and from the same DB. A FAMILY answers only if
    // every candidate calms — the same unanimity rule a family's duration takes.
    let calms = stats.calmsTarget(spec.key)
        || (spec.candidates.map { cs in cs.allSatisfy { stats.calmsTarget(BuffsShapes.spellKey($0)) } } ?? false)
    // Why it is permanent, derived rather than plumbed: `landingIsPermanent` asks the DB first and
    // the AA second, so re-asking the DB here answers the same question in the same order.
    let permanentSource = stats.isPermanent(spec.key) ? "spell" : "illusion-aa"
    let st = stats.statFor(spec.key, caster)
    let est = stats.estimateFor(spec.key, caster)
    let (overlayDurationMs, overlaySource) = overlayDurationOf(spec.key, spec.permanent, stats, caster)
    let count = spec.count ?? 1
    return ActiveBuff(
        spell: spec.spell,
        castName: spec.castName.flatMap { $0 != spec.spell ? $0 : nil },
        cls: cls,
        calmsTarget: calms ? true : nil,
        isSelf: isSelf,
        disposition: spec.dispOverride,
        startedTs: spec.startedTs,
        estimatedMs: spec.permanent ? nil : est.ms,
        p25: st?.p25,
        p75: st?.p75,
        n: st?.n ?? 0,
        target: target,
        inferredTarget: inferredTarget ? true : nil,
        durationSource: spec.permanent ? nil : est.source,
        overlayDurationMs: overlayDurationMs,
        overlaySource: overlaySource,
        permanent: spec.permanent ? true : nil,
        permanentSource: spec.permanent ? permanentSource : nil,
        messageDriven: spec.messageDriven ? true : nil,
        count: count > 1 ? count : nil,
        caster: caster != BuffsShapes.selfCaster ? caster : nil,
        candidates: spec.candidates)
}

// MARK: - Checkpoint

extension ActiveBuff {
    /// Decode a row its own `json` encoded. `json` is a lossless codec here: every optional field
    /// is skipped when absent, every nullable one is written as `null`, and no two states collapse
    /// into one spelling — so the checkpoint reuses it and only the decoder is new.
    static func fromCheckpoint(_ v: JSONValue) -> ActiveBuff? {
        guard let spell = v["spell"].string, let clsRaw = v["cls"].string,
              let cls = BuffClass(rawValue: clsRaw), let isSelf = v["self"].bool,
              let startedTs = v["startedTs"].int64, let n = v["n"].int64 else { return nil }
        var disposition: Disposition?
        if let s = v["disposition"].string {
            guard let d = Disposition(rawValue: s) else { return nil }
            disposition = d
        }
        var durationSource: EstimatorSource?
        if let s = v["durationSource"].string {
            guard let d = EstimatorSource(rawValue: s) else { return nil }
            durationSource = d
        }
        var overlaySource: EstimatorSource?
        if let s = v["overlaySource"].string {
            guard let d = EstimatorSource(rawValue: s) else { return nil }
            overlaySource = d
        }
        var candidates: [String]?
        if let rows = v["candidates"].array {
            let names = rows.compactMap(\.string)
            guard names.count == rows.count else { return nil }
            candidates = names
        }
        return ActiveBuff(
            spell: spell,
            castName: v["castName"].string,
            cls: cls,
            calmsTarget: v["calmsTarget"].bool,
            isSelf: isSelf,
            disposition: disposition,
            startedTs: startedTs,
            estimatedMs: v["estimatedMs"].int64,
            p25: v["p25"].double,
            p75: v["p75"].double,
            n: n,
            target: v["target"].string,
            inferredTarget: v["inferredTarget"].bool,
            durationSource: durationSource,
            overlayDurationMs: v["overlayDurationMs"].int64,
            overlaySource: overlaySource,
            permanent: v["permanent"].bool,
            permanentSource: v["permanentSource"].string,
            messageDriven: v["messageDriven"].bool,
            count: v["count"].int64,
            caster: v["caster"].string,
            candidates: candidates)
    }
}
