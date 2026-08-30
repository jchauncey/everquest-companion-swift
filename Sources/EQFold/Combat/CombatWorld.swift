// The world model — entity-INSTANCE tracking (fold/src/combat/world.rs).
//
// Keying by bare name collapses same-named twins: charm one `a fire giant warrior` while a hostile
// one is present and the pet and the mob it tanks become indistinguishable. Every spawn gets a
// distinct identity `<nameKey>#<gen>` instead.
//
// The lifecycle table. Every rule is deterministic and ambiguity is FLAGGED rather than resolved
// toward the worse failure — a false pet death drops all later pet damage, so the bias is always
// away from retiring the pet:
//
//   see(name)     resolve a live instance, else spawn a hostile one (gen++). Twins are separated
//                 by evidence (`noteTwinEvidence`), never by guesswork.
//   charm(name)   bind a lone live hostile when there is no evidence of a second twin; otherwise
//                 spawn a fresh charmed one.
//   claim(name)   the summoned half, idempotent FIRST so a pet's repeat tells converge on one
//                 entity. Binding a new summoned pet retires the prior one.
//   uncharm(name) clear `charmed` on the same instance — hostile-capable again, not retired.
//   death(…)      decide WHICH instance dies; four cases, all biased toward the pet.
//   zone(ts)      retire everything except summoned pets, which the real log proves follow you.
//   staleness     a live HOSTILE unseen for INSTANCE_STALE_MS is retired the next time its name
//                 resolves, so the sighting after the gap spawns a fresh generation. Pets are
//                 exempt: a pet is bound by evidence and may stand quiet for minutes.
//
// Retirement is final, and somebody has to hear about it. `retire()` — the one place it is
// recorded — queues the instance id, and `EngineState` drains the queue at every call site that
// can retire.
import Foundation
import EQLog

/// How long a live hostile instance may go completely unobserved before its slot is eligible for
/// retirement. Deliberately the same number as the encounter layer's PRESENCE_GONE_MS: an instance
/// closure has written off as "gone" is precisely the one whose identity a later sighting must not
/// inherit, so the two horizons agree by construction.
public let INSTANCE_STALE_MS: Int64 = PRESENCE_GONE_MS

/// How an instance became your pet.
///
/// `charmed` — bound by a `<mob> has been charmed.` line; cannot survive a zone.
/// `summoned` — a class pet (random proper name) bound by a petClaim. It persists across zone
/// lines, verified in the real log.
public enum PetKind: Sendable {
    case charmed
    case summoned
}

/// True if an entity of this kind is retired by a zone line: charmed pets and hostile mobs are left
/// behind, summoned pets follow. `nil` = a hostile mob.
public func isLeftBehindOnZone(_ kind: PetKind?) -> Bool { kind != .summoned }

public struct Instance: Sendable {
    public var instanceId: String
    public var nameKey: String
    public var display: String
    public var charmed: Bool
    /// Set while `charmed` is true; distinguishes zone behaviour. `nil` = hostile.
    public var petKind: PetKind?
    public var firstSeenTs: Int64
    public var lastSeenTs: Int64
    public var retired: Bool
    /// gen ordinal (1-based) among all instances ever spawned for this nameKey.
    public var gen: Int
}

/// An instance resolved for attribution: the aggregate key, the name key the membership sets are
/// asked about, and the display label the meter row carries. All three always travel together.
public struct Resolved: Sendable {
    public var instanceId: String
    public var nameKey: String
    public var label: String

    public init(instanceId: String, nameKey: String, label: String) {
        self.instanceId = instanceId; self.nameKey = nameKey; self.label = label
    }
}

/// Result of a `death()` decision, for the engine's processing line and ambiguity surfacing.
public struct DeathResolution: Sendable {
    public var wasPet: Bool
    public var ambiguous: Bool
    public var reason: String
}

