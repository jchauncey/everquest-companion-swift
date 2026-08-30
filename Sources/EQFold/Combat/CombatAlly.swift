// The ally-charm model: whose pet is that, when it is not yours? (fold/src/combat/ally.rs)
//
// `<mob> has been charmed.` names no caster, so a third party's charm binds only on evidence that
// names both ends — a charm-family cast by a player-shaped name arming a window that exactly one
// caster-less broadcast falls inside, or `<PetName> says, 'My leader is <Player>.'`. The caster gate
// is the defence of the first: mobs cast charm songs at you, so the shape of the NAME is required.
//
// The lifecycle keys on `kind`, never on which line bound it. A `summon` bind is exempt from the
// soft-hostile break (no charm to break) and from the hold clock (no spell to derive one from);
// `charm` is the default when neither evidence exists.
//
// Four endings, each a line the log prints: the bound pet swings at a friendly (landed or not), pet
// death, a re-charm, and silence for a whole window. The hold SLIDES on evidence rather than
// expiring at the spell's listed duration. Nothing is retro-uncredited.
//
// Pure + clock-injected, like CombatCharm.swift.
import Foundation
import EQLog

/// What the evidence says this creature is, and therefore which endings apply to it.
public enum AllyKind: Sendable {
    case charm
    case summon
}

/// Which line bound it. The processing line reads it; it is not the lifecycle discriminant.
public enum AllyVia: Sendable {
    case cast
    case leader
}

/// `Number.POSITIVE_INFINITY` as a log clock can hold it — a `summon` bind has no clock at all.
/// Every arithmetic site below saturates rather than wrapping.
let NO_CLOCK: Int64 = Int64.max

/// i64 saturating add — the Rust `saturating_add`, which `NO_CLOCK` depends on.
@inline(__always)
func satAdd(_ a: Int64, _ b: Int64) -> Int64 {
    let (r, o) = a.addingReportingOverflow(b)
    if o { return b > 0 ? Int64.max : Int64.min }
    return r
}

/// One live third-party charm bind.
public struct AllyBind: Sendable {
    public var nameKey: String
    /// The pet's display name as the charm broadcast spelled it (lowercase article, world-model law
    /// 2) — never the sentence-cased spelling a damage line happens to carry.
    public var display: String
    public var charmerKey: String
    public var charmer: String
    public var boundTs: Int64
    /// How long this name may be quiet and still plausibly be bound, slid forward by `noteActivity`
    /// on every line the name acts on. NO_CLOCK when `kind` is `summon`.
    public var holdUntil: Int64
    /// The window `holdUntil` is slid by. Held on the bind rather than recomputed, because the spell
    /// that explains a bind is knowable only at the moment it is made.
    public var windowMs: Int64
    /// A second instance of this name has acted unbound, so its mob-vs-mob lines are unattributable.
    /// Sticky for the life of the bind: the twin does not announce its departure either.
    public var ambiguous: Bool
    public var via: AllyVia
    public var kind: AllyKind
}

/// What a caster-less `<mob> has been charmed.` broadcast means for a third party.
public enum AllyVerdict {
    /// Bound (or re-bound / restated) to a named charmer.
    case bind(AllyBind)
    /// Evidence exists but is unusable, and the reason is worth printing.
    case refuse(String)
    /// No third-party cast is armed at all — this model has nothing to say about the line.
    case none
}

/// A bind whose hold has run out, for the caller's processing line.
public struct AllyExpiry: Sendable {
    public var nameKey: String
    public var display: String
    public var charmer: String
}

/// One `<Name> begins casting <Spell>.` line, as the ally model asks about it.
public struct AllyCastLine {
    public var caster: String
    public var casterKey: String
    public var spell: String
    public var ts: Int64
    /// `EngineState.allyCasterAllowed` — the behavioural half of the caster gate.
    public var allowed: Bool

    public init(caster: String, casterKey: String, spell: String, ts: Int64, allowed: Bool) {
        self.caster = caster; self.casterKey = casterKey; self.spell = spell
        self.ts = ts; self.allowed = allowed
    }
}

/// One `<PetName> says, 'My leader is <Player>.'` line about somebody else.
public struct AllyLeaderLine {
    public var petKey: String
    public var pet: String
    public var owner: String
    public var ownerKey: String
    public var ts: Int64
    /// `CharmModel.everCharmed(petKey)` — the charm-evidence half of the lifecycle question. The
    /// caller answers it because the fact lives in the other charm model.
    public var everCharmed: Bool

    public init(petKey: String, pet: String, owner: String, ownerKey: String, ts: Int64, everCharmed: Bool) {
        self.petKey = petKey; self.pet = pet; self.owner = owner
        self.ownerKey = ownerKey; self.ts = ts; self.everCharmed = everCharmed
    }
}

private struct AllyArm {
    var charmerKey: String
    var charmer: String
    var spellKey: String
    var ts: Int64
    var until: Int64
}

