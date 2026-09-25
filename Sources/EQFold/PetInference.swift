// Your pet, inferred when the game never names it. NOT A PORT: upstream binds a summoned pet only on
// the lines that say whose it is — `Garn told you, 'Attacking … Master.'` (a `petClaim`) or a
// `My leader is …` say. A pet that comes into a session already summoned, and that you never order
// by tell, says neither, so its damage was a stranger's.
//
// The evidence used instead: YOU heal it (`You healed Liber for 255 hit points by Talisman of
// Altuna.` — a pet buff, a lifetap splash, a heal) and it fights (it swings or casts at something
// other than you), both within `windowMs` of each other in either order. On a real log every
// single-word name the player healed that also fought was one of their pets; a groupmate is the
// exception, and the roster refuses those.
//
// Refused: anything but a single capitalized word (`isPlayerShapedName` — mobs carry articles),
// a current roster member, another player's pet (`My leader is <someone else>`), a name that has
// struck you, and a name already bound. A death releases the name.
//
// What it produces is the game's own `petClaim` event with `via: "inferred"`, so every module that
// binds a pet on a claim (combat, kill credit, buffs, the roster) binds this one the same way. It
// runs only where the owner switches it on (`Fold.petInference`); the parity oracles never do.
import Foundation
import EQLog
import EQCompanionCore

public final class PetInference {
    /// How far apart the heal and the fighting may be and still describe the same pet.
    public static let windowMs: Int64 = 60 * 60_000

    private var healed: [String: (name: String, ts: Int64)] = [:]
    private var fought: [String: Int64] = [:]
    private var bound: Set<String> = []
    /// Names that can never be yours: another player's pet, or something that has hit you.
    private var refused: Set<String> = []

    public init() {}

    public func reset() {
        healed.removeAll(); fought.removeAll(); bound.removeAll(); refused.removeAll()
    }

    private static func isYou(_ name: String?) -> Bool { name.map { Names.idKey($0) == "you" } ?? false }

    /// The claim this event completes, if any.
    public func observe(_ ev: Event, roster: RosterSource?) -> Event? {
        switch ev.kind {
        case "petClaim":
            if let n = ev.str(.name) { bound.insert(Names.idKey(n)) }
        case "allyPetLeader":
            if let p = ev.str(.pet), !Self.isYou(ev.str(.owner)) { refused.insert(Names.idKey(p)) }
        case "death":
            if let n = ev.str(.name) {
                let k = Names.idKey(n)
                bound.remove(k); healed[k] = nil; fought[k] = nil
            }
        case "heal":
            guard Self.isYou(ev.str(.healer)), let target = ev.str(.target), !Self.isYou(target) else { break }
            let k = Names.idKey(target)
            guard eligible(k, target, roster) else { break }
            healed[k] = (target, ev.ts)
            if let f = fought[k], abs(ev.ts - f) <= Self.windowMs { return claim(k, target, ev) }
        case "damage", "miss":
            guard let attacker = ev.str(.attacker), !Self.isYou(attacker) else { break }
            let k = Names.idKey(attacker)
            if Self.isYou(ev.str(.target)) { refused.insert(k); break }
            guard eligible(k, attacker, roster) else { break }
            fought[k] = ev.ts
            if let h = healed[k], abs(ev.ts - h.ts) <= Self.windowMs { return claim(k, h.name, ev) }
        default:
            break
        }
        return nil
    }

    private func eligible(_ key: String, _ name: String, _ roster: RosterSource?) -> Bool {
        if bound.contains(key) || refused.contains(key) || !isPlayerShapedName(name) { return false }
        if let r = roster, r.members().contains(where: { Names.idKey($0) == key }) { return false }
        return true
    }

    private func claim(_ key: String, _ name: String, _ ev: Event) -> Event {
        bound.insert(key)
        healed[key] = nil; fought[key] = nil
        return Event.fromValue(["kind": "petClaim", "name": .string(name), "via": "inferred",
                                "seq": .int(ev.seq), "ts": .int(ev.ts), "raw": .string(ev.raw)])
    }

    // MARK: - Checkpoint

    func checkpointState() -> JSONValue {
        [
            "healed": .object(healed.mapValues { ["name": .string($0.name), "ts": .int($0.ts)] }),
            "fought": .object(fought.mapValues { .int($0) }),
            "bound": .array(bound.sorted().map { .string($0) }),
            "refused": .array(refused.sorted().map { .string($0) }),
        ]
    }

    func restoreCheckpoint(_ v: JSONValue) -> Bool {
        reset()
        guard let h = v["healed"].object, let f = v["fought"].object,
              let b = v["bound"].array, let r = v["refused"].array else { return false }
        for (k, e) in h { if let n = e["name"].string, let ts = e["ts"].int64 { healed[k] = (n, ts) } }
        for (k, ts) in f { if let t = ts.int64 { fought[k] = t } }
        bound = Set(b.compactMap(\.string))
        refused = Set(r.compactMap(\.string))
        return true
    }
}