public final class WorldModel {
    /// Every instance ever spawned, in spawn order; the indices below are handles into it.
    private var insts: [Instance] = []
    /// The LIVE index, nameKey → active handles oldest→newest, kept separate from the spawn history.
    /// An emptied entry is KEPT rather than removed, so the map's insertion order — the order
    /// `petInstances()` and `charmedInstances()` report — stays what it was.
    private var activeByName: JSMap<[Int]> = JSMap()
    private var byId: [String: Int] = [:]
    /// gen counter per nameKey.
    private var gens: [String: Int] = [:]
    /// Killers each charmed pet has been observed tanking. Drives death case (b).
    private var petTankedBy: [Int: Set<String>] = [:]
    /// The retirement announcement queue. Drained by `EngineState` at every call site that can
    /// retire.
    public var retiredIds: [String] = []

    public init() {}

    public func reset() {
        insts.removeAll()
        activeByName.clear()
        byId.removeAll()
        gens.removeAll()
        petTankedBy.removeAll()
        retiredIds.removeAll()
    }

    /// Active (non-retired) handles for a nameKey, oldest→newest.
    private func active(_ nameKey: String) -> [Int] { activeByName[nameKey] ?? [] }

    private func charmedActive(_ nameKey: String) -> Int? {
        active(nameKey).first { insts[$0].charmed }
    }

    private func hostileActive(_ nameKey: String) -> Int? {
        active(nameKey).first { !insts[$0].charmed }
    }

    /// Spawn a new instance. A `petKind` IS the charm flag: a charmed spawn always names its kind
    /// and a hostile spawn never does.
    @discardableResult
    private func spawn(_ nameKey: String, _ display: String, _ ts: Int64, _ petKind: PetKind?) -> Int {
        let gen = (gens[nameKey] ?? 0) + 1
        gens[nameKey] = gen
        let inst = Instance(
            instanceId: "\(nameKey)#\(gen)",
            nameKey: nameKey,
            display: display,
            charmed: petKind != nil,
            petKind: petKind,
            firstSeenTs: ts,
            lastSeenTs: ts,
            retired: false,
            gen: gen
        )
        let at = insts.count
        byId[inst.instanceId] = at
        insts.append(inst)
        if var live = activeByName[nameKey] {
            live.append(at)
            activeByName[nameKey] = live
        } else {
            activeByName.insert(nameKey, [at])
        }
        return at
    }

    /// Adopt a fresher raw sighting as an instance's display name — but never let EQ's
    /// sentence-casing overwrite the spawn's true name.
    ///
    /// A lowercase-initial sighting can only be mid-sentence and always wins; a capital-initial one
    /// may only overwrite another capital-initial display. Proper names have no lowercase variant
    /// and keep latest-wins.
    private func adoptDisplay(_ at: Int, _ name: String) {
        if insts[at].display == name { return }
        if Names.idKey(insts[at].display) != Names.idKey(name) { return } // never relabel across identities
        // `/^[a-z]/` is ASCII-only in JS, so this is an ASCII-lowercase test.
        let incomingLower = name.unicodeScalars.first.map { $0.value >= 97 && $0.value <= 122 } ?? false
        let currentLower = insts[at].display.unicodeScalars.first.map { $0.value >= 97 && $0.value <= 122 } ?? false
        if incomingLower || !currentLower {
            insts[at].display = name
        }
    }

    /// Resolve a raw name to a live instance for attribution, spawning a hostile one if none is
    /// active. `preferCharmed` picks the charmed pet when both a pet and a hostile twin are live
    /// and the caller knows this reference is the pet; otherwise a hostile instance is preferred.
    @discardableResult
    public func resolve(_ name: String, _ ts: Int64, _ preferCharmed: Bool) -> Resolved {
        let key = Names.idKey(name)
        if key == "you" {
            // 'you' is not modeled as a spawnable instance; the synthetic sentinel is returned.
            return Resolved(instanceId: "you", nameKey: "you", label: "You")
        }
        retireStale(key, ts)
        guard let oldest = active(key).first else {
            let at = spawn(key, name, ts, nil)
            return resolved(at)
        }
        let at: Int
        if preferCharmed {
            at = charmedActive(key) ?? hostileActive(key) ?? oldest
        } else {
            at = hostileActive(key) ?? oldest
        }
        insts[at].lastSeenTs = ts
        adoptDisplay(at, name)
        return resolved(at)
    }