public final class AllyCharms {
    /// Third-party charm casts in flight, keyed by caster rather than the single slot your own model
    /// uses: a zone can hold three enchanters, and collapsing them would make every one of their
    /// broadcasts look like the last caster's.
    private var arms: JSMap<AllyArm> = JSMap()
    /// nameKey → the live bind. Insertion-ordered because `boundNames` and `sweep` publish it.
    private var binds: JSMap<AllyBind> = JSMap()
    /// Player-shaped names seen casting (any spell) plus every charmer this model has bound for.
    /// For the soft-hostile proof and nothing else — never attribution, never merged into
    /// `knownPlayers`.
    private var friendlies: Set<String> = []
    /// casterKey → ts this ally was last seen casting a pet summon. The weaker half of the lifecycle
    /// question on purpose: no summon line names the pet it makes.
    ///
    /// Survives a zone, like `friendlies` and unlike the binds.
    private var summons: [String: Int64] = [:]

    public init() {}

    public func reset() {
        arms.clear()
        binds.clear()
        friendlies.removeAll()
        summons.removeAll()
    }

    /// `<Name> begins casting <Spell>.` — remember a player-shaped caster, and arm the join when the
    /// spell is one that could have printed the charm broadcast.
    public func noteCast(_ c: AllyCastLine) {
        if !c.allowed || !isPlayerShapedName(c.caster) { return }
        friendlies.insert(c.casterKey)
        // Recorded before the charm-arm return so a summon is never missed by falling through a test
        // about a different spell family. It arms nothing; only a later leader say reads it.
        if isPetSummonSpell(c.spell) {
            summons[c.casterKey] = c.ts
        }
        if !isCharmBroadcastSpell(c.spell) { return }
        arms.insert(c.casterKey, AllyArm(
            charmerKey: c.casterKey,
            charmer: c.caster,
            spellKey: Names.spellCanonKey(c.spell),
            ts: c.ts,
            until: c.ts + armWindowMs(c.spell)
        ))
    }

    /// A rostered group-mate is a friendly whatever their name looks like.
    public func noteFriendly(_ nameKey: String) { friendlies.insert(nameKey) }

    /// `<mob> has been charmed.` that the owner's model already declined. Consumes the winning arm:
    /// every charm spell in the DB is single-target, so one cast explains exactly one broadcast.
    @discardableResult
    public func broadcast(_ nameKey: String, _ display: String, _ ts: Int64) -> AllyVerdict {
        pruneArms(ts)
        // The line itself is charm evidence about this name, whatever it resolves to: a live bind
        // wearing the summon lifecycle has just been contradicted. One direction only, and it is the
        // safe one — this can add the break rule and the hold clock, never remove them.
        if var live = binds[nameKey], live.kind == .summon {
            live.kind = .charm
            live.windowMs = DEFAULT_CHARM_DURATION_MS + DURATION_SLACK_MS
            live.holdUntil = satAdd(ts, live.windowMs)
            binds[nameKey] = live
        }
        let live = arms.values.filter { ts >= $0.ts && ts <= $0.until }
        if live.isEmpty { return .none }
        let casters = Set(live.map(\.charmerKey))
        if casters.count > 1 {
            let n = casters.count
            // Consume them all: a tie says none of these casts is explained by anything else either,
            // and leaving them armed would hand the next broadcast to a spent cast.
            for a in live { arms.remove(a.charmerKey) }
            binds.remove(nameKey)
            return .refuse("\(n) casters armed - cannot tell whose charm this is")
        }
        let arm = live[live.count - 1]
        arms.remove(arm.charmerKey)
        let prev = binds[nameKey]
        let same = prev.map { $0.charmerKey == arm.charmerKey } ?? false
        let windowMs = provisionalWindowMs(arm.spellKey)
        let bind = AllyBind(
            nameKey: nameKey,
            display: display,
            charmerKey: arm.charmerKey,
            charmer: arm.charmer,
            boundTs: same ? prev!.boundTs : ts,
            holdUntil: satAdd(ts, windowMs),
            windowMs: windowMs,
            // A re-charm by the same charmer does not clear ambiguity: the twin that made the name
            // unreadable is still standing there, and nothing the log prints says otherwise.
            ambiguous: same && prev!.ambiguous,
            via: .cast,
            // A charm broadcast made this bind, so the creature is a charmed mob by construction.
            kind: .charm
        )
        binds.insert(nameKey, bind)
        friendlies.insert(arm.charmerKey)
        return .bind(bind)
    }

