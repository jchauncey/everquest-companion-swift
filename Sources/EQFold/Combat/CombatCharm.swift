// Charm / crowd-control ownership: which `<mob> has been charmed.` broadcast is OURS
// (fold/src/combat/charm.rs).
//
// Charm and mez broadcasts are zone-wide and name no caster, so binding one unconditionally adopts
// a stranger's pet. `You begin casting <Spell>.` prints for the player alone, so an own cast ARMS
// the model and a broadcast inside the arm is ours.
//
// Two windows are the spell's own numbers rather than tuned constants. The arm is the spell's cast
// time plus a slack, because the observed broadcast delay tracks cast time. The demotion horizon is
// the charm's own duration, because a charmed pet routinely stands idle for minutes between orders.
//
// Pure and clock-injected: no wall clock, no engine state, no I/O.
import Foundation
import EQLog
import EQCompanionCore

/// What a `<mob> has been charmed.` broadcast means for US.
public enum CharmVerdict: Sendable {
    case own
    case foreign
}

/// A provisional bind that has aged out and must be unbound.
public struct CharmDemotion: Sendable {
    public var nameKey: String
    public var display: String
}

private enum ArmKind {
    case charm
    case cc
    case petBuff
}

private struct Arm {
    var kind: ArmKind
    var spellKey: String
    var ts: Int64
    var until: Int64
}

private struct Provisional {
    var until: Int64
    var display: String
}

public final class CharmModel {
    /// The single pending own cast. You cast one spell at a time, so this is not a map.
    private var arm: Arm?
    /// nameKey → binds awaiting corroboration. Insertion order is the sweep's report order.
    private var provisional: [(String, Provisional)] = []
    /// nameKey of binds proven ours. Never auto-expires.
    private(set) var confirmed: Set<String> = []
    /// nameKey → ts of a charm broadcast we did NOT bind, for the PROMOTE path.
    private var observed: [String: Int64] = [:]
    /// Every nameKey a charm broadcast has ever named, ours or not. A name the zone has seen charmed
    /// is a mob whatever else it looks like. Session-scoped and never pruned.
    private var seenCharmed: Set<String> = []

    public init() {}

    public func reset() {
        arm = nil
        provisional.removeAll()
        confirmed.removeAll()
        observed.removeAll()
        seenCharmed.removeAll()
    }

    /// True if a charm broadcast has ever named this entity (ours or a stranger's).
    public func everCharmed(_ nameKey: String) -> Bool { seenCharmed.contains(nameKey) }

    /// `You begin casting <Spell>.` — arms the model, or clears a stale arm when the player moves on
    /// to an unrelated spell.
    public func noteCastBegin(_ spell: String, _ ts: Int64) {
        let kind: ArmKind
        if isCharmSpell(spell) {
            kind = .charm
        } else if isCcSpell(spell) {
            kind = .cc
        } else if isPetOnlySpell(spell) {
            kind = .petBuff
        } else {
            arm = nil
            return
        }
        arm = Arm(kind: kind, spellKey: Names.spellCanonKey(spell), ts: ts, until: ts + armWindowMs(spell))
    }

    /// `Your <Spell> spell fizzles!` / `is interrupted.` / `<mob> resisted your <Spell>!` — the armed
    /// cast did not land, so nothing it might have resolved is ours. Only the ARMED spell disarms.
    public func noteCastFailed(_ spell: String, _ ts: Int64) {
        let key = Names.spellCanonKey(spell)
        if let a = arm, a.spellKey == key, ts >= a.ts {
            arm = nil
        }
    }

    /// `<mob> has been charmed.` — is it ours? Consumes the arm on a hit: every charm spell in the
    /// DB is single-target, so a second broadcast in the same window is somebody else's.
    @discardableResult
    public func charmBroadcast(_ nameKey: String, _ display: String, _ ts: Int64) -> CharmVerdict {
        seenCharmed.insert(nameKey)
        if confirmed.contains(nameKey) || provisionalHas(nameKey) { return .own }
        var hit: String?
        if let a = arm, a.kind == .charm, ts >= a.ts, ts <= a.until { hit = a.spellKey }
        if let spellKey = hit {
            arm = nil
            let until = ts + provisionalWindowMs(spellKey)
            provisional.append((nameKey, Provisional(until: until, display: display)))
            return .own
        }
        observed[nameKey] = ts
        return .foreign
    }

    /// `<mob> has been mesmerized./enthralled./entranced./ensnared.` — is it ours? Does NOT consume
    /// the arm: one AE mez prints one broadcast per mob it lands on, and one cast must gate them all.
    public func ccBroadcast(_ ts: Int64) -> Bool {
        guard let a = arm else { return false }
        return a.kind == .cc && ts >= a.ts && ts <= a.until
    }

    /// A NAMED buff landing (`<Name> goes berserk.`) — was it YOUR pet-only spell resolving?
    ///
    /// The message is not the gate: one landing message resolves to several spells and most are
    /// ordinary buffs, so the armed cast must be AMONG the candidates. Consumes the arm on a hit —
    /// one cast is one bind.
    public func petBuffLanding(_ spellNames: [String], _ ts: Int64) -> Bool {
        guard let a = arm else { return false }
        if a.kind != .petBuff || ts < a.ts || ts > a.until { return false }
        if !spellNames.contains(where: { Names.spellCanonKey($0) == a.spellKey }) { return false }
        arm = nil
        return true
    }