    /// Per-instance staleness (see the header). Retire every live HOSTILE instance of `nameKey`
    /// unobserved for INSTANCE_STALE_MS, so the caller's sighting spawns a fresh generation instead
    /// of reviving a mob nobody has seen. Twin-safe; pets are skipped.
    private func retireStale(_ nameKey: String, _ ts: Int64) {
        // Backwards by index: `retire()` splices this very array, and a forward walk would skip the
        // element that slid into the hole.
        guard var i = activeByName[nameKey]?.count else { return }
        while i > 0 {
            i -= 1
            guard let live = activeByName[nameKey], i < live.count else { continue }
            let at = live[i]
            if insts[at].charmed { continue }
            if ts - insts[at].lastSeenTs >= INSTANCE_STALE_MS {
                retire(at, ts)
            }
        }
    }

    /// Record that `name` was observed at `ts` without resolving or spawning anything — the
    /// world-model half of the encounter's presence axis. It refreshes only instances that already
    /// exist, so a whiff at a mob we have never damaged has zero world-model side effects (law 8).
    public func noteSeen(_ name: String, _ ts: Int64) {
        let key = Names.idKey(name)
        guard let live = activeByName[key] else { return }
        for at in live where ts > insts[at].lastSeenTs {
            insts[at].lastSeenTs = ts
        }
    }

    /// The charmed pet instance for a name (attribution helper). No staleness sweep — pets are
    /// exempt from it.
    public func petInstance(_ name: String) -> Resolved? {
        charmedActive(Names.idKey(name)).map { resolved($0) }
    }

    /// `charm(name)` — produce the charmed pet instance (decision table, row 2).
    @discardableResult
    public func charm(_ name: String, _ ts: Int64) -> Resolved {
        let key = Names.idKey(name)
        // A slot nobody has seen for INSTANCE_STALE_MS is not the mob we just charmed.
        retireStale(key, ts)
        // Bind an existing lone hostile only when there is exactly one active instance and it is
        // not already charmed — i.e. no evidence of a second twin yet.
        let act = active(key)
        let hostiles = act.filter { !insts[$0].charmed }
        if charmedActive(key) == nil, hostiles.count == 1, act.count == 1 {
            let at = hostiles[0]
            insts[at].charmed = true
            insts[at].petKind = .charmed
            insts[at].lastSeenTs = ts
            petTankedBy[at] = []
            return resolved(at)
        }
        let at = spawn(key, name, ts, .charmed)
        petTankedBy[at] = []
        return resolved(at)
    }

    /// `claim(name)` — mark a summoned pet. Idempotent FIRST, and that ordering is load-bearing: a
    /// pet re-tells you every few seconds, so its repeat tells resolve to the same live instance and
    /// never reach the succession below.
    @discardableResult
    public func claim(_ name: String, _ ts: Int64) -> Resolved {
        let key = Names.idKey(name)
        retireStale(key, ts)
        if let at = charmedActive(key) {
            insts[at].lastSeenTs = ts
            return resolved(at)
        }
        let act = active(key)
        let hostiles = act.filter { !insts[$0].charmed }
        let at: Int
        if hostiles.count == 1, act.count == 1 {
            at = hostiles[0]
            insts[at].charmed = true
            insts[at].petKind = .summoned
            insts[at].lastSeenTs = ts
        } else {
            at = spawn(key, name, ts, .summoned)
        }
        petTankedBy[at] = []
        retirePriorSummoned(at, ts)
        return resolved(at)
    }

    /// The single-pet invariant, for summoned pets (world-model law 4).
    ///
    /// You get one class pet, and re-summoning despawns the one you had — the game prints nothing
    /// when it happens, so the successor's own claim tell is the only evidence that ever arrives.
    /// Retirement, not deletion: the old pet keeps everything already attributed to it.
    /// Summoned only: a charmed pet and a summoned one alive together is an unobserved shape.
    private func retirePriorSummoned(_ pet: Int, _ ts: Int64) {
        for key in activeByName.keys {
            // Backwards by index, for the reason `retireStale` states: `retire()` splices these.
            guard var i = activeByName[key]?.count else { continue }
            while i > 0 {
                i -= 1
                guard let live = activeByName[key], i < live.count else { continue }
                let at = live[i]
                let inst = insts[at]
                if !inst.charmed || inst.petKind != .summoned || at == pet { continue }
                retire(at, ts)
            }
        }
    }