    /// `<PetName> says, 'My leader is <Player>.'` — the strongest ally bind, and the only one that
    /// reaches a stranger's summoned pet. It is also where the lifecycle question is answered.
    @discardableResult
    public func bindByLeader(_ l: AllyLeaderLine) -> AllyBind {
        let kind = classify(l)
        // A leader say names no spell, so a charm-class bind gets the default charm duration. A
        // summon-class one gets no clock.
        let windowMs = kind == .summon ? NO_CLOCK : DEFAULT_CHARM_DURATION_MS + DURATION_SLACK_MS
        let prev = binds[l.petKey]
        let same = prev.map { $0.charmerKey == l.ownerKey } ?? false
        let bind = AllyBind(
            nameKey: l.petKey,
            display: l.pet,
            charmerKey: l.ownerKey,
            charmer: l.owner,
            boundTs: same ? prev!.boundTs : l.ts,
            holdUntil: satAdd(l.ts, windowMs),
            windowMs: windowMs,
            ambiguous: same ? prev!.ambiguous : false,
            via: .leader,
            kind: kind
        )
        binds.insert(l.petKey, bind)
        friendlies.insert(l.ownerKey)
        return bind
    }

    /// What kind of creature a leader say is about — three rungs, strongest first.
    ///
    ///   1. Charm evidence for this PET: a broadcast has named it. Keyed by the pet, so it wins.
    ///   2. Summon evidence for this OWNER: seen casting a pet summon at or before the say.
    ///   3. Neither ⇒ `charm`, the safer default.
    private func classify(_ l: AllyLeaderLine) -> AllyKind {
        if l.everCharmed { return .charm }
        if let at = summons[l.ownerKey], at <= l.ts { return .summon }
        return .charm
    }

    /// The live bind for a name, or none.
    public func bindOf(_ nameKey: String) -> AllyBind? { binds[nameKey] }

    /// The bound name just acted — slide its hold. A pet still swinging has not stopped being a pet,
    /// whatever a spell database lists its charm at.
    ///
    /// It slides on APPEARANCE, not on credit: an ambiguous bind books nothing, but the name is
    /// demonstrably still acting, and reaping it for silence would be false.
    public func noteActivity(_ nameKey: String, _ ts: Int64) {
        guard var b = binds[nameKey] else { return }
        let next = satAdd(ts, b.windowMs)
        if next > b.holdUntil {
            b.holdUntil = next
            binds[nameKey] = b
        }
    }

    /// The bind a line may be CREDITED to: live and unambiguous.
    public func creditable(_ nameKey: String) -> AllyBind? {
        guard let b = binds[nameKey], !b.ambiguous else { return nil }
        return b
    }

    /// True when `nameKey` is on the friendly side of an ally charm — a caster we have seen, or a
    /// charmer we have bound for. Never an attribution test.
    public func isFriendly(_ nameKey: String) -> Bool { friendlies.contains(nameKey) }

    /// True while no bind is live (lets the caller skip the per-line work entirely).
    public func idle() -> Bool { binds.isEmpty }

    /// The twin refusal. Sticky — see `AllyBind.ambiguous`.
    @discardableResult
    public func markAmbiguous(_ nameKey: String) -> Bool {
        guard var b = binds[nameKey] else { return false }
        if b.ambiguous { return false }
        b.ambiguous = true
        binds[nameKey] = b
        return true
    }

    /// Drop a bind unconditionally — death, a zone, your own charm taking the same mob, a pet claim.
    /// Every one of these ends both kinds.
    ///
    /// The soft-hostile proof does not come through here: it is the one ending that depends on which
    /// creature this is.
    @discardableResult
    public func release(_ nameKey: String) -> AllyBind? {
        let b = binds[nameKey]
        if b != nil { binds.remove(nameKey) }
        return b
    }

    /// The soft-hostile proof, applied — the bound pet has swung at a friendly. Returns the bind it
    /// ended, or nil when the swing proves nothing.
    ///
    /// It proves nothing about a `summon` bind: a summoned pet swinging at a name that happens to be
    /// on the friendly list is a name collision, not a charm ending.
    ///
    /// It reads `kind`, never `via`: a charm pet answers `/pet who leader` too.
    @discardableResult
    public func softHostile(_ nameKey: String) -> AllyBind? {
        guard let b = binds[nameKey] else { return nil }
        if b.kind == .summon { return nil }
        binds.remove(nameKey)
        return b
    }

    /// Charm cannot survive a zone, and neither can an arm. The friendly set and the summon sighting
    /// are kept: they are about people, and a summoned pet walks through the door with its owner.
    public func zone() {
        arms.clear()
        binds.clear()
    }

    /// Binds whose pet has gone silent for a whole window as of `now`; removing them is this call's
    /// side effect. A `summon` bind's `holdUntil` is NO_CLOCK and is never in the answer.
    public func sweep(_ now: Int64) -> [AllyExpiry] {
        let out = binds.values.filter { $0.holdUntil <= now }.map {
            AllyExpiry(nameKey: $0.nameKey, display: $0.display, charmer: $0.charmer)
        }
        for e in out { binds.remove(e.nameKey) }
        return out
    }

    /// Display names of the live ally pets, newest last.
    public func boundNames() -> [String] { binds.values.map(\.display) }

    private func pruneArms(_ now: Int64) {
        let stale = arms.pairs.filter { $0.1.until < now }.map(\.0)
        for k in stale { arms.remove(k) }
    }
}