    /// Pet-shaped evidence for `nameKey`: its own outgoing damage or miss, its resisted cast, its
    /// `… Master.` tell, the owner healing it, or YOUR charm spell wearing off it. Promotes a
    /// provisional bind to confirmed.
    public func notePetEvidence(_ nameKey: String) {
        takeProvisional(nameKey)
        confirmed.insert(nameKey)
        observed.removeValue(forKey: nameKey)
    }

    /// A `<Name> told you, '… Master.'` tell arrived for a name we saw charmed but declined to bind.
    /// The tell is ownership-definitive and pet-only, so this promotes the name — as a CHARMED pet,
    /// never a summoned one. Returns true when the caller should bind it as a charm.
    public func claimIsCharmed(_ nameKey: String, _ ts: Int64) -> Bool {
        guard let seen = observed[nameKey] else { return false }
        if ts - seen > PROMOTE_MS { return false }
        observed.removeValue(forKey: nameKey)
        confirmed.insert(nameKey)
        return true
    }

    /// Forget a name entirely (death, un-charm, left behind on a zone).
    public func release(_ nameKey: String) {
        takeProvisional(nameKey)
        confirmed.remove(nameKey)
        observed.removeValue(forKey: nameKey)
    }

    /// Charm cannot survive a zone. Keep only the pets that actually walked through with you (the
    /// summoned survivors the world model hands back) and drop every pending arm and sighting.
    public func zone(_ survivorKeys: [String]) {
        arm = nil
        provisional.removeAll()
        observed.removeAll()
        let keep = Set(survivorKeys)
        confirmed = confirmed.filter { keep.contains($0) }
    }

    /// True when the model has nothing that could expire — lets the caller skip the sweep.
    public func idle() -> Bool { provisional.isEmpty }

    /// Provisional binds whose corroboration window has closed as of `now`. Removing them from the
    /// model is this call's side effect; unbinding them in the world is the caller's.
    public func sweep(_ now: Int64) -> [CharmDemotion] {
        var out: [CharmDemotion] = []
        for (nameKey, v) in provisional where v.until <= now {
            out.append(CharmDemotion(nameKey: nameKey, display: v.display))
        }
        provisional = provisional.filter { $0.1.until > now }
        return out
    }

    private func provisionalHas(_ nameKey: String) -> Bool {
        provisional.contains { $0.0 == nameKey }
    }

    @discardableResult
    private func takeProvisional(_ nameKey: String) -> Bool {
        let before = provisional.count
        provisional = provisional.filter { $0.0 != nameKey }
        return before != provisional.count
    }
}

// MARK: - Checkpoint

extension CharmModel {
    /// Everything, mid-arm included: a checkpoint can land between a `You begin casting` and its
    /// broadcast, and losing the arm would read the resumed broadcast as a stranger's charm. The
    /// windows are all log-clock (`ts` / `until` derive from event ts), so they restore verbatim.
    func checkpointState() -> JSONValue {
        var o: [String: JSONValue] = [
            "provisional": .array(provisional.map { (key, p) -> JSONValue in
                .object(["nameKey": .string(key), "until": .int(p.until), "display": .string(p.display)])
            }),
            "confirmed": ckStringSet(confirmed),
            "observed": ckInt64Dict(observed),
            "seenCharmed": ckStringSet(seenCharmed),
        ]
        if let a = arm {
            let kind: String
            switch a.kind {
            case .charm: kind = "charm"
            case .cc: kind = "cc"
            case .petBuff: kind = "petBuff"
            }
            o["arm"] = .object(["kind": .string(kind), "spellKey": .string(a.spellKey),
                                "ts": .int(a.ts), "until": .int(a.until)])
        }
        return .object(o)
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let provRows = v["provisional"].array,
              let confirmedV = ckStringSetBack(v["confirmed"]),
              let observedV = ckInt64DictBack(v["observed"]),
              let seenV = ckStringSetBack(v["seenCharmed"]) else { reset(); return false }
        if let armV = v["arm"].presentValue {
            guard let kindStr = armV["kind"].string, let spellKey = armV["spellKey"].string,
                  let ts = armV["ts"].int64, let until = armV["until"].int64 else { reset(); return false }
            let kind: ArmKind
            switch kindStr {
            case "charm": kind = .charm
            case "cc": kind = .cc
            case "petBuff": kind = .petBuff
            default: reset(); return false
            }
            arm = Arm(kind: kind, spellKey: spellKey, ts: ts, until: until)
        }
        var prov: [(String, Provisional)] = []
        for r in provRows {
            guard let key = r["nameKey"].string, let until = r["until"].int64,
                  let display = r["display"].string else { reset(); return false }
            prov.append((key, Provisional(until: until, display: display)))
        }
        provisional = prov
        confirmed = confirmedV
        observed = observedV
        seenCharmed = seenV
        return true
    }
}