    /// `uncharm(name)` — clear the charmed flag on the pet instance (the same instance). A worn-off
    /// charm-spell line never names a summoned pet, so this is a no-op for them.
    @discardableResult
    public func uncharm(_ name: String, _ ts: Int64) -> Resolved? {
        guard let at = charmedActive(Names.idKey(name)) else { return nil }
        if insts[at].petKind == .summoned { return nil }
        insts[at].charmed = false
        insts[at].petKind = nil
        insts[at].lastSeenTs = ts
        return resolved(at)
    }

    /// Record evidence that a hostile twin of `name` co-exists with a charmed pet of the same name:
    /// ensure a second active hostile instance exists.
    public func noteTwinEvidence(_ name: String, _ ts: Int64) {
        let key = Names.idKey(name)
        if charmedActive(key) == nil { return } // only meaningful while a pet is live
        if hostileActive(key) == nil {
            spawn(key, name, ts, nil)
        }
    }

    /// Note that a charmed pet is trading blows with a killer of nameKey `otherKey`. Drives death
    /// case (b): if that killer later "slays" the name and the pet was tanking it, the pet died.
    public func notePetEngagement(_ petName: String, _ otherKey: String) {
        guard let at = charmedActive(Names.idKey(petName)) else { return }
        petTankedBy[at, default: []].insert(otherKey)
    }

    /// `death(name, killerKey)` — decide which instance retires.
    @discardableResult
    public func death(_ name: String, _ ts: Int64, _ killerKey: String?) -> DeathResolution {
        let key = Names.idKey(name)
        let act = active(key)
        if act.isEmpty {
            return DeathResolution(wasPet: false, ambiguous: false, reason: "no active instance")
        }
        let petOpt = charmedActive(key)
        let hostile = hostileActive(key)

        // Case 1: no charmed instance — plain hostile death.
        guard let pet = petOpt else {
            let victim = hostile ?? act[0]
            retire(victim, ts)
            return DeathResolution(wasPet: false, ambiguous: false, reason: "plain hostile death")
        }

        // Case 2a: the killer is You. The pet cannot be slain by you; a hostile twin died.
        if killerKey == "you" {
            if let hostile {
                retire(hostile, ts)
                return DeathResolution(wasPet: false, ambiguous: false, reason: "you slew hostile twin")
            }
            // Only the pet is live and the game says you slew it — charm broke this tick and then
            // you killed it. Rare, and deterministic.
            retire(pet, ts)
            return DeathResolution(wasPet: true, ambiguous: false, reason: "you slew pet (charm-break race)")
        }

        // Case 2b: the killer is a different name (e.g. a fire giant wizard).
        if let kk = killerKey, kk != key {
            return deathByForeignKiller(key, name, ts, pet, hostile, kk)
        }

        // Case 2c: the killer is the same name — pet↔twin, genuinely ambiguous.
        if let hostile {
            retire(hostile, ts)
            return DeathResolution(wasPet: false, ambiguous: true,
                                   reason: "ambiguous same-name death; kept pet, retired twin")
        }
        retire(pet, ts)
        return DeathResolution(wasPet: true, ambiguous: true,
                               reason: "ambiguous same-name death; only pet live → pet died")
    }

    /// `death()` case 2b: a charmed pet of `name` is live and the killer is a different name, so
    /// that killer was fighting something named `name`. The bias is away from retiring the pet.
    private func deathByForeignKiller(_ key: String, _ name: String, _ ts: Int64,
                                      _ pet: Int, _ hostile: Int?, _ kk: String) -> DeathResolution {
        let petTanked = petTankedBy[pet]?.contains(kk) ?? false
        if petTanked, hostile == nil {
            retire(pet, ts)
            return DeathResolution(wasPet: true, ambiguous: false, reason: "pet slain by \(kk) it was tanking")
        }
        if let hostile {
            retire(hostile, ts)
            return DeathResolution(
                wasPet: false,
                ambiguous: petTanked,
                reason: petTanked
                    ? "ambiguous: pet also tanked \(kk); kept pet, retired twin"
                    : "hostile twin slain by \(kk)"
            )
        }
        // No hostile twin AND no evidence the pet tanked this killer: the killer was fighting a
        // same-named mob we had not separately instanced. Spawn+retire a hostile twin slot; keep
        // the pet, flag ambiguity — never silently kill the pet.
        let ghost = spawn(key, name, ts, nil)
        retire(ghost, ts)
        return DeathResolution(wasPet: false, ambiguous: true, reason: "ambiguous: \(kk) slew a \(name); kept pet")
    }

    /// The one place retirement is recorded. Everything above funnels through it, which is what
    /// makes the announcement queue complete rather than best-effort.
    private func retire(_ at: Int, _ ts: Int64) {
        insts[at].retired = true
        insts[at].lastSeenTs = ts
        insts[at].charmed = false
        insts[at].petKind = nil
        petTankedBy.removeValue(forKey: at)
        let nameKey = insts[at].nameKey
        if var live = activeByName[nameKey] {
            if let pos = live.firstIndex(of: at) {
                live.remove(at: pos)
                activeByName[nameKey] = live
            }
        }
        retiredIds.append(insts[at].instanceId)
    }

    /// `zone(ts)` — retire everything except summoned pets. Charm cannot survive a zone and hostile
    /// mobs do not follow you; summoned class pets do. Returns the survivors so the engine can
    /// rebuild its pet-name index from them.
    @discardableResult
    public func zone(_ ts: Int64) -> [Resolved] {
        var survivors: [Resolved] = []
        for key in activeByName.keys {
            // A copy, not the live list: `retire()` splices it, and unlike `retireStale` this loop
            // must stay forward — the survivors it returns are rendered in this order.
            let list = activeByName[key] ?? []
            for at in list {
                let inst = insts[at]
                let kind = inst.charmed ? inst.petKind : nil
                if inst.charmed && !isLeftBehindOnZone(kind) {
                    insts[at].lastSeenTs = ts
                    survivors.append(resolved(at))
                } else {
                    retire(at, ts)
                }
            }
        }
        return survivors
    }

    /// True if the instance with this id has been retired (dead/zoned). An unknown id counts as
    /// retired: it cannot be a live engagement.
    public func isRetired(_ instanceId: String) -> Bool {
        guard let at = byId[instanceId] else { return true }
        return insts[at].retired
    }

    /// True if the instance is currently your (live, non-retired) charmed/summoned pet. Such an
    /// instance is never a hostile we are trying to kill, so it must not block an encounter's
    /// death-close.
    public func isLivePet(_ instanceId: String) -> Bool {
        guard let at = byId[instanceId] else { return false }
        return !insts[at].retired && insts[at].charmed
    }

    /// The genuinely-charmed live pets — mobs bound by a `<mob> has been charmed.` line. A summoned
    /// class pet is a pet but is not charmed. The only honest source for a charm roster.
    public func charmedInstances() -> [Resolved] { walkPets { $0 == .charmed } }

    /// All live pets, charmed and summoned — the attribution roster.
    public func petInstances() -> [Resolved] { walkPets { _ in true } }

    private func walkPets(_ want: (PetKind?) -> Bool) -> [Resolved] {
        var out: [Resolved] = []
        for (_, list) in activeByName.pairs {
            for at in list {
                let inst = insts[at]
                if inst.charmed && want(inst.petKind) {
                    out.append(resolved(at))
                }
            }
        }
        return out
    }

    /// The name key of every live pet, in the order `petInstances` reports.
    public func petNameKeys() -> [String] { petInstances().map(\.nameKey) }

    /// Display label for an instance in encounter views. When more than one instance of a nameKey
    /// has ever been spawned, later gens get a ` (N)` suffix so twins are visually distinct; the
    /// first gen keeps the bare name.
    private func resolved(_ at: Int) -> Resolved {
        let inst = insts[at]
        let total = gens[inst.nameKey] ?? 1
        let label = (total <= 1 || inst.gen == 1) ? inst.display : "\(inst.display) (\(inst.gen))"
        return Resolved(instanceId: inst.instanceId, nameKey: inst.nameKey, label: label)
    }
}
